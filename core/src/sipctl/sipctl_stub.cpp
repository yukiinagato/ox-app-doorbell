// sipctl スタブ — DB_WITH_PJSIP=OFF (mingw クロス等、pjsip ホストビルド無し) 用。
// 常に未登録 (Idle)。call は no-op + 警告ログ。
#include "sipctl/sipctl.h"

#include "util/log.h"

namespace db {

namespace {
constexpr const char* kTag = "sipctl";
}

struct SipCtl::Impl {
  Runloop& loop;
  Callbacks cbs;
  explicit Impl(Runloop& l, Callbacks c) : loop(l), cbs(std::move(c)) {}
};

SipCtl::SipCtl(Runloop& loop, Callbacks cbs) : impl_(new Impl(loop, std::move(cbs))) {}
SipCtl::~SipCtl() = default;

void SipCtl::start(const SipSettings& settings) {
  if (!settings.server.empty())
    DB_LOGW(kTag, "PJSIP 無効ビルド — SIP は使用不可 (server=" + settings.server + ")");
}
void SipCtl::stop() {}
void SipCtl::updateSettings(const SipSettings&) {}

void SipCtl::call(const std::string& extension) {
  DB_LOGW(kTag, "call(" + extension + "): PJSIP 無効ビルド — no-op");
}
void SipCtl::hangup() {}
void SipCtl::answer() {}

SipRegState SipCtl::regState() const { return SipRegState::Idle; }
SipCallState SipCtl::callState() const { return SipCallState::Idle; }

void SipCtl::rtpStats(int64_t* tx_pkts, int64_t* rx_pkts) const {
  if (tx_pkts) *tx_pkts = 0;
  if (rx_pkts) *rx_pkts = 0;
}

}  // namespace db
