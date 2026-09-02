



#include "media/camera_win.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "media/frame_bus.h"
#include "util/log.h"

namespace db {

namespace {

constexpr const char* kTag = "camera";


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

std::string wideToUtf8(const wchar_t* w) {
  if (!w) return "";
  int n = ::WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (n <= 1) return "";
  std::string out(static_cast<size_t>(n - 1), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w, -1, &out[0], n, nullptr, nullptr);
  return out;
}

std::string lowerAscii(std::string s) {
  for (char& c : s)
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  return s;
}

std::string hrStr(HRESULT hr) {
  char buf[16];
  std::snprintf(buf, sizeof(buf), "0x%08lx", static_cast<unsigned long>(hr));
  return buf;
}


bool frameSize(IMFMediaType* mt, UINT32* w, UINT32* h) {
  UINT64 sz = 0;
  if (FAILED(mt->GetUINT64(MF_MT_FRAME_SIZE, &sz))) return false;
  *w = static_cast<UINT32>(sz >> 32);
  *h = static_cast<UINT32>(sz & 0xffffffff);
  return true;
}


struct Negotiated {
  int format = 1;  // RawFrame::format (1=NV12, 2=YUY2)
  int w = 0, h = 0, stride = 0;
};

bool queryCurrent(IMFSourceReader* reader, Negotiated* out) {
  ComPtr<IMFMediaType> cur;
  if (FAILED(reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, cur.put())))
    return false;
  GUID sub{};
  if (FAILED(cur->GetGUID(MF_MT_SUBTYPE, &sub))) return false;
  if (sub == MFVideoFormat_NV12) {
    out->format = 1;
  } else if (sub == MFVideoFormat_YUY2) {
    out->format = 2;
  } else {
    return false;
  }
  UINT32 w = 0, h = 0;
  if (!frameSize(cur.get(), &w, &h) || w == 0 || h == 0) return false;
  out->w = static_cast<int>(w);
  out->h = static_cast<int>(h);
  UINT32 st = 0;
  if (SUCCEEDED(cur->GetUINT32(MF_MT_DEFAULT_STRIDE, &st)) && static_cast<INT32>(st) > 0) {
    out->stride = static_cast<int>(st);
  } else {
    out->stride = out->format == 2 ? out->w * 2 : out->w;
  }
  return true;
}


bool negotiate(IMFSourceReader* reader, int tw, int th, Negotiated* out) {
  ComPtr<IMFMediaType> best;
  long best_score = -1;
  for (DWORD i = 0;; i++) {
    ComPtr<IMFMediaType> mt;
    HRESULT hr =
        reader->GetNativeMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, mt.put());
    if (hr == MF_E_NO_MORE_TYPES || FAILED(hr)) break;
    GUID sub{};
    if (FAILED(mt->GetGUID(MF_MT_SUBTYPE, &sub))) continue;
    bool nv12 = (sub == MFVideoFormat_NV12);
    if (!nv12 && sub != MFVideoFormat_YUY2) continue;
    UINT32 w = 0, h = 0;
    if (!frameSize(mt.get(), &w, &h)) continue;

    long score = std::labs(static_cast<long>(w) - tw) + std::labs(static_cast<long>(h) - th);
    score = score * 2 + (nv12 ? 0 : 1);
    if (best_score < 0 || score < best_score) {
      best_score = score;
      best.reset();
      *best.put() = mt.get();
      best.get()->AddRef();
    }
  }
  if (best &&
      SUCCEEDED(reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr,
                                            best.get()))) {
    return queryCurrent(reader, out);
  }

  for (const GUID* sub : {&MFVideoFormat_NV12, &MFVideoFormat_YUY2}) {
    ComPtr<IMFMediaType> want;
    if (FAILED(MFCreateMediaType(want.put()))) return false;
    want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    want->SetGUID(MF_MT_SUBTYPE, *sub);
    if (SUCCEEDED(reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr,
                                              want.get()))) {
      return queryCurrent(reader, out);
    }
  }
  return false;
}


