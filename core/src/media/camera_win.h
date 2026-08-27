// Windows カメラ採集 (Media Foundation SourceReader) — WIN32 のみコンパイル。
//   専用スレッドで ReadSample ループを回し FrameBus へ push する。
//   失敗はログのみ (アプリは止めない)。停止/再起動安全。
// TODO: 古い USB カメラで MF が使えない場合の DirectShow フォールバック (実機検証時)。
#pragma once

#include <atomic>
#include <string>
#include <thread>

namespace db {

class FrameBus;

class CameraWin {
 public:
  explicit CameraWin(FrameBus& bus) : bus_(bus) {}
  ~CameraWin() { stop(); }

  CameraWin(const CameraWin&) = delete;
  CameraWin& operator=(const CameraWin&) = delete;

  // device_hint: フレンドリ名の部分一致 (大小無視; 空 = 先頭デバイス)。
  // target_w/h: 交渉目標解像度 (最も近い native type を選ぶ)。
  // 採集スレッドを起動して即 true を返す (デバイス失敗はスレッド内でログ)。
  bool start(const std::string& device_hint, int target_w = 640, int target_h = 480);
  void stop();
  bool running() const { return running_.load(); }

 private:
  void run(std::string hint, int tw, int th);

  FrameBus& bus_;
  std::thread th_;
  std::atomic<bool> running_{false};
};

}  // namespace db
