// 極小 MQTT 3.1.1 クライアント (QoS0 専用・外部依存なし) — HA ブリッジ用。
//  - パケットの encode/decode は純関数 (db::mqtt::*) — 単体テスト可能
//  - MqttClient: 専用ソケットスレッド 1 本 (socket_compat の net:: — Windows 移植可)。
//    コールバック (on_connected/on_disconnected/on_message) は Runloop へ post。
//    切断時は 2s→5s→15s→30s(cap) のバックオフで stop まで再接続し続ける。
//  - 対応: CONNECT (LWT/user/pass/keepalive) / CONNACK / PUBLISH QoS0 (retain, 受信も) /
//    SUBSCRIBE QoS0 (SUBACK) / PINGREQ/PINGRESP / DISCONNECT
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "util/common.h"
#include "util/runloop.h"

namespace db {
namespace mqtt {

// パケット型 (固定ヘッダ上位 4bit)
enum PacketType : uint8_t {
  kConnect = 1,
  kConnack = 2,
  kPublish = 3,
  kSubscribe = 8,
  kSuback = 9,
  kPingReq = 12,
  kPingResp = 13,
  kDisconnect = 14,
};

struct ConnectOpts {
  std::string client_id;
  std::string username;      // 空 = 認証なし
  std::string password;      // username 非空時のみ有効
  uint16_t keepalive_s = 30;
  bool clean_session = true;
  std::string will_topic;    // 空 = LWT なし
  std::string will_payload;
  bool will_retain = false;
};

// remaining length (可変長, 7bit/byte + 継続ビット)。戻り値 = 書いたバイト数 (1..4)。
// 上限 268435455 超は 0。
size_t encodeRemainingLength(uint32_t len, uint8_t out[4]);
// 戻り値: 1=成功 (*value/*used 設定)、0=データ不足、-1=不正 (4 バイト目にも継続ビット)。
int decodeRemainingLength(const uint8_t* data, size_t len, uint32_t* value, size_t* used);

Bytes encodeConnect(const ConnectOpts& o);
Bytes encodePublish(const std::string& topic, const std::string& payload, bool retain);
Bytes encodeSubscribe(uint16_t packet_id, const std::vector<std::string>& filters);
Bytes encodePingReq();
Bytes encodeDisconnect();

// 受信パケット (固定ヘッダ解析済み。body = 可変ヘッダ + ペイロード)
struct Packet {
  uint8_t type = 0;   // PacketType
  uint8_t flags = 0;  // 固定ヘッダ下位 4bit (PUBLISH の retain/QoS 等)
  Bytes body;
};
// 先頭からパケット 1 個を切り出す。戻り値: 消費バイト数 (>0)、0=データ不足、-1=不正。
int decodePacket(const uint8_t* data, size_t len, Packet* out);

bool parseConnack(const Packet& p, uint8_t* return_code);  // 0 = 接続受理
// PUBLISH の分解 (QoS>0 の packet id は読み飛ばす — 本実装は QoS0 でしか購読しない)
bool parsePublish(const Packet& p, std::string* topic, std::string* payload, bool* retain);

}  // namespace mqtt

// スレッド安全な公開 API。コールバックは全て Runloop 上。
class MqttClient {
 public:
  struct Options {
    std::string host;
    uint16_t port = 1883;
    std::string client_id;
    std::string username;
    std::string password;
    uint16_t keepalive_s = 30;
    std::string will_topic;    // 空 = LWT なし
    std::string will_payload;
    bool will_retain = false;
  };
  struct Callbacks {
    std::function<void()> on_connected;     // CONNACK 受理毎 (再接続でも)
    std::function<void()> on_disconnected;  // 接続確立後の切断のみ (接続失敗では呼ばない)
    std::function<void(const std::string& topic, const std::string& payload, bool retain)>
        on_message;
  };

  MqttClient(Runloop& loop, Options opts, Callbacks cbs);
  ~MqttClient();  // stop() + スレッド join

  void start();
  // 送信残を吐いて DISCONNECT → 切断 (LWT は発火しない)。冪等。
  void stop();
  // テスト用: DISCONNECT なしで TCP を即断 (ブローカーの LWT 発火を検証する)。再接続もしない。
  void abortForTest();

  // 未接続時は落とす (再接続時に呼び出し側が状態を再発行する前提)。
  void publish(const std::string& topic, const std::string& payload, bool retain);
  void subscribe(const std::string& topic_filter);  // QoS0。再接続毎に呼び直すこと
  bool connected() const;

  struct Impl;

 private:
  std::shared_ptr<Impl> impl_;
};

}  // namespace db
