
#include "mesh/secure_channel.h"

#include <cstdlib>
#include <cstring>

#include "monocypher-ed25519.h"
#include "monocypher.h"
#include "util/log.h"

namespace db {

namespace {

constexpr size_t kKeyLen = 32;
constexpr size_t kMacLen = 16;
constexpr size_t kDataHeader = 1 + 1 + 8 + kMacLen;  // type + dir + frame_no + mac
constexpr size_t kMaxIdLen = 64;
constexpr size_t kMaxPskIds = 4;
constexpr size_t kMaxPskIdLen = 32;
constexpr size_t kConfirmLen = 2 + 32 + 64;
constexpr size_t kHelloFixed = 1 + 1 + kKeyLen * 3 + 1;  // type, version, eph, nonce, pk, count
const char kTranscriptTag[] = "doorbell-mesh-v3";
const char kSignTag[] = "doorbell-mesh-v3-confirm";

void putU64BE(uint8_t* p, uint64_t v) {
  for (int i = 7; i >= 0; i--) {
    p[i] = static_cast<uint8_t>(v & 0xff);
    v >>= 8;
  }
}

uint64_t getU64BE(const uint8_t* p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
  return v;
}

void buildNonce(uint8_t out[24], uint8_t dir, uint64_t no) {
  std::memset(out, 0, 24);
  out[0] = dir;
  putU64BE(out + 1, no);
}

bool allZero(const uint8_t* p, size_t n) {
  uint8_t acc = 0;
  for (size_t i = 0; i < n; i++) acc |= p[i];
  return acc == 0;
}

// "k<n>" or "k<n>.<suffix>"; anything else is generation zero.
uint64_t pskGeneration(const std::string& id) {
  if (id.size() < 2 || id[0] != 'k') return 0;
  uint64_t n = 0;
  for (size_t i = 1; i < id.size() && id[i] != '.'; i++) {
    if (id[i] < '0' || id[i] > '9' || n > (uint64_t{1} << 50)) return 0;
    n = n * 10 + static_cast<uint64_t>(id[i] - '0');
  }
  return n;
}

bool printableId(const std::string& s) {
  for (unsigned char c : s)
    if (c < 0x21 || c > 0x7e) return false;
  return !s.empty();
}

}  // namespace

int comparePskIds(const std::string& a, const std::string& b) {
  const uint64_t ga = pskGeneration(a), gb = pskGeneration(b);
  if (ga != gb) return ga < gb ? -1 : 1;
  return a.compare(b) < 0 ? -1 : (a == b ? 0 : 1);
}

SecureChannel::SecureChannel(Runloop& loop, ConnPtr conn, bool initiator,
                             ChannelIdentity identity, std::string self_id,
                             int64_t handshake_timeout_ms)
    : loop_(loop),
      conn_(std::move(conn)),
      initiator_(initiator),
      identity_(std::move(identity)),
      self_id_(std::move(self_id)),
      hs_timeout_ms_(handshake_timeout_ms) {
  std::array<uint8_t, 32> seed = identity_.identity_seed;
  if (allZero(seed.data(), seed.size())) {
    Bytes r = randomBytes(32);
    std::memcpy(seed.data(), r.data(), seed.size());
  }
  crypto_ed25519_key_pair(sign_sk_.data(), sign_pk_.data(), seed.data());
  crypto_wipe(identity_.identity_seed.data(), identity_.identity_seed.size());
  Bytes e = randomBytes(32);
  std::memcpy(eph_sk_.data(), e.data(), eph_sk_.size());
  crypto_x25519_public_key(eph_pk_.data(), eph_sk_.data());
  Bytes n = randomBytes(32);
  std::memcpy(nonce_.data(), n.data(), nonce_.size());
}

SecureChannel::SecureChannel(Runloop& loop, ConnPtr conn, bool initiator,
                             const std::array<uint8_t, 32>& psk, std::string self_id,
                             int64_t handshake_timeout_ms)
    : SecureChannel(loop, std::move(conn), initiator,
                    ChannelIdentity{{PskSlot{"k1", psk}}, {}, nullptr}, std::move(self_id),
                    handshake_timeout_ms) {}

SecureChannel::~SecureChannel() {
  if (timeout_id_) loop_.cancel(timeout_id_);
  crypto_wipe(eph_sk_.data(), eph_sk_.size());
  crypto_wipe(sign_sk_.data(), sign_sk_.size());
  crypto_wipe(session_.data(), session_.size());
  crypto_wipe(dir_key_[0].data(), dir_key_[0].size());
  crypto_wipe(dir_key_[1].data(), dir_key_[1].size());
  for (auto& slot : identity_.psks) crypto_wipe(slot.key.data(), slot.key.size());
}

void SecureChannel::start() {
  std::weak_ptr<SecureChannel> w = shared_from_this();
  conn_->setCallbacks(
      [w](const Bytes& f) {
        if (auto self = w.lock()) self->handleRawFrame(f);
      },
      [w]() {
        if (auto self = w.lock()) {
          self->state_ = State::kClosed;
          self->notifyClose_();
        }
      });

  timeout_id_ = loop_.postDelayed(hs_timeout_ms_, [w]() {
    auto self = w.lock();
    if (!self) return;
    self->timeout_id_ = 0;
    if (self->state_ != State::kOpen && self->state_ != State::kClosed) {
      self->fail_("handshake timeout");
    }
  });
  if (initiator_) {
    hello_self_ = buildHello_(kFrameHs1);
    conn_->send(hello_self_);
  }
}

Bytes SecureChannel::buildHello_(uint8_t type) {
  Bytes f;
  f.reserve(kHelloFixed + 64 + self_id_.size());
  f.push_back(type);
  f.push_back(kMeshProtocolVersion);
  f.insert(f.end(), eph_pk_.begin(), eph_pk_.end());
  f.insert(f.end(), nonce_.begin(), nonce_.end());
  f.insert(f.end(), sign_pk_.begin(), sign_pk_.end());
  size_t count = 0;
  for (const auto& slot : identity_.psks)
    if (!slot.id.empty() && slot.id.size() <= kMaxPskIdLen && count < kMaxPskIds) count++;
  f.push_back(static_cast<uint8_t>(count));
  size_t written = 0;
  for (const auto& slot : identity_.psks) {
    if (slot.id.empty() || slot.id.size() > kMaxPskIdLen || written >= count) continue;
    f.push_back(static_cast<uint8_t>(slot.id.size()));
    f.insert(f.end(), slot.id.begin(), slot.id.end());
    written++;
  }
  f.insert(f.end(), self_id_.begin(), self_id_.end());
  return f;
}

bool SecureChannel::parseHello_(const Bytes& f, uint8_t expect_type) {
  if (f.empty() || f[0] != expect_type) {
    fail_("bad hello");
    return false;
  }
  // A v2 hello is [type][nonce 32][id]: no version byte, so the second byte is random.
  if (f.size() < 2 || f[1] != kMeshProtocolVersion || f.size() < kHelloFixed + 1) {
    if (f.size() > 33 && f.size() <= 33 + kMaxIdLen) {
      const std::string legacy_id(f.begin() + 33, f.end());
      if (printableId(legacy_id)) peer_id_ = legacy_id;
    }
    reject_("protocol_upgrade_required");
    return false;
  }
  size_t pos = 2;
  std::memcpy(peer_eph_.data(), f.data() + pos, kKeyLen);
  pos += kKeyLen;
  pos += kKeyLen;  // peer nonce: covered by the transcript through the raw hello
  std::memcpy(peer_identity_.data(), f.data() + pos, kKeyLen);
  pos += kKeyLen;
  const size_t count = f[pos++];
  if (count > kMaxPskIds) {
    fail_("bad hello");
    return false;
  }
  peer_psk_ids_.clear();
  for (size_t i = 0; i < count; i++) {
    if (pos >= f.size()) {
      fail_("bad hello");
      return false;
    }
    const size_t len = f[pos++];
    if (len == 0 || len > kMaxPskIdLen || pos + len > f.size()) {
      fail_("bad hello");
      return false;
    }
    peer_psk_ids_.emplace_back(f.begin() + pos, f.begin() + pos + len);
    pos += len;
  }
  if (f.size() - pos == 0 || f.size() - pos > kMaxIdLen) {
    fail_("bad hello");
    return false;
  }
  peer_id_.assign(f.begin() + pos, f.end());
  if (!printableId(peer_id_)) {
    fail_("bad hello");
    return false;
  }
  hello_peer_ = f;
  return true;
}

bool SecureChannel::derive_() {
  const PskSlot* chosen = nullptr;
  for (const auto& slot : identity_.psks) {
    bool shared = false;
    for (const auto& id : peer_psk_ids_) shared = shared || id == slot.id;
    if (!shared) continue;
    if (!chosen || comparePskIds(slot.id, chosen->id) > 0) chosen = &slot;
  }
  if (!chosen) {
    reject_("no_common_psk");
    return false;
  }
  psk_id_ = chosen->id;
  if (identity_.authorize && !identity_.authorize(peer_id_, peer_identity_, psk_id_)) {
    reject_("unauthorized_peer");
    return false;
  }
  uint8_t dh[32];
  crypto_x25519(dh, eph_sk_.data(), peer_eph_.data());
  if (allZero(dh, sizeof(dh))) {
    crypto_wipe(dh, sizeof(dh));
    fail_("low-order ephemeral key");
    return false;
  }
  const Bytes& hello_init = initiator_ ? hello_self_ : hello_peer_;
  const Bytes& hello_resp = initiator_ ? hello_peer_ : hello_self_;
  crypto_blake2b_ctx ctx;
  crypto_blake2b_init(&ctx, 32);
  crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(kTranscriptTag),
                        sizeof(kTranscriptTag) - 1);
  const uint8_t id_len = static_cast<uint8_t>(psk_id_.size());
  crypto_blake2b_update(&ctx, &id_len, 1);
  crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(psk_id_.data()), psk_id_.size());
  crypto_blake2b_update(&ctx, hello_init.data(), hello_init.size());
  crypto_blake2b_update(&ctx, hello_resp.data(), hello_resp.size());
  crypto_blake2b_final(&ctx, transcript_.data());

  crypto_blake2b_keyed_init(&ctx, 32, chosen->key.data(), chosen->key.size());
  crypto_blake2b_update(&ctx, dh, sizeof(dh));
  crypto_blake2b_update(&ctx, transcript_.data(), transcript_.size());
  crypto_blake2b_final(&ctx, session_.data());
  crypto_wipe(dh, sizeof(dh));
  crypto_wipe(eph_sk_.data(), eph_sk_.size());
  for (uint8_t dir = 0; dir < 2; dir++) {
    const uint8_t label[4] = {'d', 'i', 'r', dir};
    crypto_blake2b_keyed(dir_key_[dir].data(), 32, session_.data(), session_.size(), label,
                         sizeof(label));
  }
  key_ready_ = true;
  return true;
}

