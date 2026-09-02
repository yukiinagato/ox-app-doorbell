import AVFoundation
import Foundation

final class SirenPlayer {

    private var player: AVAudioPlayer?


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

    private static let bundledFiles: [String: String] = [
        "outdoor_call_alert": "outdoor_call_alert.mp3",
        "button_click": "button_click.mp3",
        "school_chime": "学校のチャイム.mp3",
        "indoor_update": "indoor_update.mp3",
        "title_display": "title_display.mp3"
    ]

    func playConfigured(_ value: String, dataDir: String = BootConfig.dataDir(),
                        loops: Bool = false, fallback: (() -> Void)? = nil) {
        guard !value.isEmpty else { return }
        var url: URL?
        if value.hasPrefix("asset:"), value.count == 70 {
            let hash = String(value.dropFirst(6))
            let path = URL(fileURLWithPath: dataDir).appendingPathComponent("assets")
                .appendingPathComponent(hash).path
            if FileManager.default.fileExists(atPath: path) { url = URL(fileURLWithPath: path) }
        } else if let filename = SirenPlayer.bundledFiles[value] {
            url = Bundle.main.url(forResource: (filename as NSString).deletingPathExtension,
                                  withExtension: (filename as NSString).pathExtension)
        }
        guard let soundUrl = url, let p = try? AVAudioPlayer(contentsOf: soundUrl) else {
            fallback?()
            return
        }
        player?.stop()
        player = p
        p.numberOfLoops = loops ? -1 : 0
        if !p.play() { fallback?() }
    }


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
            let freq = (i / (rate / 2)) % 2 == 0 ? 880.0 : 660.0
            let env = min(1.0, Double(min(i, n - i)) / (Double(rate) * 0.02))
            let s = Int16(sin(2 * Double.pi * freq * t) * 0.6 * Double(Int16.max) * env)
            var x = UInt16(bitPattern: s).littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        return d
    }
}
