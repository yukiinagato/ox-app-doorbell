
#include "mesh/secure_channel.h"

#include <cstring>

#include "monocypher.h"
#include "util/log.h"

namespace db {

namespace {

constexpr size_t kNonceLen = 32;
constexpr size_t kMacLen = 16;
constexpr size_t kDataHeader = 1 + 1 + 8 + kMacLen;  // type + dir + frame_no + mac
constexpr size_t kMaxIdLen = 64;

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

}  // namespace

SecureChannel::SecureChannel(Runloop& loop, ConnPtr conn, bool initiator,
                             const std::array<uint8_t, 32>& psk, std::string self_id,
                             int64_t handshake_timeout_ms)
    : loop_(loop),
      conn_(std::move(conn)),
      initiator_(initiator),
      psk_(psk),
      self_id_(std::move(self_id)),
      hs_timeout_ms_(handshake_timeout_ms) {}

SecureChannel::~SecureChannel() {
  if (timeout_id_) loop_.cancel(timeout_id_);
  crypto_wipe(key_.data(), key_.size());
  crypto_wipe(psk_.data(), psk_.size());
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
    Bytes r = randomBytes(kNonceLen);
    std::memcpy(nonce_a_.data(), r.data(), kNonceLen);
    sendHello_(kFrameHs1);
  }
}

void SecureChannel::sendHello_(uint8_t type) {
  const auto& nonce = initiator_ ? nonce_a_ : nonce_b_;
  Bytes f;
  f.reserve(1 + kNonceLen + self_id_.size());
  f.push_back(type);
  f.insert(f.end(), nonce.begin(), nonce.end());
  f.insert(f.end(), self_id_.begin(), self_id_.end());
  conn_->send(f);
}

void SecureChannel::deriveKey_() {

  const std::string& id_a = initiator_ ? self_id_ : peer_id_;
  const std::string& id_b = initiator_ ? peer_id_ : self_id_;
  crypto_blake2b_ctx ctx;
  crypto_blake2b_keyed_init(&ctx, 32, psk_.data(), psk_.size());
  crypto_blake2b_update(&ctx, nonce_a_.data(), nonce_a_.size());
  crypto_blake2b_update(&ctx, nonce_b_.data(), nonce_b_.size());
  crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(id_a.data()), id_a.size());
  crypto_blake2b_update(&ctx, reinterpret_cast<const uint8_t*>(id_b.data()), id_b.size());
  crypto_blake2b_final(&ctx, key_.data());
  key_ready_ = true;
}

Bytes SecureChannel::confirmMac_(uint8_t dir) const {

  static const uint8_t kTag[3] = {'c', 'f', 'm'};
  crypto_blake2b_ctx ctx;
  crypto_blake2b_keyed_init(&ctx, 32, key_.data(), key_.size());
  crypto_blake2b_update(&ctx, kTag, sizeof(kTag));
  crypto_blake2b_update(&ctx, &dir, 1);
  crypto_blake2b_update(&ctx, nonce_a_.data(), nonce_a_.size());
  crypto_blake2b_update(&ctx, nonce_b_.data(), nonce_b_.size());
  Bytes mac(32);
  crypto_blake2b_final(&ctx, mac.data());
  return mac;
}

void SecureChannel::sendConfirm_() {
  const uint8_t dir = initiator_ ? 0 : 1;
  Bytes mac = confirmMac_(dir);
  Bytes f;
  f.reserve(2 + mac.size());
  f.push_back(kFrameConfirm);
  f.push_back(dir);
  f.insert(f.end(), mac.begin(), mac.end());
  conn_->send(f);
}

bool SecureChannel::checkConfirm_(const Bytes& f) {
  if (f.size() != 2 + 32) return false;
  const uint8_t expect_dir = initiator_ ? 1 : 0;
  if (f[1] != expect_dir) return false;
  Bytes expect = confirmMac_(expect_dir);
  return crypto_verify32(f.data() + 2, expect.data()) == 0;
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
      if (type != expect || f.size() < 1 + kNonceLen + 1 ||
          f.size() > 1 + kNonceLen + kMaxIdLen) {
        fail_("bad hello");
        return;
      }
      auto& peer_nonce = initiator_ ? nonce_b_ : nonce_a_;
      std::memcpy(peer_nonce.data(), f.data() + 1, kNonceLen);
      peer_id_.assign(f.begin() + 1 + kNonceLen, f.end());
      if (!initiator_) {
        Bytes r = randomBytes(kNonceLen);
        std::memcpy(nonce_b_.data(), r.data(), kNonceLen);
        sendHello_(kFrameHs2);
      }
      deriveKey_();
      sendConfirm_();
      state_ = State::kAwaitConfirm;

      return;
    }
    case State::kAwaitConfirm: {
      if (type != kFrameConfirm || !checkConfirm_(f)) {
        fail_("confirm mismatch");
        return;
      }
      peer_confirmed_ = true;
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

      if (crypto_aead_unlock(plain.data(), f.data() + 10, key_.data(), nonce, f.data(), 10,
                             f.data() + kDataHeader, clen) != 0) {
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
  crypto_aead_lock(f.data() + kDataHeader, f.data() + 10, key_.data(), nonce, f.data(), 10,
                   reinterpret_cast<const uint8_t*>(msg_json.data()), msg_json.size());
  conn_->send(f);
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
