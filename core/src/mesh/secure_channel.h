// PSK 認証付き暗号チャネル (設計書 mesh §1.3)。ITransport の IConn 1 本の上に載せる。
//  - 平文握手: HS1/HS2 で 32B ランダム nonce と node_id を交換 (PSK は線上に流さない)
//  - session_key = BLAKE2b-256(key=psk, input=nonceA||nonceB||idA||idB)  (A=接続発起側)
//  - CONFIRM: 双方が session_key の HMAC を交換して鍵一致を確認 → PSK 不一致は確立前に拒否
//  - 以降の全フレーム: XChaCha20-Poly1305 AEAD。nonce は方向バイト + 単調フレーム番号
//    (方向分離 + 再生防止: 受信番号が単調増加でなければ即切断。欠番は許容 = 損失耐性)
//  - 復号失敗・形式不正は即切断
// スレッド: 全て Runloop 上 (IConn のコールバックが Runloop 上で来る前提)。
#pragma once

#include <array>
#include <cstdint>
#include <deque>
#include <memory>
#include <string>

#include "mesh/transport.h"
#include "util/runloop.h"

namespace db {

// 生フレーム 1 バイト目の種別 (SecureChannel と mesh の JOIN 経路で共有)
enum : uint8_t {
  kFrameHs1 = 0x01,      // [type][nonce 32][node_id...]  (発起側 → 受理側)
  kFrameHs2 = 0x02,      // [type][nonce 32][node_id...]  (受理側 → 発起側)
  kFrameConfirm = 0x03,  // [type][dir 1][hmac 32]
  kFrameData = 0x10,     // [type][dir 1][frame_no 8BE][mac 16][cipher...]
  kFrameJoin = 0x40,     // [type][JSON...]  平文の配対プロトコル (mesh 側で処理)
};

class SecureChannel : public std::enable_shared_from_this<SecureChannel> {
 public:
  struct Callbacks {
    std::function<void()> on_established;              // 握手 + 鍵確認 完了
    std::function<void(const std::string&)> on_message;  // 復号済み平文 (JSON)
    std::function<void()> on_close;                    // 切断 (確立前の失敗含む, 1 回だけ)
  };

  // initiator: 接続発起側 (= 設計上の A)。handshake_timeout_ms 以内に確立しなければ切断。
  SecureChannel(Runloop& loop, ConnPtr conn, bool initiator, const std::array<uint8_t, 32>& psk,
                std::string self_id, int64_t handshake_timeout_ms);
  ~SecureChannel();

  void setCallbacks(Callbacks cbs) { cbs_ = std::move(cbs); }

  // conn のコールバックを奪い、発起側なら HS1 を送る
  void start();
  // 受理側で mesh が先読みした初回フレームの注入 (種別判定のため mesh が 1 枚目を覗く)
  void handleRawFrame(const Bytes& f);

  // AEAD 封緘して送出。確立前はキューされ、確立時にまとめて流れる。
  void sendMessage(const std::string& msg_json);
  void close();

  bool established() const { return state_ == State::kOpen; }
  const std::string& peerId() const { return peer_id_; }
  bool isInitiator() const { return initiator_; }
  std::string remoteAddr() const { return conn_ ? conn_->remoteAddr() : ""; }

 private:
  enum class State { kAwaitHs, kAwaitConfirm, kOpen, kClosed };

  void sendHello_(uint8_t type);
  void deriveKey_();
  void sendConfirm_();
  bool checkConfirm_(const Bytes& f);
  void becomeOpen_();
  void fail_(const char* why);
  void notifyClose_();
  Bytes confirmMac_(uint8_t dir) const;

  Runloop& loop_;
  ConnPtr conn_;
  bool initiator_;
  std::array<uint8_t, 32> psk_;
  std::string self_id_;
  std::string peer_id_;
  int64_t hs_timeout_ms_;
  uint64_t timeout_id_ = 0;

  State state_ = State::kAwaitHs;
  std::array<uint8_t, 32> nonce_a_{};  // 発起側 nonce
  std::array<uint8_t, 32> nonce_b_{};  // 受理側 nonce
  std::array<uint8_t, 32> key_{};      // session_key
  bool key_ready_ = false;
  bool peer_confirmed_ = false;

  uint64_t send_no_ = 0;       // 次に使う送信フレーム番号
  uint64_t recv_min_no_ = 0;   // 受信で許容する最小フレーム番号 (再生防止, 欠番許容)
  std::deque<std::string> pending_;  // 確立前の送信キュー
  Callbacks cbs_;
  bool close_notified_ = false;
};

}  // namespace db
