// PJSIP 包装 (音声のみ, Phase 1)。
//  - Asterisk への REGISTER 維持 (再接続含む)
//  - 按鈴呼び出し: call(ext) — G.711 (PCMU) / RFC2833 DTMF 受信
//  - 直接呼 (Asterisk 非経由): call("sip:host:port") — 固定 direct_port で常時 listen し、
//    PBX 障害時も室内機/TV ↔ 門口機の対講・監聴が生きる (自愈方針)。server 空でも
//    transport だけは立てる。
//  - 逆呼び/モニタ呼: 内線または直接の INVITE を自動応答。X-Doorbell-Mode ヘッダで
//    "monitor" (一方向: マイク→相手のみ) / "answer" (双方向) を明示できる。ヘッダ無しは
//    「主呼進行中=モニタ / アイドル=双方向」のフォールバック (詳細は sipctl.cpp)。
//  - AEC: プラットフォーム別 (iOS VPIO / Android 硬件 / Windows・その他 WebRTC AEC)
// ビルド: DB_WITH_PJSIP=ON の時のみ実装がリンクされる。OFF 時は weak スタブ (常に未登録)。
// スレッド: PJSIP は自前スレッドを持つ — 本クラスがコールバックを Runloop へ marshal する。
// 公開 API はすべて Runloop 上から呼ぶこと。
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "util/runloop.h"

namespace db {

struct SipSettings {
  std::string server;          // Asterisk IP/host ("" = 登録なし — 直接呼のみ)
  int port = 5060;
  std::string transport = "udp";
  std::string user;            // 例 "8001"
  std::string password;
  std::string display_name;    // callerid 表示 (門口名)
  int rtp_port_start = 4000;   // 固定レンジ 4000-4099 (FW 開放と一致)
  int ec_tail_ms = 200;        // AEC 初期遅延推定 (装機標定で上書き)
  bool auto_answer = true;     // 逆呼び自動応答 (Alert-Info auto)
  int reg_retry_s = 30;
  bool null_audio = false;     // テスト/ヘッドレス: null 音声デバイス (RTP は流れる)
  // SIP transport の固定 listen ポート (直接呼の宛先になる)。0 = 空きポート任せ
  // (直接着信は不可)。既定 47190 — docs/network-ports.md 参照。使用中なら空きポートへ
  // フォールバックする (登録運用は継続、直接着信のみ不可)。
  int direct_port = 47190;
};

enum class SipRegState { Idle, Registering, Registered, Failed };
enum class SipCallState { Idle, Calling, InCall, Ended };

class SipCtl {
 public:
  struct Callbacks {
    // すべて Runloop 上で呼ばれる
    std::function<void(SipRegState, const std::string& reason)> on_reg_state;
    std::function<void(SipCallState, const std::string& remote)> on_call_state;
    std::function<void(char digit)> on_dtmf;  // 通話中の相手キー (RFC2833)
  };

  SipCtl(Runloop& loop, Callbacks cbs);
  ~SipCtl();

  // settings.server が空なら何もしない (SIP 無効運用も正常系)
  void start(const SipSettings& settings);
  void stop();
  void updateSettings(const SipSettings& settings);  // 変更時は再登録

  // 発呼。target: 内線番号 (server 経由) または "sip:" で始まる完全 URI (直接呼)。
  // mode: "" = 通常 / "monitor" / "answer" — X-Doorbell-Mode ヘッダとして相手へ渡す
  // (受け側の一方向/双方向判別に使う)。主呼進行中は無視。
  void call(const std::string& target, const std::string& mode = "");
  void hangup();  // 主呼 + モニタ呼すべて切断
  void answer();  // 手動応答 (通常は auto_answer)

  // 直接 INVITE (server 経由でない送信元) の許可 IP リスト。空 = 全許可 (既定)。
  // 非空なら server 自身とリスト内 IP 以外からの INVITE を 403 拒否する。
  // start/stop をまたいで保持される。Node 側の配線は後続 (mesh peers の IP を渡す想定)。
  void setAllowedSources(const std::vector<std::string>& ips);

  SipRegState regState() const;
  SipCallState callState() const;
  int monitorCount() const;  // 受理中のモニタ呼本数 (診断/テスト用; 任意スレッド可)

  // テスト/診断: 直近通話の RTP 送受パケット数 (主呼基準 — モニタ呼は含めない)
  void rtpStats(int64_t* tx_pkts, int64_t* rx_pkts) const;

  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
