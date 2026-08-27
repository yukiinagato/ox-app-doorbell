// ホスト開発用ランナー: 1 プロセス = 1 子機。実機殻 (WPF/Android/iOS) の代わりに
// macOS/Linux 上で Node を起動して mesh/管理画面/API を触るためのツール。
//   ./doorbell_host --data /tmp/n1 --name front --role door_station --door d_front \
//                   --listen 127.0.0.1:47172 --http 47180 --psk <64hex> [--seed host:port]
#include <csignal>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "node/node.h"
#include "util/common.h"
#include "util/log.h"

static volatile std::sig_atomic_t g_stop = 0;
static void onSig(int) { g_stop = 1; }

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
    else continue;
    i++;
  }
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
