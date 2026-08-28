// SOS サイレン + カスタム音声再生。
// - サイレン: 880/660Hz 交互 2 秒の PCM WAV を実行時生成してループ (WPF BuildSirenWav と同一
//   波形 — 同梱音源なしで動く)。emergency イベントの audio_path (カスタム警報音) があれば
//   そちらをループ再生し、失敗時に内蔵サイレンへ回落する。
// - playAsset: reply/chime の audio_path (資産ローカルファイル) を 1 回再生。失敗時 fallback
//   (TTS / 内蔵音) へ回落する。
import AVFoundation
import Foundation

final class SirenPlayer {

    private var player: AVAudioPlayer?

    // MARK: - カスタム音声 (reply/chime)

    /// 資産のローカルファイルを再生。失敗時は fallback (TTS / 内蔵音) へ回落する。
    func playAsset(path: String, fallback: (() -> Void)?) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            fallback?()
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player = p
            p.numberOfLoops = 0
            if !p.play() { fallback?() }
        } catch {
            fallback?()
        }
    }

    // MARK: - サイレン

    /// 警報開始。customPath (emergency の audio_path) 優先、無ければ内蔵サイレン。
    func startSiren(customPath: String, volume: Int) {
        let vol = Float(max(0, min(100, volume))) / 100.0
        if !customPath.isEmpty, FileManager.default.fileExists(atPath: customPath),
           let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: customPath)) {
            player = p
            p.numberOfLoops = -1
            p.volume = vol
            if p.play() { return }
        }
        guard let p = try? AVAudioPlayer(data: SirenPlayer.sirenWav()) else { return }
        player = p
        p.numberOfLoops = -1
        p.volume = vol
        p.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    /// 880/660Hz 交互 2 秒の警報音 (22.05kHz 16bit mono PCM WAV)。
    private static func sirenWav() -> Data {
        let rate = 22050
        let seconds = 2
        let n = rate * seconds
        let dataLen = n * 2
        var d = Data(capacity: 44 + dataLen)
        func le32(_ v: Int) {
            var x = UInt32(v).littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        func le16(_ v: Int) {
            var x = UInt16(v).littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        d.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataLen)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16)
        le16(1)          // PCM
        le16(1)          // mono
        le32(rate)
        le32(rate * 2)   // byte rate
        le16(2)          // block align
        le16(16)         // bits
        d.append(contentsOf: Array("data".utf8)); le32(dataLen)
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let freq = (i / (rate / 2)) % 2 == 0 ? 880.0 : 660.0  // 0.5 秒毎に交互
            let env = min(1.0, Double(min(i, n - i)) / (Double(rate) * 0.02))  // クリック防止
            let s = Int16(sin(2 * Double.pi * freq * t) * 0.6 * Double(Int16.max) * env)
            var x = UInt16(bitPattern: s).littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        return d
    }
}
