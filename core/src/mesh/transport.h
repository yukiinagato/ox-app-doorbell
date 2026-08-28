// トランスポート抽象。
//  - TcpTransport:   実機用 (POSIX/Winsock)。ストリームを 4B BE length-prefix でフレーム化。
//  - InMemTransport: テスト用。プロセス内レジストリ (InMemNet) 経由で配送し、
//                    落とし/遅延/分断の故障注入ができる。
// 暗号化 (PSK AEAD) はこの層の上 (mesh の SecureChannel) で行う。
// すべてのコールバックは Runloop 上で呼ばれること (実装側が post する)。
#pragma once

#include <functional>
#include <memory>
#include <string>

#include "util/common.h"

namespace db {

class Runloop;

class IConn {
 public:
  virtual ~IConn() = default;
  // 1 フレーム送信 (フレーム化は実装の責務)。失敗は on_close で通知。
  virtual void send(const Bytes& frame) = 0;
  virtual void close() = 0;
  virtual std::string remoteAddr() const = 0;
  // 設定後に受信開始。on_frame は 1 フレーム毎。
  virtual void setCallbacks(std::function<void(const Bytes&)> on_frame,
                            std::function<void()> on_close) = 0;
};
using ConnPtr = std::shared_ptr<IConn>;

class ITransport {
 public:
  virtual ~ITransport() = default;
  // addr 形式: "host:port" (InMem では任意の一意文字列 "nodeA:1")
  virtual bool listen(const std::string& addr, std::function<void(ConnPtr)> on_accept) = 0;
  virtual void stopListening() = 0;
  // 接続。失敗時は nullptr を cb に渡す。
  virtual void connect(const std::string& addr, std::function<void(ConnPtr)> cb) = 0;
  virtual std::string listenAddr() const = 0;
};

// ノード発見 (UDP beacon / mDNS / InMem)。
struct DiscoveredPeer {
  std::string node_id;
  std::string addr;
};

// 未配対デバイスの平文告知 (配対 §1.6 拡張)。PSK を持たないので MAC は付かない。
// pk = X25519 公開鍵 hex — 招待側はこれに向けて {psk,seeds,cfg} を封緘する。
struct PairBeacon {
  std::string id;
  std::string addr;
  std::string name;  // 表示名 (機種/役割)
  std::string role;
  std::string pk;    // X25519 公開鍵 (64 hex)
};

class IDiscovery {
 public:
  virtual ~IDiscovery() = default;
  virtual void start(std::function<void(const DiscoveredPeer&)> on_found) = 0;
  // 自分の存在を周期告知 (実装側が Runloop タイマーで回す)
  virtual void announce(const std::string& node_id, const std::string& addr) = 0;
  virtual void stop() = 0;

  // --- 配対発見 (既定 no-op — 実装は UdpBeacon / InMemDiscovery) ---
  // 未配対時: 周期告知を PAIR-ANNOUNCE に切り替える (on=true)。paired 化後は off。
  virtual void setPairAnnounce(bool /*on*/, const std::string& /*name*/,
                               const std::string& /*role*/, const std::string& /*pk*/) {}
  // 近隣の未配対デバイス発見コールバック (paired ノードのみ設定)。
  virtual void setPairFound(std::function<void(const PairBeacon&)> /*cb*/) {}
};

}  // namespace db
