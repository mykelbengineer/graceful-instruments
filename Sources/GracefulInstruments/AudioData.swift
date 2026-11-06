import AVFoundation
import Accelerate

/// Decoded audio held in memory at the engine sample rate, as two plain float arrays.
/// The audio thread reads these pointers directly, so instances are never mutated after creation.
final class AudioData {
    static let sampleRate: Double = 44100

    let frames: Int
    let l: UnsafeMutablePointer<Float>
    let r: UnsafeMutablePointer<Float>
    private let stereo: Bool

    init(frames: Int, stereo: Bool = true) {
        self.frames = max(frames, 1)
        self.stereo = stereo
        l = .allocate(capacity: self.frames)
        l.initialize(repeating: 0, count: self.frames)
        if stereo {
            r = .allocate(capacity: self.frames)
            r.initialize(repeating: 0, count: self.frames)
        } else {
            r = l
        }
    }

    /// Takes ownership of buffers that were filled elsewhere (no copy, so a long file isn't held twice while loading).
    init(adopting l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>?, frames: Int) {
        self.frames = max(frames, 1)
        self.l = l
        self.stereo = r != nil
        self.r = r ?? l
    }

    deinit {
        l.deallocate()
        if stereo { r.deallocate() }
    }

    var duration: Double { Double(frames) / AudioData.sampleRate }
    var bytes: Int { frames * MemoryLayout<Float>.size * (stereo ? 2 : 1) }

    /// Max-abs peaks for drawing a waveform.
    func peaks(bins: Int) -> [Float] {
        guard bins > 0 else { return [] }
        var out = [Float](repeating: 0, count: bins)
        let per = max(1, frames / bins)
        for b in 0..<bins {
            let start = b * per
            if start >= frames { break }
            let n = min(per, frames - start)
            // RMS rather than peak, so loud and soft passages look different.
            var ml: Float = 0, mr: Float = 0
            vDSP_rmsqv(l + start, 1, &ml, vDSP_Length(n))
            vDSP_rmsqv(r + start, 1, &mr, vDSP_Length(n))
            out[b] = min(1, max(ml, mr) * 2.2)
        }
        return out
    }

    /// Mono mix of several stems, used for tempo analysis.
    static func monoMix(_ items: [AudioData]) -> AudioData {
        let n = items.map(\.frames).max() ?? 1
        let out = AudioData(frames: n, stereo: false)
        for d in items {
            var half: Float = 0.5
            vDSP_vsma(d.l, 1, &half, out.l, 1, out.l, 1, vDSP_Length(d.frames))
            vDSP_vsma(d.r, 1, &half, out.l, 1, out.l, 1, vDSP_Length(d.frames))
        }
        return out
    }
}

enum AudioLoadError: Error, LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let s): return "Could not read audio: \(s)" }
    }
}

enum AudioLoader {
    static let audioExtensions: Set<String> = ["mp3", "mpeg", "mp4", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "mov", "m4v"]