Bytes SecureChannel::confirmMac_(uint8_t dir) const {
  static const uint8_t kTag[3] = {'c', 'f', 'm'};
  crypto_blake2b_ctx ctx;
  crypto_blake2b_keyed_init(&ctx, 32, session_.data(), session_.size());
  crypto_blake2b_update(&ctx, kTag, sizeof(kTag));
  crypto_blake2b_update(&ctx, &dir, 1);
  crypto_blake2b_update(&ctx, transcript_.data(), transcript_.size());
  Bytes mac(32);
  crypto_blake2b_final(&ctx, mac.data());
  return mac;
}

namespace {
Bytes signedConfirmMessage(uint8_t dir, const std::array<uint8_t, 32>& transcript) {
  Bytes m(kSignTag, kSignTag + sizeof(kSignTag) - 1);
  m.push_back(dir);
  m.insert(m.end(), transcript.begin(), transcript.end());
  return m;
}
}  // namespace

void SecureChannel::sendConfirm_() {
  const uint8_t dir = initiator_ ? 0 : 1;
  Bytes mac = confirmMac_(dir);
  const Bytes message = signedConfirmMessage(dir, transcript_);
  uint8_t signature[64];
  crypto_ed25519_sign(signature, sign_sk_.data(), message.data(), message.size());
  Bytes f;
  f.reserve(kConfirmLen);
  f.push_back(kFrameConfirm);
  f.push_back(dir);
  f.insert(f.end(), mac.begin(), mac.end());
  f.insert(f.end(), signature, signature + sizeof(signature));
  conn_->send(f);
}

