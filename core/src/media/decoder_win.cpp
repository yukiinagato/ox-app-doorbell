#include "media/decoder_win.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <strmif.h>  // ICodecAPI
#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <deque>
#include <utility>
#include <cstring>
#include <vector>

#include "util/log.h"

namespace db {

namespace {

constexpr const char* kTag = "decoder";

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

// CODECAPI_AVLowLatencyMode / MF_LOW_LATENCY share this GUID.
const GUID kAVLowLatencyMode = {
    0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}};

struct Mft {
  ComPtr<IMFTransform> xf;
  ComPtr<ICodecAPI> codec_api;
  DWORD in_id = 0, out_id = 0;
  DWORD out_size = 0;
  bool provides_samples = false;
  int width = 0, height = 0;
  LONG stride = 0;
  std::string label;
  void reset() {
    codec_api.reset();
    xf.reset();
    in_id = out_id = 0;
    out_size = 0;
    provides_samples = false;
    width = height = 0;
    stride = 0;
    label.clear();
  }
};

uint8_t clamp8(int v) { return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v)); }

// NV12 (BT.601 limited range) → top-down BGRA. Sizes are small (door-station 640x360), so a
// plain integer loop is fast enough and keeps the shell free of pixel format knowledge.
void nv12ToBgra(const uint8_t* y_plane, const uint8_t* uv_plane, LONG pitch, int w, int h,
                std::vector<uint8_t>* out) {
  out->resize(static_cast<size_t>(w) * h * 4);
  for (int r = 0; r < h; r++) {
    const uint8_t* y = y_plane + static_cast<size_t>(r) * pitch;
    const uint8_t* uv = uv_plane + static_cast<size_t>(r / 2) * pitch;
    uint8_t* dst = out->data() + static_cast<size_t>(r) * w * 4;
    for (int c = 0; c < w; c++) {
      int yy = (static_cast<int>(y[c]) - 16) * 298;
      int u = static_cast<int>(uv[(c & ~1)]) - 128;
      int v = static_cast<int>(uv[(c & ~1) + 1]) - 128;
      dst[c * 4 + 0] = clamp8((yy + 516 * u + 128) >> 8);            // B
      dst[c * 4 + 1] = clamp8((yy - 100 * u - 208 * v + 128) >> 8);  // G
      dst[c * 4 + 2] = clamp8((yy + 409 * v + 128) >> 8);            // R
      dst[c * 4 + 3] = 0xff;
    }
  }
}

bool selectOutputType(Mft* m) {
  for (DWORD i = 0;; i++) {
    ComPtr<IMFMediaType> t;
    HRESULT hr = m->xf->GetOutputAvailableType(m->out_id, i, t.put());
    if (FAILED(hr)) break;
    GUID sub = GUID_NULL;
    if (FAILED(t->GetGUID(MF_MT_SUBTYPE, &sub)) || sub != MFVideoFormat_NV12) continue;
    hr = m->xf->SetOutputType(m->out_id, t.get(), 0);
    if (FAILED(hr)) {
      DB_LOGE(kTag, "SetOutputType(NV12) failed: " + hrStr(hr));
      return false;
    }
    UINT32 w = 0, h = 0;
    if (SUCCEEDED(MFGetAttributeSize(t.get(), MF_MT_FRAME_SIZE, &w, &h))) {
      m->width = static_cast<int>(w);
      m->height = static_cast<int>(h);
    }
    UINT32 stride = 0;
    m->stride = SUCCEEDED(t->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride)) && stride
                    ? static_cast<LONG>(static_cast<INT32>(stride)) : m->width;
    MFT_OUTPUT_STREAM_INFO osi{};
    if (SUCCEEDED(m->xf->GetOutputStreamInfo(m->out_id, &osi))) {
      m->provides_samples = (osi.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;
      m->out_size = osi.cbSize;
    }
    if (!m->out_size)
      m->out_size = static_cast<DWORD>(m->width) * m->height * 3 / 2 + 4096;
    return true;
  }
  DB_LOGE(kTag, "the H.264 decoder offers no NV12 output");
  return false;
}

