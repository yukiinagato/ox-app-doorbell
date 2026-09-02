// Host development runner: one process represents one node. It exercises the mesh, Admin, and
// APIs on macOS/Linux without a WPF, Android, or Apple platform shell.
//   ./doorbell_host --data /tmp/n1 --name front --role door_station --door d_front \
//                   --listen 127.0.0.1:47172 --http 47180 --psk <64hex> [--seed host:port]
// Asset import: --add-asset <file> [--asset-type <mime>] [--asset-label <name>].

#include <unistd.h>

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cctype>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "node/node.h"
#include "util/common.h"
#include "util/json.h"
#include "util/log.h"

static volatile std::sig_atomic_t g_stop = 0;
static void onSig(int) { g_stop = 1; }

// Quote one shell argument for the development-only curl transport.
static std::string shq(const std::string& s) {
  std::string out = "'";
  for (char c : s) {
    if (c == '\'') out += "'\\''";
    else out.push_back(c);
  }
  out += "'";
  return out;
}
// Development HTTPS transport. Platform clients use their native platform_v2 transport instead.
// The completion callback may run on any thread, so curl executes on a dedicated worker.
static void curlHttps(const std::string& method, const std::string& url,
                      const std::string& headers_json, const db::Bytes& body,
                      std::function<void(int, std::string)> done) {
  std::thread([method, url, headers_json, body, done] {
    char body_path[] = "/tmp/db-https-body-XXXXXX";
    char resp_path[] = "/tmp/db-https-resp-XXXXXX";
    int bfd = ::mkstemp(body_path);
    int rfd = ::mkstemp(resp_path);
    if (bfd < 0 || rfd < 0) {
      if (bfd >= 0) ::close(bfd);
      if (rfd >= 0) ::close(rfd);
      done(-1, "");
      return;
    }
    ::close(rfd);
    if (!body.empty() &&
        ::write(bfd, body.data(), body.size()) != static_cast<ssize_t>(body.size())) {
      ::close(bfd);
      ::unlink(body_path);
      ::unlink(resp_path);
      done(-1, "");
      return;
    }
    ::close(bfd);

    // Store the response body in a file and reserve stdout for curl's HTTP status code.
    std::string cmd = "curl -sS --max-time 40 -o " + shq(resp_path) +
                      " -w '%{http_code}' -X " + shq(method);
    auto hdrs = db::json::parse(headers_json.empty() ? "{}" : headers_json);
    cJSON* h = nullptr;
    cJSON_ArrayForEach(h, hdrs.get()) {
      if (h->string && cJSON_IsString(h))
        cmd += " -H " + shq(std::string(h->string) + ": " + h->valuestring);
    }
    if (!body.empty()) cmd += " --data-binary @" + shq(body_path);
    cmd += " " + shq(url);

    int status = -1;
    std::string resp;
    FILE* p = ::popen(cmd.c_str(), "r");
    if (p) {
      char code[16] = {0};
      size_t n = std::fread(code, 1, sizeof(code) - 1, p);
      const int rc = ::pclose(p);
      if (rc == 0 && n > 0) status = std::atoi(code);
      if (status > 0) {
        FILE* rf = std::fopen(resp_path, "rb");
        if (rf) {
          char buf[4096];
          size_t m;
          while ((m = std::fread(buf, 1, sizeof(buf), rf)) > 0) resp.append(buf, m);
          std::fclose(rf);
        }
      }
    }
    ::unlink(body_path);
    ::unlink(resp_path);
    done(status > 0 ? status : -1, std::move(resp));
  }).detach();
}

