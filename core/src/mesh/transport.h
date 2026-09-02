





// Framed transport and discovery abstractions. Implementations deliver every callback on Runloop;
// encryption is layered above them by SecureChannel.
#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "util/common.h"

namespace db {

class Runloop;

class IConn {
 public:
  virtual ~IConn() = default;

  virtual void send(const Bytes& frame) = 0;
  virtual void close() = 0;
  virtual std::string remoteAddr() const = 0;

  virtual void setCallbacks(std::function<void(const Bytes&)> on_frame,
                            std::function<void()> on_close) = 0;
};
using ConnPtr = std::shared_ptr<IConn>;

class ITransport {
 public:
  virtual ~ITransport() = default;

  virtual bool listen(const std::string& addr, std::function<void(ConnPtr)> on_accept) = 0;
  virtual void stopListening() = 0;

  virtual void connect(const std::string& addr, std::function<void(ConnPtr)> cb) = 0;
  virtual std::string listenAddr() const = 0;
};


struct DiscoveredPeer {
  std::string node_id;
  std::string addr;
};



// Unauthenticated discovery metadata for an unpaired device. pk is the X25519 public key used to
// seal an invitation; cluster secrets never appear in the beacon. model/platform/sw are advisory
// device-card fields so the inviting shell can name the device a user is about to add.
struct PairBeacon {
  std::string id;
  std::string addr;
  std::string name;
  std::string role;
  std::string pk;
  std::string model;
  std::string platform;
  std::string sw;
};


// What an unpaired device announces about itself. Announcing stops as soon as the device pairs.
struct PairAnnounce {
  bool on = false;
  std::string name;
  std::string role;
  std::string pk;
  std::string model;
  std::string platform;
  std::string sw;
};

class IDiscovery {
 public:
  virtual ~IDiscovery() = default;
  virtual void start(std::function<void(const DiscoveredPeer&)> on_found) = 0;

  virtual void announce(const std::string& node_id, const std::string& addr) = 0;
  virtual void stop() = 0;



  virtual void setPairAnnounce(const PairAnnounce& /*announce*/) {}

  virtual void setPairFound(std::function<void(const PairBeacon&)> /*cb*/) {}

  // Rekey authenticated discovery in place. A node that pairs at runtime must MAC its HELLO with
  // the live cluster key; implementations are called from Runloop and may have a receive thread.
  virtual void setPsk(const std::array<uint8_t, 32>& /*psk*/) {}
};

}  // namespace db