bool createMft(Mft* m, const fmp4::Demuxer::Config& cfg) {
  MFT_REGISTER_TYPE_INFO tin{MFMediaType_Video, MFVideoFormat_H264};
  MFT_REGISTER_TYPE_INFO tout{MFMediaType_Video, MFVideoFormat_NV12};
  IMFActivate** acts = nullptr;
  UINT32 n = 0;
  // The synchronous (software) decoder: no D3D device is needed for DXVA, and 640x360 at
  // 20 fps is far below what it handles on a Toughpad.
  HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                         MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, &tin, &tout,
                         &acts, &n);
  if (FAILED(hr) || n == 0) {
    if (acts) ::CoTaskMemFree(acts);
    DB_LOGE(kTag, "no H.264 decoder MFT: " + hrStr(hr));
    return false;
  }
  hr = acts[0]->ActivateObject(IID_IMFTransform, reinterpret_cast<void**>(m->xf.put()));
  {
    WCHAR* name = nullptr;
    UINT32 len = 0;
    if (SUCCEEDED(acts[0]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &name, &len)) &&
        name) {
      char narrow[128];
      int wrote = ::WideCharToMultiByte(CP_UTF8, 0, name, -1, narrow, sizeof(narrow), nullptr,
                                        nullptr);
      m->label = wrote > 0 ? narrow : "h264 decoder";
      ::CoTaskMemFree(name);
    } else {
      m->label = "h264 decoder";
    }
  }
  for (UINT32 i = 0; i < n; i++) acts[i]->Release();
  ::CoTaskMemFree(acts);
  if (FAILED(hr) || !m->xf) {
    DB_LOGE(kTag, "ActivateObject failed: " + hrStr(hr));
    return false;
  }

  ComPtr<IMFAttributes> attrs;
  if (SUCCEEDED(m->xf->GetAttributes(attrs.put())) && attrs)
    attrs->SetUINT32(kAVLowLatencyMode, 1);
  if (SUCCEEDED(m->xf->QueryInterface(IID_ICodecAPI,
                                      reinterpret_cast<void**>(m->codec_api.put())))) {
    VARIANT b;
    ::VariantInit(&b);
    b.vt = VT_BOOL;
    b.boolVal = VARIANT_TRUE;
    m->codec_api->SetValue(&kAVLowLatencyMode, &b);
  }

  DWORD ins = 0, outs = 0;
  if (SUCCEEDED(m->xf->GetStreamCount(&ins, &outs)) && (ins > 0 || outs > 0)) {
    DWORD in_ids[1] = {0}, out_ids[1] = {0};
    if (m->xf->GetStreamIDs(1, in_ids, 1, out_ids) == S_OK) {
      m->in_id = in_ids[0];
      m->out_id = out_ids[0];
    }
  }

  ComPtr<IMFMediaType> in;
  if (FAILED(MFCreateMediaType(in.put()))) return false;
  in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_MixedInterlaceOrProgressive);
  if (cfg.width > 0 && cfg.height > 0)
    MFSetAttributeSize(in.get(), MF_MT_FRAME_SIZE, static_cast<UINT32>(cfg.width),
                       static_cast<UINT32>(cfg.height));
  hr = m->xf->SetInputType(m->in_id, in.get(), 0);
  if (FAILED(hr)) {
    DB_LOGE(kTag, "SetInputType(H264) failed: " + hrStr(hr));
    return false;
  }
  if (!selectOutputType(m)) return false;
  m->xf->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  m->xf->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  return true;
}

bool makeSample(const fmp4::Demuxer::AccessUnit& au, IMFSample** out) {
  const DWORD size = static_cast<DWORD>(au.annexb.size());
  ComPtr<IMFSample> sample;
  ComPtr<IMFMediaBuffer> buf;
  if (FAILED(MFCreateSample(sample.put()))) return false;
  if (FAILED(MFCreateMemoryBuffer(size, buf.put()))) return false;
  BYTE* p = nullptr;
  DWORD maxlen = 0;
  if (FAILED(buf->Lock(&p, &maxlen, nullptr))) return false;
  std::memcpy(p, au.annexb.data(), size);
  buf->Unlock();
  buf->SetCurrentLength(size);
  sample->AddBuffer(buf.get());
  sample->SetSampleTime(static_cast<LONGLONG>(au.dts) * 10000);  // ms → 100 ns
  sample->SetSampleDuration(static_cast<LONGLONG>(au.dur_ms ? au.dur_ms : 40) * 10000);
  if (au.key) sample->SetUINT32(MFSampleExtension_CleanPoint, 1);
  *out = sample.get();
  (*out)->AddRef();
  return true;
}

}  // namespace

DecoderWin::DecoderWin(Output out, StateFn state)
    : out_(std::move(out)), state_(std::move(state)) {}

