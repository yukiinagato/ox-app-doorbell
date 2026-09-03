





#include "media/encoder_win.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <strmif.h>  // ICodecAPI
#include <windows.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <vector>

#include "util/log.h"

namespace db {

namespace {

constexpr const char* kTag = "encoder";


template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  ~ComPtr() { reset(); }
  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;
  T** put() {
    reset();
    return &p_;
  }
  T* get() const { return p_; }
  T* operator->() const { return p_; }
  explicit operator bool() const { return p_ != nullptr; }
  void reset() {
    if (p_) {
      p_->Release();
      p_ = nullptr;
    }
  }

 private:
  T* p_ = nullptr;
};

std::string hrStr(HRESULT hr) {
  char buf[16];
  std::snprintf(buf, sizeof(buf), "0x%08lx", static_cast<unsigned long>(hr));
  return buf;
}



const GUID kAVEncCommonRateControlMode = {
    0x1c0608e9, 0x370c, 0x4710, {0x8a, 0x58, 0xcb, 0x61, 0x81, 0xc4, 0x24, 0x23}};
const GUID kAVEncCommonMeanBitRate = {
    0xf7222374, 0x2144, 0x4815, {0xb5, 0x50, 0xa3, 0x7f, 0x8e, 0x12, 0xee, 0x52}};
const GUID kAVEncMPVGOPSize = {
    0x95f31b26, 0x95a4, 0x41aa, {0x93, 0x03, 0x24, 0x6a, 0x7f, 0xc6, 0xee, 0xf1}};
const GUID kAVLowLatencyMode = {
    0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}};
const GUID kAVEncVideoForceKeyFrame = {
    0x398c1b98, 0x8353, 0x475a, {0x9e, 0xf2, 0x8f, 0x26, 0x5d, 0x26, 0x03, 0x45}};
constexpr UINT32 kRateControlCbr = 0;  // eAVEncCommonRateControlMode_CBR


void yuy2ToNv12(const uint8_t* src, int w, int h, int stride, uint8_t* dst) {
  uint8_t* y = dst;
  uint8_t* uv = dst + static_cast<size_t>(w) * h;
  for (int r = 0; r < h; r++) {
    const uint8_t* row = src + static_cast<size_t>(r) * stride;
    for (int c = 0; c < w; c++) y[static_cast<size_t>(r) * w + c] = row[c * 2];
    if ((r & 1) == 0) {
      uint8_t* uvrow = uv + static_cast<size_t>(r / 2) * w;
      for (int c = 0; c + 1 < w; c += 2) {
        uvrow[c] = row[c * 2 + 1];      // U
        uvrow[c + 1] = row[c * 2 + 3];  // V
      }
    }
  }
}


void packNv12(const uint8_t* src, int w, int h, int stride, uint8_t* dst) {
  for (int r = 0; r < h; r++)
    std::memcpy(dst + static_cast<size_t>(r) * w, src + static_cast<size_t>(r) * stride, w);
  const uint8_t* suv = src + static_cast<size_t>(stride) * h;
  uint8_t* duv = dst + static_cast<size_t>(w) * h;
  for (int r = 0; r < (h + 1) / 2; r++)
    std::memcpy(duv + static_cast<size_t>(r) * w, suv + static_cast<size_t>(r) * stride, w);
}


struct Mft {
  ComPtr<IMFTransform> xf;
  ComPtr<IMFMediaEventGenerator> gen;
  ComPtr<ICodecAPI> codec_api;
  bool async = false;
  bool provides_samples = false;
  DWORD in_id = 0, out_id = 0;
  DWORD out_size = 0;
};


