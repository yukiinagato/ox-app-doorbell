

// PJSIP controller for registration, direct calls, inbound monitoring/answering, RTP, and DTMF.
// PJSIP owns worker threads; callbacks are marshaled onto Runloop and public methods are called
// from Runloop. Release builds must use the real backend; explicitly marked display-only
// development builds may link the stub.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "util/runloop.h"

namespace db {

/* Compile-time backend identity used by release gates and product shells. */
const char* sipBackendName();
bool sipBackendAvailable();

struct SipSettings {
  std::string server;  // Empty disables PBX registration but retains direct-call transport.
  int port = 5060;
  std::string transport = "udp";
  std::string user;
  std::string password;
  std::string display_name;
  int rtp_port_start = 4000;
  int ec_tail_ms = 200;
  bool auto_answer = true;
  int reg_retry_s = 30;
  bool null_audio = false;  // Headless test mode; RTP remains active.



  // Fixed direct-call listen port. Zero disables inbound direct calls.
  int direct_port = 47190;
};

enum class SipRegState { Idle, Registering, Registered, Failed };
enum class SipCallState { Idle, Calling, InCall, Ended };

class SipCtl {
 public:
  struct Callbacks {
    // All callbacks are delivered on Runloop.
    std::function<void(SipRegState, const std::string& reason)> on_reg_state;
    std::function<void(SipCallState, const std::string& remote)> on_call_state;
    std::function<void(char digit)> on_dtmf;
  };

  SipCtl(Runloop& loop, Callbacks cbs);
  ~SipCtl();


  // Empty server is a supported direct-call-only configuration.
  void start(const SipSettings& settings);
  void stop();
  void updateSettings(const SipSettings& settings);




  // target is an extension or full sip: URI; mode is empty, "monitor", or "answer".
  void call(const std::string& target, const std::string& mode = "");
  void hangup();  // Ends the primary and all monitor legs.
  // An owned primary leg is isolated from manual primary calls and monitor legs. The owner token
  // is normally the Core call_id; cancellation succeeds only for the matching live leg.
  bool callOwned(const std::string& owner, const std::string& target,
                 const std::string& mode = "");
  bool hangupOwned(const std::string& owner);
  void answer();  // Manual answer for configurations without auto-answer.
  bool sendDtmf(const std::string& digits);  // RFC2833 digits on the active primary call




  // Restrict direct INVITEs by source IP. Empty allows all sources.
  void setAllowedSources(const std::vector<std::string>& ips);

  // Microphone mute for the talk control. The flag is remembered across calls and reapplied
  // when media becomes active, so muting before answering stays muted.
  void setMicMuted(bool muted);
  bool micMuted() const;

  SipRegState regState() const;
  SipCallState callState() const;
  int monitorCount() const;


  void rtpStats(int64_t* tx_pkts, int64_t* rx_pkts) const;

  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace db
