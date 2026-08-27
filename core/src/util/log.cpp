#include "util/log.h"

#include <cstdio>
#include <ctime>
#include <deque>
#include <mutex>

namespace db {

namespace {
std::mutex g_mu;
std::deque<std::string> g_ring;
constexpr size_t kRingMax = 2000;
std::function<void(LogLevel, const std::string&)> g_sink;
LogLevel g_min = LogLevel::Debug;

const char* levelName(LogLevel lv) {
  switch (lv) {
    case LogLevel::Debug: return "D";
    case LogLevel::Info: return "I";
    case LogLevel::Warn: return "W";
    case LogLevel::Error: return "E";
  }
  return "?";
}
}  // namespace

void logLine(LogLevel lv, const std::string& tag, const std::string& msg) {
  if (static_cast<int>(lv) < static_cast<int>(g_min)) return;
  char ts[32];
  std::time_t t = std::time(nullptr);
  std::tm tm{};
#if defined(_WIN32)
  localtime_s(&tm, &t);
#else
  localtime_r(&t, &tm);
#endif
  std::strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tm);
  std::string line = std::string(ts) + " " + levelName(lv) + " [" + tag + "] " + msg;

  std::function<void(LogLevel, const std::string&)> sink;
  {
    std::lock_guard<std::mutex> lk(g_mu);
    g_ring.push_back(line);
    if (g_ring.size() > kRingMax) g_ring.pop_front();
    sink = g_sink;
  }
  std::fprintf(stderr, "%s\n", line.c_str());
  if (sink) sink(lv, line);
}

void setLogSink(std::function<void(LogLevel, const std::string&)> sink) {
  std::lock_guard<std::mutex> lk(g_mu);
  g_sink = std::move(sink);
}

void setLogMinLevel(LogLevel lv) { g_min = lv; }

std::vector<std::string> recentLogs(size_t max_lines) {
  std::lock_guard<std::mutex> lk(g_mu);
  size_t n = g_ring.size() < max_lines ? g_ring.size() : max_lines;
  return std::vector<std::string>(g_ring.end() - static_cast<long>(n), g_ring.end());
}

}  // namespace db