bool createMft(Mft* m) {
  MFT_REGISTER_TYPE_INFO tin{MFMediaType_Video, MFVideoFormat_NV12};
  MFT_REGISTER_TYPE_INFO tout{MFMediaType_Video, MFVideoFormat_H264};
  const struct {
    UINT32 flags;
    const char* label;
  } tries[] = {
      {MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, "HW"},
      {MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, "SW"},
  };
  for (const auto& t : tries) {
    IMFActivate** acts = nullptr;
    UINT32 n = 0;
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, t.flags, &tin, &tout, &acts, &n);
    if (FAILED(hr) || n == 0) {
      if (acts) ::CoTaskMemFree(acts);
      continue;
    }
    hr = acts[0]->ActivateObject(IID_IMFTransform, reinterpret_cast<void**>(m->xf.put()));
    for (UINT32 i = 0; i < n; i++) acts[i]->Release();
    ::CoTaskMemFree(acts);
    if (FAILED(hr)) continue;
    DB_LOGI(kTag, std::string("H.264 encoder MFT: ") + t.label);
    break;
  }
  if (!m->xf) return false;


  ComPtr<IMFAttributes> attrs;
  if (SUCCEEDED(m->xf->GetAttributes(attrs.put())) && attrs) {
    UINT32 is_async = 0;
    attrs->GetUINT32(MF_TRANSFORM_ASYNC, &is_async);
    if (is_async) {
      m->async = true;
      attrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
      if (FAILED(m->xf->QueryInterface(IID_PPV_ARGS(m->gen.put())))) {
        DB_LOGE(kTag, "asynchronous MFT does not expose IMFMediaEventGenerator");
        return false;
      }
    }
  }

  DWORD ins = 0, outs = 0;
  if (SUCCEEDED(m->xf->GetStreamCount(&ins, &outs)) && (ins > 0 || outs > 0)) {
    DWORD in_ids[1] = {0}, out_ids[1] = {0};
    if (m->xf->GetStreamIDs(1, in_ids, 1, out_ids) == S_OK) {
      m->in_id = in_ids[0];
      m->out_id = out_ids[0];
    }
  }
  return true;
}


bool configureMft(Mft* m, int w, int h, const EncoderWin::Params& p) {
  ComPtr<IMFMediaType> out;
  HRESULT hr = MFCreateMediaType(out.put());
  if (FAILED(hr)) return false;
  out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  out->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  out->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(p.bitrate_kbps) * 1000);
  MFSetAttributeSize(out.get(), MF_MT_FRAME_SIZE, w, h);
  MFSetAttributeRatio(out.get(), MF_MT_FRAME_RATE, static_cast<UINT32>(p.fps), 1);
  MFSetAttributeRatio(out.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  out->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  out->SetUINT32(MF_MT_MPEG2_PROFILE, 66);
  hr = m->xf->SetOutputType(m->out_id, out.get(), 0);
  if (FAILED(hr)) {
    DB_LOGE(kTag, "SetOutputType failed: " + hrStr(hr));
    return false;
  }
  ComPtr<IMFMediaType> in;
  hr = MFCreateMediaType(in.put());
  if (FAILED(hr)) return false;
  in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  MFSetAttributeSize(in.get(), MF_MT_FRAME_SIZE, w, h);
  MFSetAttributeRatio(in.get(), MF_MT_FRAME_RATE, static_cast<UINT32>(p.fps), 1);
  in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  in->SetUINT32(MF_MT_DEFAULT_STRIDE, static_cast<UINT32>(w));
  hr = m->xf->SetInputType(m->in_id, in.get(), 0);
  if (FAILED(hr)) {
    DB_LOGE(kTag, "SetInputType failed: " + hrStr(hr));
    return false;
  }

  if (SUCCEEDED(m->xf->QueryInterface(
          IID_ICodecAPI, reinterpret_cast<void**>(m->codec_api.put())))) {
    VARIANT v;
    ::VariantInit(&v);
    v.vt = VT_UI4;
    v.ulVal = kRateControlCbr;
    m->codec_api->SetValue(&kAVEncCommonRateControlMode, &v);
    v.ulVal = static_cast<ULONG>(p.bitrate_kbps) * 1000;
    m->codec_api->SetValue(&kAVEncCommonMeanBitRate, &v);
    v.ulVal = static_cast<ULONG>(p.fps * p.gop_s);
    m->codec_api->SetValue(&kAVEncMPVGOPSize, &v);
    VARIANT b;
    ::VariantInit(&b);
    b.vt = VT_BOOL;
    b.boolVal = VARIANT_TRUE;
    m->codec_api->SetValue(&kAVLowLatencyMode, &b);
  }
  MFT_OUTPUT_STREAM_INFO osi{};
  if (SUCCEEDED(m->xf->GetOutputStreamInfo(m->out_id, &osi))) {
    m->provides_samples = (osi.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;
    m->out_size = osi.cbSize ? osi.cbSize : static_cast<DWORD>(w) * h;
  } else {
    m->out_size = static_cast<DWORD>(w) * h;
  }
  m->xf->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  m->xf->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  return true;
}


bool makeSample(const RawFrame& f, int fps, IMFSample** out) {
  const DWORD size = static_cast<DWORD>(f.data.size());
  ComPtr<IMFSample> sample;
  ComPtr<IMFMediaBuffer> buf;
  if (FAILED(MFCreateSample(sample.put()))) return false;
  if (FAILED(MFCreateMemoryBuffer(size, buf.put()))) return false;
  BYTE* p = nullptr;
  DWORD maxlen = 0;
  if (FAILED(buf->Lock(&p, &maxlen, nullptr))) return false;
  std::memcpy(p, f.data.data(), size);
  buf->Unlock();
  buf->SetCurrentLength(size);
  sample->AddBuffer(buf.get());
  sample->SetSampleTime(f.ts_ms * 10000);  // ms → 100ns
  sample->SetSampleDuration(10000000 / (fps > 0 ? fps : 25));
  *out = sample.get();
  (*out)->AddRef();
  return true;
}

}  // namespace