int main(int argc, char** argv) {
  db::NodeOptions o;
  o.data_dir = "/tmp/doorbell-host";
  o.listen_addr = "0.0.0.0:47172";
  o.http_port = 47180;
  std::string psk_hex;
  for (int i = 1; i < argc - 1; i++) {
    std::string k = argv[i], v = argv[i + 1];
    if (k == "--data") o.data_dir = v;
    else if (k == "--name") o.name = v;
    else if (k == "--role") o.role = v;
    else if (k == "--door") o.door = v;
    else if (k == "--listen") o.listen_addr = v;
    else if (k == "--advertise") o.advertise_addr = v;
    else if (k == "--http") o.http_port = std::atoi(v.c_str());
    else if (k == "--seed") o.seed_peers.push_back(v);
    else if (k == "--psk") psk_hex = v;
    else if (k == "--sip-user") o.sip_user = v;
    else if (k == "--sip-pass") o.sip_pass = v;
    else if (k == "--caps") o.caps_json = v;
    else continue;
    i++;
  }
  // Start a delayed one-way monitor or two-way answer call for development test scripts.
  std::string monitor_call, monitor_mode = "monitor";
  int monitor_delay_ms = 2000;
  for (int i = 1; i < argc - 1; i++) {
    std::string k = argv[i];
    if (k == "--monitor-call") monitor_call = argv[i + 1];
    else if (k == "--answer-call") { monitor_call = argv[i + 1]; monitor_mode = "answer"; }
    else if (k == "--monitor-delay-ms") monitor_delay_ms = std::atoi(argv[i + 1]);
  }
  for (int i = 1; i < argc; i++)
    if (std::string(argv[i]) == "--sip-null") o.sip_null_audio = true;
  if (!psk_hex.empty()) {
    db::Bytes psk;
    if (!db::hexDecode(psk_hex, psk) || psk.size() != 32) {
      std::fprintf(stderr, "--psk must contain 64 hexadecimal characters\n");
      return 2;
    }
    std::copy(psk.begin(), psk.end(), o.psk.begin());
  } else {
    o.psk.fill(0x5a);  // Development default; production obtains this value through pairing.
  }
  if (o.advertise_addr.empty()) o.advertise_addr = o.listen_addr;

  bool fake_camera = false;
  for (int i = 1; i < argc; i++)
    if (std::string(argv[i]) == "--fake-camera") fake_camera = true;

  // --add-asset <file> [--asset-type <mime>] [--asset-label <name>]:
  // register one shared asset after startup and print its content hash.
  std::string add_asset_path, asset_type, asset_label;
  for (int i = 1; i < argc - 1; i++) {
    std::string k = argv[i];
    if (k == "--add-asset") add_asset_path = argv[i + 1];
    else if (k == "--asset-type") asset_type = argv[i + 1];
    else if (k == "--asset-label") asset_label = argv[i + 1];
  }

  db::Node node(o);
  node.setHttpsFn(curlHttps);  // Used only by development integrations that require HTTPS.
  node.setUiEventCb([](const std::string& ev) { DB_LOGI("ui", ev); });
  node.setTtsCb([](const std::string& text, const std::string& lang) {
    DB_LOGI("tts", "[" + lang + "] " + text);
  });
  if (!node.start()) {
    std::fprintf(stderr, "failed to start node\n");
    return 1;
  }
  // Feed a static synthetic frame at 2 fps for snapshot and media-path development.
  std::thread fake_th;
  if (fake_camera) {
    fake_th = std::thread([&node] {
      const int w = 640, h = 480;
      std::vector<uint8_t> f(static_cast<size_t>(w) * h * 4);
      for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
          size_t i = (static_cast<size_t>(y) * w + x) * 4;
          f[i] = static_cast<uint8_t>(255 * x / w);        // B
          f[i + 1] = static_cast<uint8_t>(255 * y / h);    // G
          f[i + 2] = 140;                                  // R
          f[i + 3] = 255;
        }
      int64_t ts = 0;
      while (!g_stop) {
        node.pushCameraFrame(f.data(), 3 /*BGRA*/, w, h, w * 4, ts += 500);
        struct timespec t { 0, 500 * 1000 * 1000 };
        nanosleep(&t, nullptr);
      }
    });
  }

  // Place a delayed direct SIP call with the requested monitor/answer mode.
  std::thread mon_th;
  if (!monitor_call.empty()) {
    mon_th = std::thread([&node, monitor_call, monitor_mode, monitor_delay_ms] {
      struct timespec t{monitor_delay_ms / 1000,
                        static_cast<long>(monitor_delay_ms % 1000) * 1000 * 1000};
      nanosleep(&t, nullptr);
      DB_LOGI("host", monitor_mode + "-call -> " + monitor_call);
      node.sipCall(monitor_call, monitor_mode);
    });
  }

  // Asset ledger entries replicate through the configuration CRDT.
  if (!add_asset_path.empty()) {
    db::Bytes data;
    if (!db::readFileBytes(add_asset_path, data)) {
      std::fprintf(stderr, "--add-asset: cannot read: %s\n", add_asset_path.c_str());
    } else {
      if (asset_type.empty()) {  // Infer only a supported MIME type from the extension.
        const std::string p = add_asset_path;
        auto ends = [&p](const char* s) {
          const size_t n = std::strlen(s);
          return p.size() >= n && p.compare(p.size() - n, n, s) == 0;
        };
        if (ends(".jpg") || ends(".jpeg")) asset_type = "image/jpeg";
        else if (ends(".png")) asset_type = "image/png";
        else if (ends(".mp3")) asset_type = "audio/mpeg";
        else if (ends(".wav")) asset_type = "audio/wav";
      }
      if (asset_label.empty()) {
        const size_t slash = add_asset_path.find_last_of('/');
        asset_label = slash == std::string::npos ? add_asset_path
                                                 : add_asset_path.substr(slash + 1);
      }
      const std::string hash = node.addAsset(data, asset_type, asset_label);
      if (hash.empty()) {
        std::fprintf(stderr,
                     "--add-asset: rejected (over 3 MB or unsupported type: '%s')\n"
                     "  supported types: image/jpeg image/png audio/mpeg audio/wav"
                     " — set one explicitly with --asset-type\n",
                     asset_type.c_str());
      } else {
        // Flush so scripts can consume the first output line immediately.
        std::printf("asset %s  (%zu bytes, %s, \"%s\")\n", hash.c_str(), data.size(),
                    asset_type.c_str(), asset_label.c_str());
        std::fflush(stdout);
      }
    }
  }

  std::printf("node %s  admin: http://127.0.0.1:%d/admin/  (Ctrl+C to stop)\n",
              node.nodeId().substr(0, 8).c_str(), o.http_port);
  std::signal(SIGINT, onSig);
  std::signal(SIGTERM, onSig);
  while (!g_stop) {
    struct timespec ts { 0, 200 * 1000 * 1000 };
    nanosleep(&ts, nullptr);
  }
  if (fake_th.joinable()) fake_th.join();
  if (mon_th.joinable()) mon_th.join();
  node.stop();
  return 0;
}
