#pragma once

#include <algorithm>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <tuple>

namespace db {

// The loop publishes a durable credential version; HTTP workers only inspect this locked copy.
// Sessions are process-local, and interaction never extends the absolute lifetime.
class AdminSessions {
 public:
  static constexpr int64_t kIdleMs = 30 * 60 * 1000;
  static constexpr int64_t kAbsoluteMs = 8 * 60 * 60 * 1000;
  static constexpr size_t kCapacity = 64;

  void publishCredential(const std::string& version) {
    std::lock_guard<std::mutex> lock(mu_);
    if (version_ != version) {
      version_ = version;
      sessions_.clear();
    }
  }

  bool issue(const std::string& token, const std::string& version, int64_t now,
             const std::string& csrf = "") {
    std::lock_guard<std::mutex> lock(mu_);
    if (token.empty() || version.empty() || version != version_ || sessions_.count(token))
      return false;
    for (auto it = sessions_.begin(); it != sessions_.end();) {
      if (!valid(it->second, now)) it = sessions_.erase(it);
      else ++it;
    }
    if (sessions_.size() >= kCapacity) {
      auto oldest = std::min_element(sessions_.begin(), sessions_.end(),
          [](const auto& a, const auto& b) {
            return std::tie(a.second.interaction, a.second.order) <
                   std::tie(b.second.interaction, b.second.order);
          });
      sessions_.erase(oldest);
    }
    sessions_.emplace(token, Entry{version, now, now, ++issue_order_, csrf});
    return true;
  }

  bool check(const std::string& token, int64_t now, bool interaction = false) {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = sessions_.find(token);
    if (it == sessions_.end()) return false;
    if (!valid(it->second, now)) {
      sessions_.erase(it);
      return false;
    }
    if (interaction) it->second.interaction = now;
    return true;
  }

  std::string csrfToken(const std::string& token, int64_t now) {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = sessions_.find(token);
    return it != sessions_.end() && valid(it->second, now) ? it->second.csrf : "";
  }

  bool interact(const std::string& token, const std::string& csrf, int64_t now) {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = sessions_.find(token);
    if (csrf.empty() || it == sessions_.end() || !valid(it->second, now) ||
        it->second.csrf != csrf) return false;
    it->second.interaction = now;
    return true;
  }

  void clear() {
    std::lock_guard<std::mutex> lock(mu_);
    sessions_.clear();
  }

 private:
  struct Entry {
    std::string credential_version;
    int64_t issued;
    int64_t interaction;
    uint64_t order;
    std::string csrf;
  };
  static bool youngerThan(int64_t now, int64_t then, int64_t limit) {
    return now >= then && static_cast<uint64_t>(now) - static_cast<uint64_t>(then) <
                              static_cast<uint64_t>(limit);
  }
  bool valid(const Entry& entry, int64_t now) const {
    return entry.credential_version == version_ &&
           youngerThan(now, entry.issued, kAbsoluteMs) &&
           youngerThan(now, entry.interaction, kIdleMs);
  }
  std::mutex mu_;
  std::map<std::string, Entry> sessions_;
  std::string version_;
  uint64_t issue_order_ = 0;
};

}  // namespace db
