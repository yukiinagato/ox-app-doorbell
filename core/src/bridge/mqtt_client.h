





//    SUBSCRIBE QoS0 (SUBACK) / PINGREQ/PINGRESP / DISCONNECT
// Dependency-free MQTT 3.1.1 QoS0 client. A dedicated socket thread reconnects with bounded
// backoff and posts connection/message callbacks to Runloop. Public methods are thread-safe.
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
  std::string username;
  std::string password;
  uint16_t keepalive_s = 30;
  bool clean_session = true;
  std::string will_topic;
  std::string will_payload;
  bool will_retain = false;
};



size_t encodeRemainingLength(uint32_t len, uint8_t out[4]);

int decodeRemainingLength(const uint8_t* data, size_t len, uint32_t* value, size_t* used);

Bytes encodeConnect(const ConnectOpts& o);
Bytes encodePublish(const std::string& topic, const std::string& payload, bool retain);
Bytes encodeSubscribe(uint16_t packet_id, const std::vector<std::string>& filters);
Bytes encodePingReq();
Bytes encodeDisconnect();


struct Packet {
  uint8_t type = 0;   // PacketType
  uint8_t flags = 0;
  Bytes body;
};

int decodePacket(const uint8_t* data, size_t len, Packet* out);

bool parseConnack(const Packet& p, uint8_t* return_code);

bool parsePublish(const Packet& p, std::string* topic, std::string* payload, bool* retain);

}  // namespace mqtt


class MqttClient {
 public:
  struct Options {
    std::string host;
    uint16_t port = 1883;
    std::string client_id;
    std::string username;
    std::string password;
    uint16_t keepalive_s = 30;
    std::string will_topic;
    std::string will_payload;
    bool will_retain = false;
  };
  struct Callbacks {
    std::function<void()> on_connected;
    std::function<void()> on_disconnected;
    std::function<void(const std::string& topic, const std::string& payload, bool retain)>
        on_message;
  };

  MqttClient(Runloop& loop, Options opts, Callbacks cbs);
  ~MqttClient();

  void start();

  void stop();

  void abortForTest();


  void publish(const std::string& topic, const std::string& payload, bool retain);
  void subscribe(const std::string& topic_filter);
  bool connected() const;

  struct Impl;

 private:
  std::shared_ptr<Impl> impl_;
};

}  // namespace db
