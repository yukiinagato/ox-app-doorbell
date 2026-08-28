// 内蔵 HTTP サーバ実装 (CivetWeb ラッパ)。httpd.h の仕様に従う:
//  - static 資産 → /snapshot.jpg → /stream.mjpeg → route の順で振り分け
//  - route ハンドラは Runloop へ marshal して同期実行 (5s タイムアウトで 503)
//  - 認証ゲートは civetweb スレッド上で呼ぶ (public_prefixes は素通し)
#include "httpd/httpd.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>

#include "civetweb.h"
#include "util/log.h"

namespace db {

namespace {

constexpr int64_t kHandlerTimeoutMs = 5000;  // route ハンドラの同期待ち上限
constexpr size_t kMaxBodyBytes = 8 * 1024 * 1024;  // 暴走防止
// /stream.mp4: init segment の初回待ち上限 (エンコーダは購読者が付いてから起動する —
// 殻の wanted ポーリング (5s) + エンコーダ初期化 + 最初の SPS/PPS 到着ぶんを見込む)
constexpr int kMp4FirstChunkTimeoutMs = 15000;

int hexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// query/form 用 URL デコード ('+' は空白)。不正な %xx はそのまま残す。
std::string urlDecode(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); i++) {
    char c = s[i];
    if (c == '+') {
      out.push_back(' ');
    } else if (c == '%' && i + 2 < s.size() && hexVal(s[i + 1]) >= 0 && hexVal(s[i + 2]) >= 0) {
      out.push_back(static_cast<char>((hexVal(s[i + 1]) << 4) | hexVal(s[i + 2])));
      i += 2;
    } else {
      out.push_back(c);
    }
  }
  return out;
}

// "k=v&k2=v2" 形式から key を検索 (キー・値とも URL デコードして比較/返却)
bool findParam(const std::string& data, const std::string& key, std::string* out) {
  size_t pos = 0;
  while (pos <= data.size()) {
    size_t amp = data.find('&', pos);
    if (amp == std::string::npos) amp = data.size();
    size_t eq = data.find('=', pos);
    std::string k, v;
    if (eq != std::string::npos && eq < amp) {
      k = urlDecode(data.substr(pos, eq - pos));
      v = urlDecode(data.substr(eq + 1, amp - eq - 1));
    } else {
      k = urlDecode(data.substr(pos, amp - pos));
    }
    if (!k.empty() && k == key) {
      *out = std::move(v);
      return true;
    }
    if (amp >= data.size()) break;
    pos = amp + 1;
  }
  return false;
}

std::string toLowerCopy(const char* s) {
  std::string out(s ? s : "");
  for (char& c : out) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }
  return out;
}

const char* statusText(int code) {
  switch (code) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 301: return "Moved Permanently";
    case 302: return "Found";
    case 304: return "Not Modified";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 409: return "Conflict";
    case 500: return "Internal Server Error";
    case 503: return "Service Unavailable";
    default: return "Status";
  }
}

}  // namespace

// ---------- HttpReq ----------

std::string HttpReq::param(const std::string& key, const std::string& def) const {
  std::string v;
  if (findParam(query, key, &v)) return v;
  auto it = headers.find("content-type");
  if (it != headers.end() &&
      it->second.find("application/x-www-form-urlencoded") != std::string::npos) {
    if (findParam(body, key, &v)) return v;
  }
  return def;
}

std::string HttpReq::cookie(const std::string& name) const {
  auto it = headers.find("cookie");
  if (it == headers.end()) return "";
  const std::string& h = it->second;
  size_t pos = 0;
  while (pos < h.size()) {
    size_t sc = h.find(';', pos);
    if (sc == std::string::npos) sc = h.size();
    size_t b = pos;
    while (b < sc && (h[b] == ' ' || h[b] == '\t')) b++;
    size_t e = sc;
    while (e > b && (h[e - 1] == ' ' || h[e - 1] == '\t')) e--;
    size_t eq = h.find('=', b);
    if (eq != std::string::npos && eq < e && h.compare(b, eq - b, name) == 0) {
      return h.substr(eq + 1, e - eq - 1);
    }
    pos = sc + 1;
  }
  return "";
}

// ---------- HttpResp ----------

HttpResp HttpResp::json(const std::string& body, int status) {
  HttpResp r;
  r.status = status;
  r.content_type = "application/json; charset=utf-8";
  r.body = body;
  return r;
}

HttpResp HttpResp::text(const std::string& body, int status) {
  HttpResp r;
  r.status = status;
  r.content_type = "text/plain; charset=utf-8";
  r.body = body;
  return r;
}

HttpResp HttpResp::notFound() { return text("not found", 404); }

// ---------- Httpd::Impl ----------

struct Httpd::Impl {
  explicit Impl(Runloop& l) : loop(l) {}