bool SecureChannel::checkConfirm_(const Bytes& f) {
  if (f.size() != kConfirmLen) return false;
  const uint8_t expect_dir = initiator_ ? 1 : 0;
  if (f[1] != expect_dir) return false;
  Bytes expect = confirmMac_(expect_dir);
  if (crypto_verify32(f.data() + 2, expect.data()) != 0) return false;
  const Bytes message = signedConfirmMessage(expect_dir, transcript_);
  if (crypto_ed25519_check(f.data() + 34, peer_identity_.data(), message.data(),
                           message.size()) != 0) {
    reject_("bad_signature");
    return false;
  }
  return true;
}

void SecureChannel::becomeOpen_() {
  state_ = State::kOpen;
  if (timeout_id_) {
    loop_.cancel(timeout_id_);
    timeout_id_ = 0;
  }
  std::deque<std::string> q;
  q.swap(pending_);
  for (const auto& m : q) sendMessage(m);
  if (cbs_.on_established) cbs_.on_established();
}

void SecureChannel::handleRawFrame(const Bytes& f) {
  if (state_ == State::kClosed) return;
  if (f.empty()) {
    fail_("empty frame");
    return;
  }
  const uint8_t type = f[0];
  switch (state_) {
    case State::kAwaitHs: {
      const uint8_t expect = initiator_ ? kFrameHs2 : kFrameHs1;
      if (!parseHello_(f, expect)) return;
      if (!initiator_) {
        // The responder answers before judging the hello so the initiator can classify a
        // missing common key the same way.
        hello_self_ = buildHello_(kFrameHs2);
        conn_->send(hello_self_);
      }
      if (!derive_()) return;
      sendConfirm_();
      state_ = State::kAwaitConfirm;
      return;
    }
    case State::kAwaitConfirm: {
      if (type != kFrameConfirm || !checkConfirm_(f)) {
        fail_("confirm mismatch");
        return;
      }
      becomeOpen_();
      return;
    }
    case State::kOpen: {
      if (type != kFrameData || f.size() < kDataHeader) {
        fail_("bad data frame");
        return;
      }
      const uint8_t expect_dir = initiator_ ? 1 : 0;
      if (f[1] != expect_dir) {
        fail_("wrong direction");
        return;
      }
      const uint64_t no = getU64BE(f.data() + 2);
      if (no < recv_min_no_) {
        fail_("replayed frame");
        return;
      }
      uint8_t nonce[24];
      buildNonce(nonce, expect_dir, no);
      const size_t clen = f.size() - kDataHeader;
      Bytes plain(clen);
      if (crypto_aead_unlock(plain.data(), f.data() + 10, dir_key_[expect_dir].data(), nonce,
                             f.data(), 10, f.data() + kDataHeader, clen) != 0) {
        fail_("decrypt failed");
        return;
      }
      recv_min_no_ = no + 1;
      if (cbs_.on_message) cbs_.on_message(std::string(plain.begin(), plain.end()));
      return;
    }
    case State::kClosed:
      return;
  }
}

