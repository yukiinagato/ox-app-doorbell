// 内蔵 HTTP サーバ (CivetWeb ラッパ)。ポート 47180 (計画書の端点表):
//   /admin/*        管理 SPA (埋め込み静的資産; webui から生成)
//   /api/*          JSON REST (ハンドラは Runloop 上で実行 — 本クラスが marshal する)
//   /stream.mjpeg   multipart/x-mixed-replace (Phase 0 はスタブ静止画)
//   /stream.mp4     fMP4 ライブ (H.264 硬編有効時のみ — Phase 6a)
//   /snapshot.jpg   最新 JPEG
//   /panel/*        legacy Web 前端 (Phase 5; 予約)
// 認証: setAuth のゲートに通らないリクエストは 401 (public_prefixes は素通し)。
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "util/common.h"
#include "util/runloop.h"

namespace db {

struct HttpReq {
  std::string method;  // GET/POST/...
  std::string uri;     // パス部のみ
  std::string query;   // ?以降 (生)
  std::string body;
  std::map<std::string, std::string> headers;  // 小文字キー
  std::string remote_addr;
  // query/form 取得ヘルパ (URL デコード済み; 無ければ def)
  std::string param(const std::string& key, const std::string& def = "") const;
  std::string cookie(const std::string& name) const;
};

struct HttpResp {
  int status = 200;
  std::string content_type = "application/json; charset=utf-8";
  std::string body;
  std::map<std::string, std::string> headers;
  static HttpResp json(const std::string& body, int status = 200);
  static HttpResp text(const std::string& body, int status = 200);
  static HttpResp notFound();
};

class Httpd {
 public:
  using Handler = std::function<HttpResp(const HttpReq&)>;

  explicit Httpd(Runloop& loop);
  ~Httpd();

  bool start(int port);  // 0.0.0.0:port
  void stop();
  int port() const;

  // 完全一致 or 前缀一致 ("/api/config/*" のように末尾 * で前缀)。
  // handler は Runloop 上で同期実行される (5s タイムアウトで 503)。
  void route(const std::string& method, const std::string& path, Handler h);

  // 埋め込み静的資産 (gzip なし・そのまま)。path 完全一致。
  void setStatic(const std::string& path, const std::string& content_type, Bytes content);

  // 最新 JPEG の提供者 (任意スレッドから呼ばれる — スレッドセーフに実装すること)。
  // 空 vector = フレーム無し (503)。/stream.mjpeg は fps 間隔でこれをポーリングする。
  void setJpegProvider(std::function<Bytes(int64_t*)> provider, int stream_fps = 8);

  // /stream.mp4 (fMP4 ライブ — Phase 6a) のセッション提供者。リクエスト毎に provider が
  // 呼ばれ pull 関数を返す (null = h264 無効 → 503)。pull は「次に書くべきバイト列」を
  // 返す: 初回は init segment、以降は media fragment。空 vector = まだ無い (呼び直し可)、
  // *ended=true = 購読終了 (切断する)。pull のブロックは ~500ms 上限で実装すること
  // (停止・切断への応答性)。init が最初に来るまでは応答ヘッダを書かない
  // (kMp4FirstChunkTimeoutMs 待って来なければ 503)。
  using Mp4Pull = std::function<Bytes(bool* ended)>;
  void setMp4Provider(std::function<Mp4Pull()> provider);

  // 認証ゲート (Runloop 外で呼ばれる; 状態を触るなら自前で同期すること)。
  // 未設定なら全公開 (テスト用)。
  void setAuth(std::function<bool(const HttpReq&)> gate,
               std::vector<std::string> public_prefixes);

  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