  Runloop& loop;
  struct mg_context* ctx = nullptr;
  int port = 0;
  std::atomic<bool> stopping{false};

  // 登録テーブル (civetweb スレッドから読まれる) — mu で保護
  std::mutex mu;
  struct Route {
    std::string method;
    std::string path;  // prefix=true のとき末尾 '*' を除いた前缀
    bool prefix = false;
    Handler h;
  };
  std::vector<Route> routes;
  struct Asset {
    std::string content_type;
    Bytes content;
  };
  std::map<std::string, Asset> statics;
  std::function<Bytes()> jpeg_provider;
  int stream_fps = 8;
  std::function<Mp4Pull()> mp4_provider;
  std::function<bool(const HttpReq&)> gate;
  std::vector<std::string> public_prefixes;
};

namespace {

// リクエストを HttpReq へ変換 (body も読む — mg_read はレスポンス前に呼ぶこと)
HttpReq buildReq(struct mg_connection* conn) {
  const struct mg_request_info* ri = mg_get_request_info(conn);
  HttpReq req;
  req.method = ri->request_method ? ri->request_method : "";
  req.uri = ri->local_uri ? ri->local_uri : "";
  req.query = ri->query_string ? ri->query_string : "";
  req.remote_addr = ri->remote_addr;
  for (int i = 0; i < ri->num_headers; i++) {
    req.headers[toLowerCopy(ri->http_headers[i].name)] =
        ri->http_headers[i].value ? ri->http_headers[i].value : "";
  }
  if (ri->content_length != 0) {
    char buf[4096];
    long long want = ri->content_length;  // -1 = 不明 (EOF まで)
    for (;;) {
      int n = mg_read(conn, buf, sizeof(buf));
      if (n <= 0) break;
      req.body.append(buf, static_cast<size_t>(n));
      if (req.body.size() >= kMaxBodyBytes) break;
      if (want > 0 && static_cast<long long>(req.body.size()) >= want) break;
    }
  }
  return req;
}

// Content-Length + Connection: close で単純に書き出す
void writeResp(struct mg_connection* conn, const HttpResp& r) {
  std::string head = "HTTP/1.1 " + std::to_string(r.status) + " " + statusText(r.status) + "\r\n";
  head += "Content-Type: " + r.content_type + "\r\n";
  head += "Content-Length: " + std::to_string(r.body.size()) + "\r\n";
  head += "Connection: close\r\n";
  for (const auto& kv : r.headers) head += kv.first + ": " + kv.second + "\r\n";
  head += "\r\n";
  mg_write(conn, head.data(), head.size());
  if (!r.body.empty()) mg_write(conn, r.body.data(), r.body.size());
}

// /stream.mjpeg: provider を fps 間隔でポーリングして multipart 送信。
// 書込失敗 (切断)・stop() (provider が外れる) で終了。
int handleStream(struct mg_connection* conn, Httpd::Impl* impl) {
  std::function<Bytes()> prov;
  int fps;
  {
    std::lock_guard<std::mutex> lk(impl->mu);
    prov = impl->jpeg_provider;
    fps = impl->stream_fps;
  }
  if (!prov) {
    writeResp(conn, HttpResp::text("no frame source", 503));
    return 503;
  }
  const char* head =
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
      "Connection: close\r\n\r\n";
  if (mg_write(conn, head, std::strlen(head)) <= 0) return 200;
  const auto interval = std::chrono::milliseconds(1000 / (fps > 0 ? fps : 8));
  for (;;) {
    if (impl->stopping.load()) break;
    {
      std::lock_guard<std::mutex> lk(impl->mu);
      prov = impl->jpeg_provider;
    }
    if (!prov) break;  // stop() で外された
    Bytes frame = prov();
    if (!frame.empty()) {  // 空 = フレーム無し → 今回はスキップ (重複送信は可)
      char part[128];
      std::snprintf(part, sizeof(part),
                    "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n",
                    static_cast<unsigned>(frame.size()));
      if (mg_write(conn, part, std::strlen(part)) <= 0) break;
      if (mg_write(conn, frame.data(), frame.size()) <= 0) break;
      if (mg_write(conn, "\r\n", 2) <= 0) break;
    }
    std::this_thread::sleep_for(interval);
  }
  return 200;
}

// /stream.mp4: fMP4 ライブ配信。provider からセッション (pull) を得て、
// init segment → fragment を逐次 mg_write する。切断/停止/購読終了で終わる。
// pull は ~500ms 上限でブロックする契約 (httpd.h) — 停止フラグを小刻みに見られる。
int handleStreamMp4(struct mg_connection* conn, Httpd::Impl* impl) {
  std::function<Httpd::Mp4Pull()> provider;
  {
    std::lock_guard<std::mutex> lk(impl->mu);
    provider = impl->mp4_provider;
  }
  Httpd::Mp4Pull pull = provider ? provider() : nullptr;
  if (!pull) {
    writeResp(conn, HttpResp::text("h264 stream not available", 503));
    return 503;
  }
  // 初回チャンク (init segment) が来るまでヘッダを書かない — 来なければ 503
  Bytes chunk;
  bool ended = false;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(kMp4FirstChunkTimeoutMs);
  for (;;) {
    if (impl->stopping.load()) {
      writeResp(conn, HttpResp::text("shutting down", 503));
      return 503;
    }
    chunk = pull(&ended);
    if (!chunk.empty() || ended) break;
    if (std::chrono::steady_clock::now() >= deadline) break;
  }
  if (chunk.empty()) {
    writeResp(conn, HttpResp::text("no h264 source", 503));
    return 503;
  }
  const char* head =
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: video/mp4\r\n"
      "Cache-Control: no-store\r\n"
      "Connection: close\r\n\r\n";
  if (mg_write(conn, head, std::strlen(head)) <= 0) return 200;
  for (;;) {
    if (!chunk.empty()) {
      if (mg_write(conn, chunk.data(), chunk.size()) <= 0) break;
    } else {
      // 新 fragment 無し (pull タイムアウト) — 8 バイトの `free` box を書いて
      // 切断を検出する (ISOBMFF の頂層 free box は MSE/ffmpeg とも読み飛ばす)。
      // これが無いと「クライアントが切ったのにフレームが来ない」間ループが
      // 終われず、購読者数が減らない → エンコーダが止まらない。
      static const uint8_t kFreeBox[8] = {0, 0, 0, 8, 'f', 'r', 'e', 'e'};
      if (mg_write(conn, kFreeBox, sizeof(kFreeBox)) <= 0) break;
    }
    if (ended || impl->stopping.load()) break;
    {
      std::lock_guard<std::mutex> lk(impl->mu);
      if (!impl->mp4_provider) break;  // stop() で外された
    }
    chunk = pull(&ended);
  }
  return 200;
}

// route ハンドラを Runloop へ marshal して同期実行。タイムアウトは 503
// (ハンドラは後で走っても良い — 結果は破棄。共有状態は shared_ptr で寿命安全に)。
HttpResp runOnLoop(Httpd::Impl* impl, const Httpd::Handler& h, const HttpReq& req) {
  struct Pending {
    std::mutex m;
    std::condition_variable cv;
    bool done = false;
    HttpResp resp;
  };
  auto p = std::make_shared<Pending>();
  impl->loop.post([p, h, req] {
    HttpResp r = h(req);
    std::lock_guard<std::mutex> lk(p->m);
    p->resp = std::move(r);
    p->done = true;
    p->cv.notify_all();
  });
  std::unique_lock<std::mutex> lk(p->m);
  if (!p->cv.wait_for(lk, std::chrono::milliseconds(kHandlerTimeoutMs), [&] { return p->done; })) {
    return HttpResp::text("handler timeout", 503);
  }
  return std::move(p->resp);
}

// 全リクエストの入口 (civetweb ワーカースレッド上)
int requestHandler(struct mg_connection* conn, void* cbdata) {
  auto* impl = static_cast<Httpd::Impl*>(cbdata);
  HttpReq req = buildReq(conn);

  // --- 認証: gate 未設定なら全公開。public_prefixes (前缀一致) は素通し ---
  std::function<bool(const HttpReq&)> gate;
  {
    std::lock_guard<std::mutex> lk(impl->mu);
    if (impl->gate) {
      bool is_public = false;
      for (const auto& p : impl->public_prefixes) {
        if (req.uri.compare(0, p.size(), p) == 0) {
          is_public = true;
          break;
        }
      }
      if (!is_public) gate = impl->gate;
    }
  }
  if (gate && !gate(req)) {  // gate はロック外・civetweb スレッドで呼ぶ (ヘッダ記載通り)
    writeResp(conn, HttpResp::text("unauthorized", 401));
    return 401;
  }

  // --- 1. static 資産 (完全一致) ---
  if (req.method == "GET" || req.method == "HEAD") {
    std::lock_guard<std::mutex> lk(impl->mu);
    auto it = impl->statics.find(req.uri);
    if (it != impl->statics.end()) {
      HttpResp r;
      r.content_type = it->second.content_type;
      r.body = toString(it->second.content);
      writeResp(conn, r);
      return r.status;
    }
  }

  // --- 2. /snapshot.jpg ---
  if (req.uri == "/snapshot.jpg") {
    std::function<Bytes()> prov;
    {
      std::lock_guard<std::mutex> lk(impl->mu);
      prov = impl->jpeg_provider;
    }
    Bytes frame = prov ? prov() : Bytes{};
    if (frame.empty()) {
      writeResp(conn, HttpResp::text("no frame", 503));
      return 503;
    }
    HttpResp r;
    r.content_type = "image/jpeg";
    r.body = toString(frame);
    writeResp(conn, r);
    return 200;
  }

  // --- 3. /stream.mjpeg・/stream.mp4 ---
  if (req.uri == "/stream.mjpeg") return handleStream(conn, impl);
  if (req.uri == "/stream.mp4") return handleStreamMp4(conn, impl);

  // --- 4. route: 完全一致優先 → 前缀 ("...*") の最長一致 ---
  Httpd::Handler h;
  {
    std::lock_guard<std::mutex> lk(impl->mu);
    size_t best_len = 0;
    bool exact = false;
    for (const auto& r : impl->routes) {
      if (r.method != req.method) continue;
      if (!r.prefix) {
        if (r.path == req.uri) {
          h = r.h;
          exact = true;
          break;
        }
      } else if (!exact && req.uri.compare(0, r.path.size(), r.path) == 0 &&
                 r.path.size() >= best_len) {
        // 同長は後勝ちにしない: '>' だと同じ前缀の再登録が拾えないため '>=' で最後の登録を優先
        best_len = r.path.size();
        h = r.h;
      }
    }
  }
  if (!h) {
    writeResp(conn, HttpResp::notFound());
    return 404;
  }
  HttpResp resp = runOnLoop(impl, h, req);
  writeResp(conn, resp);
  return resp.status;
}

}  // namespace

