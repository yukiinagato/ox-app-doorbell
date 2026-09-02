



// Length-prefixed TCP transport. Socket workers marshal all completion callbacks to Runloop.
#pragma once

#include <memory>
#include <string>

#include "mesh/transport.h"
#include "util/runloop.h"

namespace db {

class TcpTransport : public ITransport {
 public:
  explicit TcpTransport(Runloop& loop);
  ~TcpTransport() override;


  bool listen(const std::string& addr, std::function<void(ConnPtr)> on_accept) override;
  void stopListening() override;
  void connect(const std::string& addr, std::function<void(ConnPtr)> cb) override;
  std::string listenAddr() const override;

  struct Impl;

 private:
  std::shared_ptr<Impl> impl_;
};

}  // namespace db