    static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Decodes any file AVFoundation understands into 44.1 kHz stereo float.
    static func load(_ url: URL, maxSeconds: Double? = nil) throws -> AudioData {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw AudioLoadError.unreadable(url.lastPathComponent)
        }
        let inFmt = file.processingFormat
        let srcChannels = Int(inFmt.channelCount)
        let outChannels: AVAudioChannelCount = srcChannels == 1 ? 1 : 2
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioData.sampleRate,
                                         channels: outChannels, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw AudioLoadError.unreadable(url.lastPathComponent)
        }
        if srcChannels > 2 { conv.downmix = true }

        let ratio = AudioData.sampleRate / inFmt.sampleRate
        let limitFrames = maxSeconds.map { Int($0 * AudioData.sampleRate) } ?? Int.max
        let estimate = min(Int(Double(file.length) * ratio), limitFrames) + 8192
        var capacity = estimate
        var outL = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        var outR = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        var written = 0

        let chunk: AVAudioFrameCount = 32768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 4096) else {
            throw AudioLoadError.unreadable(url.lastPathComponent)
        }
        var eof = false
        while true {
            outBuf.frameLength = 0
            var convError: NSError?
            let status = conv.convert(to: outBuf, error: &convError) { _, inputStatus in
                if eof { inputStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inBuf, frameCount: chunk)
                } catch {
                    eof = true; inputStatus.pointee = .endOfStream; return nil
                }
                if inBuf.frameLength == 0 { eof = true; inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return inBuf
            }
            let n = Int(outBuf.frameLength)
            if n > 0, let ch = outBuf.floatChannelData {
                if written + n > capacity {
                    let newCap = (written + n) * 2
                    let nl = UnsafeMutablePointer<Float>.allocate(capacity: newCap)
                    let nr = UnsafeMutablePointer<Float>.allocate(capacity: newCap)
                    nl.update(from: outL, count: written); nr.update(from: outR, count: written)
                    outL.deallocate(); outR.deallocate()
                    outL = nl; outR = nr; capacity = newCap
                }
                (outL + written).update(from: ch[0], count: n)
                (outR + written).update(from: outChannels == 2 ? ch[1] : ch[0], count: n)
                written += n
            }
            if status == .endOfStream || status == .error || (n == 0 && eof) || written >= limitFrames { break }
        }
        guard written > 0 else {
            outL.deallocate(); outR.deallocate()
            throw AudioLoadError.unreadable(url.lastPathComponent)
        }
        // Mono files stay mono in memory (vendor stem packs are often mostly mono).
        if outChannels == 2 { return AudioData(adopting: outL, r: outR, frames: written) }
        outR.deallocate()
        return AudioData(adopting: outL, r: nil, frames: written)
    }

    /// Mono mix of several files, decoding one at a time so a stem pack never sits in memory all at once.
    static func loadMonoMix(_ urls: [URL], maxSeconds: Double) -> AudioData? {
        if urls.count == 1 { return try? load(urls[0], maxSeconds: maxSeconds) }
        var out: AudioData?
        var used = 0
        for url in urls {
            autoreleasepool {
                guard let d = try? load(url, maxSeconds: maxSeconds) else { return }
                if out == nil {
                    let longest = urls.map { AppModel.quickDuration($0) }.max() ?? 0
                    let n = Int(min(max(longest, d.duration), maxSeconds) * AudioData.sampleRate) + 1
                    out = AudioData(frames: n, stereo: false)
                }
                guard let o = out else { return }
                let n = min(d.frames, o.frames)
                var half: Float = 0.5
                vDSP_vsma(d.l, 1, &half, o.l, 1, o.l, 1, vDSP_Length(n))
                vDSP_vsma(d.r, 1, &half, o.l, 1, o.l, 1, vDSP_Length(n))
                used = max(used, n)
            }
        }
        guard let o = out, used > 0 else { return nil }
        if used >= o.frames - 1 { return o }
        let trimmed = AudioData(frames: used, stereo: false)
        trimmed.l.update(from: o.l, count: used)
        return trimmed
    }

    /// Writes frames a..<b as Apple Lossless, so saved loops are small, exact and quick to open.
    static func writeLossless(_ d: AudioData, from a: Int, to b: Int, url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: AudioData.sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 24]
        try write(d, from: a, to: b, url: url, settings: settings)
    }

    /// 16-bit WAV, for handing audio to the Stem Maker.
    static func writeWAV(_ d: AudioData, url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioData.sampleRate,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        try write(d, from: 0, to: d.frames, url: url, settings: settings)
    }

    private static func write(_ d: AudioData, from a: Int, to b: Int, url: URL, settings: [String: Any]) throws {
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: AudioData.sampleRate, channels: 2)!
        var pos = max(0, a)
        let end = min(b, d.frames)
        while pos < end {
            let n = min(65536, end - pos)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            buf.floatChannelData![0].update(from: d.l + pos, count: n)
            buf.floatChannelData![1].update(from: d.r + pos, count: n)
            try f.write(from: buf)
            pos += n
        }
    }

    /// Loads a short mono clip (spoken cues). Falls back to silence if missing.
    static func loadMono(_ url: URL) -> AudioData {
        guard let d = try? load(url) else { return AudioData(frames: 1, stereo: false) }
        let m = AudioData(frames: d.frames, stereo: false)
        var half: Float = 0.5
        vDSP_vasm(d.l, 1, d.r, 1, &half, m.l, 1, vDSP_Length(d.frames))
        return m
    }
}