void EncoderWin::start(const Params& p) {
  stop();
  params_ = p;
  {
    std::lock_guard<std::mutex> lk(mu_);
    queue_.clear();
    last_fed_ms_ = 0;
  }
  running_ = true;
  keyframe_requested_ = false;
  th_ = std::thread([this] { run(); });
}

void EncoderWin::stop() {
  running_ = false;
  cv_.notify_all();
  if (th_.joinable()) th_.join();
}

void EncoderWin::feed(const RawFrame& f) {
  if (!running_.load()) return;
  if (f.format != 1 && f.format != 2) return;

  const int64_t interval = 1000 / (params_.fps > 0 ? params_.fps : 25);
  if (last_fed_ms_ && f.ts_ms - last_fed_ms_ < interval) return;
  last_fed_ms_ = f.ts_ms;

  RawFrame nv12;
  nv12.format = 1;
  nv12.w = f.w;
  nv12.h = f.h;
  nv12.stride = f.w;
  nv12.ts_ms = f.ts_ms;
  nv12.data.resize(static_cast<size_t>(f.w) * f.h + static_cast<size_t>(f.w) * ((f.h + 1) / 2));
  if (f.format == 2) {
    yuy2ToNv12(f.data.data(), f.w, f.h, f.stride, nv12.data.data());
  } else {
    packNv12(f.data.data(), f.w, f.h, f.stride, nv12.data.data());
  }
  {
    std::lock_guard<std::mutex> lk(mu_);
    if (queue_.size() >= 2) queue_.pop_front();
    queue_.push_back(std::move(nv12));
  }
  cv_.notify_all();
}

bool EncoderWin::popFrame(RawFrame* out, int timeout_ms) {
  std::unique_lock<std::mutex> lk(mu_);
  cv_.wait_for(lk, std::chrono::milliseconds(timeout_ms),
               [this] { return !queue_.empty() || !running_.load(); });
  if (queue_.empty()) return false;
  *out = std::move(queue_.front());
  queue_.pop_front();
  return true;
}