DecoderWin::~DecoderWin() { stop(); }

void DecoderWin::start() {
  stop();
  {
    std::lock_guard<std::mutex> lk(mu_);
    queue_.clear();
    wait_key_ = true;
    stats_ = Stats();
  }
  started_ = std::chrono::steady_clock::now();
  running_ = true;
  th_ = std::thread([this] { run(); });
}

void DecoderWin::stop() {
  running_ = false;
  cv_.notify_all();
  if (th_.joinable()) th_.join();
}

void DecoderWin::configure(const fmp4::Demuxer::Config& config) {
  std::lock_guard<std::mutex> lk(mu_);
  queue_.clear();
  Item item;
  item.is_config = true;
  item.config = config;
  queue_.push_back(std::move(item));
  wait_key_ = true;
  cv_.notify_all();
}

void DecoderWin::feed(fmp4::Demuxer::AccessUnit&& au) {
  std::lock_guard<std::mutex> lk(mu_);
  stats_.received++;
  if (wait_key_) {
    if (!au.key) {
      stats_.dropped++;
      return;
    }
    wait_key_ = false;
  }
  size_t units = 0;
  for (const Item& it : queue_)
    if (!it.is_config) units++;
  if (units >= kMaxQueued) {
    // Live-only: forget the backlog and resume at the next random-access point.
    size_t removed = 0;
    for (auto it = queue_.begin(); it != queue_.end();) {
      if (!it->is_config) {
        it = queue_.erase(it);
        removed++;
      } else {
        ++it;
      }
    }
    stats_.dropped += removed;
    if (!au.key) {
      stats_.dropped++;
      wait_key_ = true;
      return;
    }
  }
  Item item;
  item.au = std::move(au);
  queue_.push_back(std::move(item));
  cv_.notify_all();
}

DecoderWin::Stats DecoderWin::stats() const {
  std::lock_guard<std::mutex> lk(mu_);
  return stats_;
}

bool DecoderWin::pop(Item* out, int timeout_ms) {
  std::unique_lock<std::mutex> lk(mu_);
  cv_.wait_for(lk, std::chrono::milliseconds(timeout_ms),
               [this] { return !queue_.empty() || !running_.load(); });
  if (queue_.empty()) return false;
  *out = std::move(queue_.front());
  queue_.pop_front();
  return true;
}