// ---------- Httpd ----------

Httpd::Httpd(Runloop& loop) : impl_(new Impl(loop)) {}

Httpd::~Httpd() { stop(); }

bool Httpd::start(int port) {
  if (impl_->ctx) return false;  // 二重 start は不可
  impl_->stopping = false;
  std::string p = std::to_string(port);
  struct mg_callbacks cb;
  std::memset(&cb, 0, sizeof(cb));
  auto tryStart = [&](const std::string& ports) -> struct mg_context* {
    const char* opts[] = {"listening_ports", ports.c_str(),
                          "num_threads",     "4",
                          "tcp_nodelay",     "1",
                          nullptr};
    return mg_start(&cb, nullptr, opts);
  };
  // IPv4 と IPv6 を「別々のリスナー」で張る ("47180,[::]:47180")。
  // 単一 dual-stack ソケット ("+port") は iOS5 kernel で bind は通るが accept できない
  // (silent failure)。別ソケットなら IPv4 は確実に動き、IPv6 は best-effort で追加。
  std::string dual = p + ",[::]:" + p;
  struct mg_context* ctx = tryStart(dual);
  std::string mode = dual;
  if (!ctx) { ctx = tryStart(p); mode = p; }  // IPv6 を張れない環境は IPv4 のみ
  if (!ctx) {
    DB_LOGE("httpd", "mg_start failed port=" + p);
    return false;
  }
  impl_->ctx = ctx;
  impl_->port = port;
  mg_set_request_handler(ctx, "/", &requestHandler, impl_.get());
  DB_LOGI("httpd", "listening on " + mode);
  return true;
}

