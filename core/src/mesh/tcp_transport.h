// 実機用 TCP トランスポート (POSIX)。ストリームを 4B BE length-prefix でフレーム化。
//  - 専用 IO スレッド 1 本 (poll ループ + self-pipe 起床)。コールバックは Runloop に post。
//  - Windows は後日 ifdef (Winsock 化) 前提の書き方に留める。
// スレッド: 公開 API は任意スレッド可 (内部で IO スレッドへ引き渡す)。
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

  // addr: "host:port"。host は "0.0.0.0" / "127.0.0.1" / IPv4 リテラル。
  bool listen(const std::string& addr, std::function<void(ConnPtr)> on_accept) override;
  void stopListening() override;
  void connect(const std::string& addr, std::function<void(ConnPtr)> cb) override;
  std::string listenAddr() const override;

  struct Impl;

 private:
  std::shared_ptr<Impl> impl_;
};

}  // namespace db
