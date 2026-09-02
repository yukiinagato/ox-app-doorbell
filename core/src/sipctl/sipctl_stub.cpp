

#include "sipctl/sipctl.h"

#include <atomic>

#include "util/log.h"

namespace db {

const char* sipBackendName() { return "stub"; }
bool sipBackendAvailable() { return false; }

namespace {
constexpr const char* kTag = "sipctl";
}

struct SipCtl::Impl {
  Runloop& loop;
  Callbacks cbs;
  // Recorded even without a backend so status.call.mic_muted still reports what the shell asked
  // for on a display-only build.
  std::atomic<bool> mic_muted{false};
  explicit Impl(Runloop& l, Callbacks c) : loop(l), cbs(std::move(c)) {}
};

SipCtl::SipCtl(Runloop& loop, Callbacks cbs) : impl_(new Impl(loop, std::move(cbs))) {}
SipCtl::~SipCtl() = default;

void SipCtl::start(const SipSettings& settings) {
  if (!settings.server.empty())
    DB_LOGW(kTag, "PJSIP is disabled; SIP is unavailable (server=" + settings.server + ")");
}
void SipCtl::stop() {}
void SipCtl::updateSettings(const SipSettings&) {}

void SipCtl::call(const std::string& target, const std::string&) {
  DB_LOGW(kTag, "call(" + target + "): PJSIP is disabled; ignoring call");
}
bool SipCtl::callOwned(const std::string&, const std::string& target, const std::string&) {
  DB_LOGW(kTag, "call(" + target + "): PJSIP backend unavailable");
  return false;
}
bool SipCtl::hangupOwned(const std::string&) { return false; }
void SipCtl::hangup() {}
void SipCtl::answer() {}
bool SipCtl::sendDtmf(const std::string&) { return false; }
void SipCtl::setAllowedSources(const std::vector<std::string>&) {}

void SipCtl::setMicMuted(bool muted) { impl_->mic_muted.store(muted); }
bool SipCtl::micMuted() const { return impl_->mic_muted.load(); }

SipRegState SipCtl::regState() const { return SipRegState::Idle; }
SipCallState SipCtl::callState() const { return SipCallState::Idle; }
int SipCtl::monitorCount() const { return 0; }

void SipCtl::rtpStats(int64_t* tx_pkts, int64_t* rx_pkts) const {
  if (tx_pkts) *tx_pkts = 0;
  if (rx_pkts) *rx_pkts = 0;
}

}  // namespace db
