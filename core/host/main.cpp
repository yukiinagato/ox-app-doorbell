// ホスト開発用ランナー: 1 プロセス = 1 子機。実機殻 (WPF/Android/iOS) の代わりに
// macOS/Linux 上で Node を起動して mesh/管理画面/API を触るためのツール。
//   ./doorbell_host --data /tmp/n1 --name front --role door_station --door d_front \
//                   --listen 127.0.0.1:47172 --http 47180 --psk <64hex> [--seed host:port]
#include <unistd.h>

#include <csignal>
#include <cstdio>
#include <cstdlib>
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

// シェル単引用 ('...' 内の ' は '\'' に割る)
static std::string shq(const std::string& s) {
  std::string out = "'";
  for (char c : s) {
    if (c == '\'') out += "'\\''";
    else out.push_back(c);
  }
  out += "'";
  return out;
}

// HTTPS: curl コマンド実装 (開発ランナー用 — Mac 上で本物の Telegram への手動テストが
// できる)。実機殻では db_platform.https_request (WinHTTP/OkHttp/URLSession) が同役。
// done は任意スレッド可の契約なので専用スレッドで呼ぶ。
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

    // 応答本文はファイルへ、stdout には HTTP 状態コードだけを書かせる
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
  for (int i = 1; i < argc; i++)
    if (std::string(argv[i]) == "--sip-null") o.sip_null_audio = true;
  if (!psk_hex.empty()) {
    db::Bytes psk;
    if (!db::hexDecode(psk_hex, psk) || psk.size() != 32) {
      std::fprintf(stderr, "--psk は 64 hex\n");
      return 2;
    }
    std::copy(psk.begin(), psk.end(), o.psk.begin());
  } else {
    o.psk.fill(0x5a);  // 開発既定 (本番では配対で配布)
  }
  if (o.advertise_addr.empty()) o.advertise_addr = o.listen_addr;

  db::Node node(o);
  node.setHttpsFn(curlHttps);  // Telegram ブリッジ用 (leader 就任 + bot_token 設定時のみ使われる)
  node.setUiEventCb([](const std::string& ev) { DB_LOGI("ui", ev); });
  node.setTtsCb([](const std::string& text, const std::string& lang) {
    DB_LOGI("tts", "[" + lang + "] " + text);
  });
  if (!node.start()) {
    std::fprintf(stderr, "start 失敗\n");
    return 1;
  }
  std::printf("node %s  admin: http://127.0.0.1:%d/admin/  (Ctrl+C で終了)\n",
              node.nodeId().substr(0, 8).c_str(), o.http_port);
  std::signal(SIGINT, onSig);
  std::signal(SIGTERM, onSig);
  while (!g_stop) {
    struct timespec ts { 0, 200 * 1000 * 1000 };
    nanosleep(&ts, nullptr);
  }
  node.stop();
  return 0;
}
