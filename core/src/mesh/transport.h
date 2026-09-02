





// Framed transport and discovery abstractions. Implementations deliver every callback on Runloop;
// encryption is layered above them by SecureChannel.
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
// seal an invitation; cluster secrets never appear in the beacon.
struct PairBeacon {
  std::string id;
  std::string addr;
  std::string name;
  std::string role;
  std::string pk;
};

class IDiscovery {
 public:
  virtual ~IDiscovery() = default;
  virtual void start(std::function<void(const DiscoveredPeer&)> on_found) = 0;

  virtual void announce(const std::string& node_id, const std::string& addr) = 0;
  virtual void stop() = 0;



  virtual void setPairAnnounce(bool /*on*/, const std::string& /*name*/,
                               const std::string& /*role*/, const std::string& /*pk*/) {}

  virtual void setPairFound(std::function<void(const PairBeacon&)> /*cb*/) {}
};

}  // namespace db
