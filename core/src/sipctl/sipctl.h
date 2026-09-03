

// PJSIP controller for registration, direct calls, inbound monitoring/answering, RTP, and DTMF.
// Callbacks are marshaled onto Runloop and public methods are called from Runloop. Release
// builds must use the real backend; explicitly marked display-only development builds may link
// the stub.
//
// The SIP event pump is ours, not pjsua's. pjsua's built-in worker (pjsua_config.thread_cnt,
// default 1) polls every 10 ms for ever whether or not anything is happening -- 100 wakeups a
// second on a device sitting idle, which is most of the day. Symbolicated iOS reports measured
// 176 wakeups a second against a 150/s budget with the doorbell doing nothing at all. So
// thread_cnt is set to zero and one thread of ours calls pjsua_handle_events with a timeout
// that follows the work: 10 ms while a call or dialog is up, while a registration is in
// flight, or while a SIP timer is due within 10 ms, and 250 ms otherwise. Media is unaffected
// -- pjmedia runs its own threads and its own clock, so audio timing does not depend on this
// loop at all. The timeout is a ceiling: pjsip_endpt_handle_events2 already shortens the poll
// to the earliest pending timer, so raising it never makes a timer late.
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

/* Poll timeout for the SIP event pump, in milliseconds. Pure so the policy can be tested
 * without a PJSIP build: earliest_timer_ms is the delay to the nearest pending SIP timer, or a
 * negative value when the timer heap is empty. */
inline int sipPumpTimeoutMs(bool calls_active, bool registration_pending,
                            long earliest_timer_ms) {
  const int busy_ms = 10;
  const int idle_ms = 250;
  if (calls_active || registration_pending) return busy_ms;
  if (earliest_timer_ms >= 0) {
    if (earliest_timer_ms <= busy_ms) return busy_ms;
    if (earliest_timer_ms < idle_ms) return static_cast<int>(earliest_timer_ms);
  }
  return idle_ms;
}

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

  // The X-Doorbell-Mode of the dialog currently in the primary slot: "" for an ordinary
  // two-way call, "answer" for an explicit takeover, "monitor" for one-way listen-in. An
  // outbound monitor dialog occupies the same slot as a real call, so callers that act on a
  // call becoming established must consult this before treating it as an answer.
  std::string callMode() const;

  // A dialog may report a call answered only when a person is actually on it. Listen-in is not
  // answering: a panel opens a monitor dialog by itself, and a burst of them must never turn a
  // ringing call into an answered one in the history.
  static bool dialogCanAnswer(const std::string& mode) { return mode != "monitor"; }

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