HRESULT openSource(const std::string& hint, IMFMediaSource** out, std::string* picked_name) {
  ComPtr<IMFAttributes> attrs;
  HRESULT hr = MFCreateAttributes(attrs.put(), 1);
  if (FAILED(hr)) return hr;
  hr = attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                      MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  if (FAILED(hr)) return hr;

  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  hr = MFEnumDeviceSources(attrs.get(), &devices, &count);
  if (FAILED(hr)) return hr;
  if (count == 0) {
    ::CoTaskMemFree(devices);
    return MF_E_NOT_FOUND;
  }

  UINT32 pick = 0;
  std::string want = lowerAscii(hint);
  bool matched = want.empty();
  std::vector<std::string> names(count);
  for (UINT32 i = 0; i < count; i++) {
    wchar_t* wname = nullptr;
    UINT32 len = 0;
    if (SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,
                                                 &wname, &len))) {
      names[i] = wideToUtf8(wname);
      ::CoTaskMemFree(wname);
    }
    if (!matched && lowerAscii(names[i]).find(want) != std::string::npos) {
      pick = i;
      matched = true;
    }
  }

  if (!matched)
    DB_LOGW(kTag, "device_hint '" + hint + "' did not match; using first device '" + names[0] + "'");

  hr = devices[pick]->ActivateObject(IID_IMFMediaSource, reinterpret_cast<void**>(out));
  *picked_name = names[pick];
  for (UINT32 i = 0; i < count; i++) devices[i]->Release();
  ::CoTaskMemFree(devices);
  return hr;
}

}  // namespace

bool CameraWin::start(const std::string& device_hint, int target_w, int target_h) {
  stop();
  running_ = true;
  th_ = std::thread([this, device_hint, target_w, target_h] {
    run(device_hint, target_w, target_h);
  });
  return true;
}

void CameraWin::stop() {
  running_ = false;
  if (th_.joinable()) th_.join();
}

void CameraWin::run(std::string hint, int tw, int th) {

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
    ComPtr<IMFMediaSource> source;
    ComPtr<IMFSourceReader> reader;
    std::string name;
    hr = openSource(hint, source.put(), &name);
    if (FAILED(hr)) {
      DB_LOGE(kTag, "cannot open camera (hint='" + hint + "'): " + hrStr(hr));
    } else if (FAILED(hr = MFCreateSourceReaderFromMediaSource(source.get(), nullptr,
                                                               reader.put()))) {
      DB_LOGE(kTag, "SourceReader creation failed: " + hrStr(hr));
    } else {
      Negotiated neg;
      if (!negotiate(reader.get(), tw, th, &neg)) {
        DB_LOGE(kTag, "MediaType negotiation failed for both NV12 and YUY2: " + name);
      } else {
        DB_LOGI(kTag, "capture started: " + name + " " + std::to_string(neg.w) + "x" +
                          std::to_string(neg.h) + (neg.format == 1 ? " NV12" : " YUY2"));
        while (running_.load()) {
          DWORD stream = 0, flags = 0;
          LONGLONG ts = 0;
          ComPtr<IMFSample> sample;
          hr = reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &stream, &flags,
                                  &ts, sample.put());
          if (FAILED(hr)) {
            DB_LOGE(kTag, "ReadSample failed: " + hrStr(hr));
            break;
          }
          if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
            DB_LOGW(kTag, "camera stream ended");
            break;
          }
          if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
            if (!queryCurrent(reader.get(), &neg)) {
              DB_LOGE(kTag, "failed to query MediaType after a format change");
              break;
            }
          }
          if (!sample) continue;
          ComPtr<IMFMediaBuffer> buf;
          if (FAILED(sample->ConvertToContiguousBuffer(buf.put()))) continue;
          BYTE* p = nullptr;
          DWORD maxlen = 0, curlen = 0;
          if (SUCCEEDED(buf->Lock(&p, &maxlen, &curlen))) {
            RawFrame f;
            f.format = neg.format;
            f.w = neg.w;
            f.h = neg.h;
            f.stride = neg.stride;
            f.ts_ms = ts / 10000;  // 100ns → ms
            f.data.assign(p, p + curlen);
            buf->Unlock();
            sink_(std::move(f));
          }
        }
      }
    }
    if (source) source->Shutdown();
  }

  MFShutdown();
  if (co_ok) ::CoUninitialize();
  running_ = false;
  DB_LOGI(kTag, "capture thread stopped");
}

}  // namespace db
