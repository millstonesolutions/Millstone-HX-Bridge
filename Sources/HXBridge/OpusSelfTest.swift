import Foundation
import CNDI

/// Round-trip check: send 8 channels of distinct tones as multichannel Opus through NDI, receive them back
/// with the NDI library's own decoder on this Mac, and report which tone lands in which channel.
/// Run with: HXBridge --opus-selftest
enum OpusSelfTest {
    static func run() {
        guard NDIRuntime.initialize() else { report("NDI failed to initialize"); return }
        test(.ndi, channels: 8)
        for n in [1, 2, 3, 6, 16] { test(.ndi, channels: n) }
        report("done")
    }

    static func report(_ s: String) {
        Log.info("[opus-selftest] \(s)")
        print("[opus-selftest] \(s)")
    }

    static func test(_ layout: OpusLayout, channels ch: Int) {
        let group = "opus-selftest"
        let name = "OpusSelfTest-\(layout.rawValue)-\(ch)"
        let box = CStringBox()
        var sc = NDIlib_send_create_t()
        sc.p_ndi_name = box.make(name)
        sc.p_groups = box.make(group)
        sc.clock_video = false
        sc.clock_audio = false
        guard let send = NDIlib_send_create_v2(&sc, nil) else { report("\(layout): sender failed"); return }
        defer { NDIlib_send_destroy(send) }

        var fc = NDIlib_find_create_t()
        fc.show_local_sources = true
        fc.p_groups = box.make(group)
        guard let finder = NDIlib_find_create_v3(&fc, nil) else { report("\(layout): finder failed"); return }
        defer { NDIlib_find_destroy(finder) }
        var fullName = "", url: String?
        for _ in 0..<50 where fullName.isEmpty {
            _ = NDIlib_find_wait_for_sources(finder, 200)
            var n: UInt32 = 0
            if let p = NDIlib_find_get_current_sources(finder, &n) {
                for i in 0..<Int(n) {
                    guard let nm = p[i].p_ndi_name else { continue }
                    let s = String(cString: nm)
                    if s.hasSuffix("(\(name))") { fullName = s; url = p[i].p_url_address.map { String(cString: $0) } }
                }
            }
        }
        guard !fullName.isEmpty else { report("\(layout): test source not found"); return }

        var rc = NDIlib_recv_create_v3_t()
        rc.source_to_connect_to.p_ndi_name = box.make(fullName)
        rc.source_to_connect_to.p_url_address = box.make(url)
        rc.color_format = NDIlib_recv_color_format_fastest
        rc.bandwidth = NDIlib_recv_bandwidth_highest
        guard let recv = NDIlib_recv_create_v4(&rc, nil) else { report("\(layout): receiver failed"); return }
        defer { NDIlib_recv_destroy(recv) }

        guard let enc = OpusMultiEncoder(channels: ch, bitratePerChannel: 96_000, layout: layout) else {
            report("\(layout): encoder failed"); return
        }
        let freqs = (0..<ch).map { 300.0 + (ch > 8 ? 125.0 : 250.0) * Double($0) }
        let stopLock = NSLock()
        var stop = false
        let sender = Thread {
            let block = 960
            var planar = [Float](repeating: 0, count: block * ch)
            var t = 0
            var next = Date()
            while true {
                stopLock.lock(); let s = stop; stopLock.unlock()
                if s { break }
                for c in 0..<ch {
                    for i in 0..<block {
                        planar[c * block + i] = Float(0.4 * sin(2 * .pi * freqs[c] * Double(t + i) / 48000))
                    }
                }
                t += block
                let pk = planar.withUnsafeBufferPointer {
                    enc.encode(planar: $0.baseAddress!, frames: block, sourceChannels: ch,
                               channelStrideBytes: block * 4, pts100ns: Int64(t) * 10_000_000 / 48000)
                }
                for p in pk { sendOpusFrame(send: send, data: p.data, channels: ch, samples: p.samples, timecode: p.pts100ns) }
                next += 0.02
                let wait = next.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
        sender.start()
        defer { stopLock.lock(); stop = true; stopLock.unlock(); Thread.sleep(forTimeInterval: 0.1) }

        // Receive ~4 s; analyse after 1.5 s of warm-up.
        var power = [[Double]](repeating: [Double](repeating: 0, count: ch), count: 16)
        var outChannels = 0, frames = 0
        let start = Date()
        while Date().timeIntervalSince(start) < 4 {
            var a = NDIlib_audio_frame_v2_t()
            let type = NDIlib_recv_capture_v2(recv, nil, &a, nil, 100)
            guard type == NDIlib_frame_type_audio else { continue }
            defer { NDIlib_recv_free_audio_v2(recv, &a) }
            outChannels = Int(a.no_channels)
            guard Date().timeIntervalSince(start) > 1.5, let d = a.p_data else { continue }
            frames += 1
            let plane = Int(a.channel_stride_in_bytes) / 4
            for c in 0..<min(outChannels, 16) {
                for k in 0..<ch {
                    power[c][k] += goertzel(d + c * plane, Int(a.no_samples), freq: freqs[k], rate: Double(a.sample_rate))
                }
            }
        }
        guard frames > 0 else { report("\(layout): no audio received back"); return }
        var lines: [String] = []
        var allCorrect = outChannels == ch
        for c in 0..<min(outChannels, 16) {
            let row = power[c]
            let best = row.indices.max { row[$0] < row[$1] }!
            let sorted = row.sorted(by: >)
            let total = row.reduce(0, +)
            let db = sorted.count > 1
                ? 10 * log10(max(sorted[0], 1e-12) / max(sorted[1], 1e-12))
                : 10 * log10(max(sorted[0], 1e-12) / max(total * 1e-9, 1e-12))
            if best != c { allCorrect = false }
            lines.append("out\(c + 1)←in\(best + 1) (\(String(format: "%.0f", db)) dB)")
        }
        report("\(layout.rawValue) \(ch)ch: \(outChannels) channels back, \(allCorrect ? "ALL CORRECT" : "MISMATCH") — " + lines.joined(separator: ", "))
    }

    static func goertzel(_ x: UnsafePointer<Float>, _ n: Int, freq: Double, rate: Double) -> Double {
        let w = 2 * Double.pi * freq / rate
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<n {
            let s = Double(x[i]) + coeff * s1 - s2
            s2 = s1; s1 = s
        }
        return s1 * s1 + s2 * s2 - coeff * s1 * s2
    }
}