void SecureChannel::sendMessage(const std::string& msg_json) {
  if (state_ == State::kClosed) return;
  if (state_ != State::kOpen) {
    pending_.push_back(msg_json);
    return;
  }
  const uint8_t dir = initiator_ ? 0 : 1;
  const uint64_t no = send_no_++;
  Bytes f(kDataHeader + msg_json.size());
  f[0] = kFrameData;
  f[1] = dir;
  putU64BE(f.data() + 2, no);
  uint8_t nonce[24];
  buildNonce(nonce, dir, no);
  crypto_aead_lock(f.data() + kDataHeader, f.data() + 10, dir_key_[dir].data(), nonce, f.data(),
                   10, reinterpret_cast<const uint8_t*>(msg_json.data()), msg_json.size());
  conn_->send(f);
}

void SecureChannel::reject_(const char* reason) {
  if (!rejected_) {
    rejected_ = true;
    DB_LOGD("sec", std::string("channel rejected: ") + reason + " peer=" + peer_id_);
    if (cbs_.on_rejected) cbs_.on_rejected(reason, peer_id_);
  }
  close();
}

void SecureChannel::fail_(const char* why) {
  DB_LOGD("sec", std::string("channel fail: ") + why + " peer=" + peer_id_);
  close();
}

void SecureChannel::close() {
  if (state_ == State::kClosed) return;
  state_ = State::kClosed;
  if (timeout_id_) {
    loop_.cancel(timeout_id_);
    timeout_id_ = 0;
  }
  if (conn_) conn_->close();
  notifyClose_();
}

void SecureChannel::notifyClose_() {
  if (close_notified_) return;
  close_notified_ = true;
  state_ = State::kClosed;
  if (cbs_.on_close) cbs_.on_close();
}

}  // namespace db