void EncoderWin::run() {
  HRESULT co = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool co_ok = SUCCEEDED(co);
  HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(hr)) {
    DB_LOGE(kTag, "MFStartup failed: " + hrStr(hr));
    if (co_ok) ::CoUninitialize();
    running_ = false;
    return;
  }
  {
    Mft mft;
    bool ready = false;
    int w = 0, h = 0;
    long need_input = 0;


    auto drainOne = [&]() -> bool {
      MFT_OUTPUT_DATA_BUFFER ob{};
      ob.dwStreamID = mft.out_id;
      ComPtr<IMFSample> own;
      if (!mft.provides_samples) {
        ComPtr<IMFMediaBuffer> buf;
        if (FAILED(MFCreateSample(own.put()))) return false;
        if (FAILED(MFCreateMemoryBuffer(mft.out_size, buf.put()))) return false;
        own->AddBuffer(buf.get());
        ob.pSample = own.get();
      }
      DWORD status = 0;
      HRESULT ohr = mft.xf->ProcessOutput(0, 1, &ob, &status);
      if (ob.pEvents) ob.pEvents->Release();
      if (ohr == MF_E_TRANSFORM_NEED_MORE_INPUT) return false;
      if (FAILED(ohr)) {
        DB_LOGE(kTag, "ProcessOutput failed: " + hrStr(ohr));
        running_ = false;
        return false;
      }
      IMFSample* s = ob.pSample;
      if (!s) return true;
      LONGLONG ts100 = 0;
      s->GetSampleTime(&ts100);
      UINT32 clean = 0;
      s->GetUINT32(MFSampleExtension_CleanPoint, &clean);
      ComPtr<IMFMediaBuffer> cbuf;
      if (SUCCEEDED(s->ConvertToContiguousBuffer(cbuf.put()))) {
        BYTE* p = nullptr;
        DWORD maxlen = 0, curlen = 0;
        if (SUCCEEDED(cbuf->Lock(&p, &maxlen, &curlen)) ) {
          if (curlen > 0 && out_) out_(p, curlen, clean != 0, ts100 / 10000);
          cbuf->Unlock();
        }
      }
      if (mft.provides_samples && s) s->Release();
      return true;
    };

    auto feedOne = [&](const RawFrame& f) {
      if (keyframe_requested_.exchange(false) && mft.codec_api) {
        VARIANT force;
        ::VariantInit(&force);
        force.vt = VT_BOOL;
        force.boolVal = VARIANT_TRUE;
        HRESULT force_hr = mft.codec_api->SetValue(&kAVEncVideoForceKeyFrame, &force);
        if (FAILED(force_hr))
          DB_LOGW(kTag, "keyframe request failed: " + hrStr(force_hr));
      }
      ComPtr<IMFSample> sample;
      if (!makeSample(f, params_.fps, sample.put())) return;
      HRESULT ihr = mft.xf->ProcessInput(mft.in_id, sample.get(), 0);
      if (FAILED(ihr) && ihr != MF_E_NOTACCEPTING)
        DB_LOGW(kTag, "ProcessInput failed: " + hrStr(ihr));
    };

    while (running_.load()) {
      if (!ready) {
        RawFrame f;
        if (!popFrame(&f, 200)) continue;
        w = f.w;
        h = f.h;
        if (!createMft(&mft) || !configureMft(&mft, w, h, params_)) {
          DB_LOGE(kTag, "cannot initialize an H.264 encoder MFT; falling back to MJPEG");
          running_ = false;
          break;
        }
        DB_LOGI(kTag, "H.264 encoding started " + std::to_string(w) + "x" + std::to_string(h) +
                          " @" + std::to_string(params_.fps) + "fps " +
                          std::to_string(params_.bitrate_kbps) + "kbps" +
                          (mft.async ? " (async)" : " (sync)"));
        ready = true;
        if (!mft.async) feedOne(f);

        continue;
      }
      if (mft.async) {

        ComPtr<IMFMediaEvent> ev;
        HRESULT ehr = mft.gen->GetEvent(MF_EVENT_FLAG_NO_WAIT, ev.put());
        if (ehr == S_OK && ev) {
          MediaEventType met = MEUnknown;
          ev->GetType(&met);
          if (met == METransformNeedInput) {
            need_input++;
          } else if (met == METransformHaveOutput) {
            drainOne();
          }
          continue;
        }
        if (need_input > 0) {
          RawFrame f;
          if (popFrame(&f, 100)) {
            feedOne(f);
            need_input--;
          }
        } else {
          ::Sleep(5);
        }
      } else {
        RawFrame f;
        if (!popFrame(&f, 200)) continue;
        feedOne(f);
        while (running_.load() && drainOne()) {
        }
      }
    }
    if (mft.xf) {
      mft.xf->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
      mft.xf->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    }
  }
  MFShutdown();
  if (co_ok) ::CoUninitialize();
  running_ = false;
  DB_LOGI(kTag, "encoding thread stopped");
}

}  // namespace db