void DecoderWin::run() {
  HRESULT co = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool co_ok = SUCCEEDED(co);
  HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(hr)) {
    DB_LOGE(kTag, "MFStartup failed: " + hrStr(hr));
    if (state_) state_("error", "MFStartup " + hrStr(hr));
    if (co_ok) ::CoUninitialize();
    running_ = false;
    return;
  }
  {
    Mft mft;
    bool ready = false;
    std::vector<uint8_t> bgra;
    bool first_delivered = false;
    std::deque<std::pair<uint64_t, int64_t>> captures;  // (dts, capture_ms) awaiting output

    auto deliver = [&](IMFSample* s) {
      LONGLONG ts100 = 0;
      s->GetSampleTime(&ts100);
      ComPtr<IMFMediaBuffer> buf;
      if (FAILED(s->ConvertToContiguousBuffer(buf.put())) || !buf) return;
      ComPtr<IMF2DBuffer> buf2d;
      BYTE* scan0 = nullptr;
      LONG pitch = mft.stride;
      bool locked2d = false;
      if (SUCCEEDED(buf->QueryInterface(IID_PPV_ARGS(buf2d.put()))) && buf2d &&
          SUCCEEDED(buf2d->Lock2D(&scan0, &pitch))) {
        locked2d = true;
      } else {
        DWORD maxlen = 0, curlen = 0;
        if (FAILED(buf->Lock(&scan0, &maxlen, &curlen))) return;
        if (pitch <= 0) pitch = mft.width;
      }
      if (scan0 && mft.width > 0 && mft.height > 0) {
        const uint8_t* y = scan0;
        const uint8_t* uv = scan0 + static_cast<size_t>(pitch) * mft.height;
        nv12ToBgra(y, uv, pitch, mft.width, mft.height, &bgra);
        Frame f;
        f.bgra = bgra.data();
        f.width = mft.width;
        f.height = mft.height;
        f.stride = mft.width * 4;
        f.dts = static_cast<uint64_t>(ts100 / 10000);
        // Output order equals input order (low-latency mode, no B-frames), so the capture time
        // of a decoded frame is the one queued with the same decode time.
        f.capture_ms = 0;
        while (!captures.empty() && captures.front().first < f.dts) captures.pop_front();
        if (!captures.empty() && captures.front().first == f.dts) {
          f.capture_ms = captures.front().second;
          captures.pop_front();
        }
        {
          std::lock_guard<std::mutex> lk(mu_);
          stats_.decoded++;
          stats_.width = mft.width;
          stats_.height = mft.height;
          if (!first_delivered) {
            first_delivered = true;
            stats_.first_frame_ms = static_cast<int>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - started_).count());
          }
        }
        bool announce_first = false;
        int first_ms = 0;
        {
          std::lock_guard<std::mutex> lk(mu_);
          announce_first = stats_.decoded == 1;
          first_ms = stats_.first_frame_ms;
        }
        if (out_) out_(f);
        if (announce_first && state_) state_("first_frame", std::to_string(first_ms));
      }
      if (locked2d) buf2d->Unlock2D();
      else buf->Unlock();
    };

    auto drain = [&]() {
      for (;;) {
        MFT_OUTPUT_DATA_BUFFER ob{};
        ob.dwStreamID = mft.out_id;
        ComPtr<IMFSample> own;
        if (!mft.provides_samples) {
          ComPtr<IMFMediaBuffer> buf;
          if (FAILED(MFCreateSample(own.put()))) return;
          if (FAILED(MFCreateMemoryBuffer(mft.out_size, buf.put()))) return;
          own->AddBuffer(buf.get());
          ob.pSample = own.get();
        }
        DWORD status = 0;
        HRESULT ohr = mft.xf->ProcessOutput(0, 1, &ob, &status);
        if (ob.pEvents) ob.pEvents->Release();
        if (ohr == MF_E_TRANSFORM_NEED_MORE_INPUT) return;
        if (ohr == MF_E_TRANSFORM_STREAM_CHANGE) {
          if (mft.provides_samples && ob.pSample) ob.pSample->Release();
          if (!selectOutputType(&mft)) {
            running_ = false;
            return;
          }
          DB_LOGI(kTag, "output format " + std::to_string(mft.width) + "x" +
                            std::to_string(mft.height));
          continue;
        }
        if (FAILED(ohr)) {
          DB_LOGE(kTag, "ProcessOutput failed: " + hrStr(ohr));
          {
            std::lock_guard<std::mutex> lk(mu_);
            stats_.errors++;
          }
          if (state_) state_("error", "ProcessOutput " + hrStr(ohr));
          running_ = false;
          return;
        }
        if (ob.pSample) {
          deliver(ob.pSample);
          if (mft.provides_samples) ob.pSample->Release();
        }
      }
    };

    while (running_.load()) {
      Item item;
      if (!pop(&item, 200)) continue;
      if (item.is_config) {
        if (mft.xf) {
          mft.xf->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
          mft.reset();
        }
        if (!createMft(&mft, item.config)) {
          if (state_) state_("error", "no usable H.264 decoder MFT");
          running_ = false;
          break;
        }
        ready = true;
        {
          std::lock_guard<std::mutex> lk(mu_);
          stats_.decoder = mft.label;
        }
        DB_LOGI(kTag, "H.264 decoding started with " + mft.label + " " +
                          std::to_string(item.config.width) + "x" +
                          std::to_string(item.config.height));
        if (state_) state_("configured", mft.label);
        continue;
      }
      if (!ready) continue;
      ComPtr<IMFSample> sample;
      if (!makeSample(item.au, sample.put())) continue;
      captures.emplace_back(item.au.dts, item.au.capture_ms);
      if (captures.size() > 64) captures.pop_front();
      HRESULT ihr = mft.xf->ProcessInput(mft.in_id, sample.get(), 0);
      if (ihr == MF_E_NOTACCEPTING) {
        drain();
        ihr = mft.xf->ProcessInput(mft.in_id, sample.get(), 0);
      }
      if (FAILED(ihr)) {
        DB_LOGW(kTag, "ProcessInput failed: " + hrStr(ihr));
        std::lock_guard<std::mutex> lk(mu_);
        stats_.errors++;
        continue;
      }
      drain();
    }
    if (mft.xf) {
      mft.xf->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
      mft.xf->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    }
  }
  MFShutdown();
  if (co_ok) ::CoUninitialize();
  running_ = false;
  DB_LOGI(kTag, "decoding thread stopped");
}

}  // namespace db