void Httpd::stop() {
  if (!impl_->ctx) return;
  impl_->stopping = true;
  {
    // provider を外す → 進行中の stream ループが終了し、mg_stop が完了できる。
    // (provider の寿命が Httpd より先に尽きないことも保証される)
    std::lock_guard<std::mutex> lk(impl_->mu);
    impl_->jpeg_provider = nullptr;
    impl_->mp4_provider = nullptr;
  }
  mg_stop(impl_->ctx);  // 進行中の接続完了を待つ
  impl_->ctx = nullptr;
  DB_LOGI("httpd", "stopped");
}

int Httpd::port() const { return impl_->port; }

void Httpd::route(const std::string& method, const std::string& path, Handler h) {
  Impl::Route r;
  r.method = method;
  if (!path.empty() && path.back() == '*') {
    r.prefix = true;
    r.path = path.substr(0, path.size() - 1);
  } else {
    r.path = path;
  }
  r.h = std::move(h);
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->routes.push_back(std::move(r));
}

void Httpd::setStatic(const std::string& path, const std::string& content_type, Bytes content) {
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->statics[path] = Impl::Asset{content_type, std::move(content)};
}

void Httpd::setJpegProvider(std::function<Bytes()> provider, int stream_fps) {
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->jpeg_provider = std::move(provider);
  impl_->stream_fps = stream_fps;
}

void Httpd::setMp4Provider(std::function<Mp4Pull()> provider) {
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->mp4_provider = std::move(provider);
}

void Httpd::setAuth(std::function<bool(const HttpReq&)> gate,
                    std::vector<std::string> public_prefixes) {
  std::lock_guard<std::mutex> lk(impl_->mu);
  impl_->gate = std::move(gate);
  impl_->public_prefixes = std::move(public_prefixes);
}

}  // namespace db
