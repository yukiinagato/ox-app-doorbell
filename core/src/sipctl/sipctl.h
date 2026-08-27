// PJSIP 包装 (音声のみ, Phase 1)。
//  - Asterisk への REGISTER 維持 (再接続含む)
//  - 按鈴呼び出し: call(ext) — G.711 (PCMU) / RFC2833 DTMF 受信
//  - 逆呼び (モニタ): 内線からの INVITE を自動応答 (Alert-Info: <sip:auto> または許可リスト)
//  - AEC: プラットフォーム別 (iOS VPIO / Android 硬件 / Windows・その他 WebRTC AEC)
// ビルド: DB_WITH_PJSIP=ON の時のみ実装がリンクされる。OFF 時は weak スタブ (常に未登録)。
// スレッド: PJSIP は自前スレッドを持つ — 本クラスがコールバックを Runloop へ marshal する。
// 公開 API はすべて Runloop 上から呼ぶこと。
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "util/runloop.h"

namespace db {

struct SipSettings {
  std::string server;          // Asterisk IP/host
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

  void call(const std::string& extension);  // 進行中呼があれば無視
  void hangup();
  void answer();  // 手動応答 (通常は auto_answer)

  SipRegState regState() const;
  SipCallState callState() const;

  // テスト/診断: 直近通話の RTP 送受パケット数
  void rtpStats(int64_t* tx_pkts, int64_t* rx_pkts) const;

  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
