// 軽量ログ: stderr + リングバッファ (管理画面 /api/logs 用)。スレッドセーフ。
#pragma once

#include <functional>
#include <string>
#include <vector>

namespace db {

enum class LogLevel { Debug = 0, Info = 1, Warn = 2, Error = 3 };

void logLine(LogLevel lv, const std::string& tag, const std::string& msg);
// プラットフォーム殻へ転送する追加シンク (nullptr で解除)
void setLogSink(std::function<void(LogLevel, const std::string& line)> sink);
void setLogMinLevel(LogLevel lv);
std::vector<std::string> recentLogs(size_t max_lines);

#define DB_LOGD(tag, msg) ::db::logLine(::db::LogLevel::Debug, (tag), (msg))
#define DB_LOGI(tag, msg) ::db::logLine(::db::LogLevel::Info, (tag), (msg))
#define DB_LOGW(tag, msg) ::db::logLine(::db::LogLevel::Warn, (tag), (msg))
#define DB_LOGE(tag, msg) ::db::logLine(::db::LogLevel::Error, (tag), (msg))

}  // namespace db
