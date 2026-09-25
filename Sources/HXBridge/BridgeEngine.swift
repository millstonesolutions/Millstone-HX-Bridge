import Foundation
import CNDI
import CoreVideo
import VideoToolbox

enum BridgeState: String {
    case stopped = "Stopped"
    case waitingForSource = "Waiting for source"
    case noVideo = "Connected, no video"
    case idle = "Running (no receivers)"
    case running = "Running"
    case error = "Error"
}

struct BridgeStats: Equatable {
    var state: BridgeState = .stopped
    var message = ""
    var inputDescription = "—"
    var inputFPS = 0.0
    var outputMbps = 0.0
    var previewMbps = 0.0
    var targetMbps = 0.0
    var receivers = 0
    var keyframes = 0
    var framesEncoded = 0
    var droppedInput = 0
    var onProgram = false
    var onPreview = false
    var encoderInfo = ""
    var audioInfo = ""
    var startedAt: Date? = nil
}

/// One bridge: NDI receiver (High Bandwidth in) -> Apple media engine H.264/HEVC -> NDI HX sender.
final class BridgeEngine {
    let config: BridgeConfig
    let settings: AppSettings
    private let resolveURL: (String) -> String?
    private let onStats: (BridgeStats) -> Void

    private var thread: Thread?
    private let stateLock = NSLock()
    private var stopRequested = false
    private let finished = DispatchSemaphore(value: 0)

    // Sender + counters shared with encoder callback threads.
    private let sendLock = NSLock()
    private var send: NDIlib_send_instance_t?
    private var bytesMain = 0
    private var bytesPreview = 0
    private var keyframes = 0
    private var framesEncoded = 0

    // Pipeline state (capture thread only).
    private var curW = 0, curH = 0, curN = 0, curD = 0
    private var inputPool: CVPixelBufferPool?
    private var inputPoolKey = ""
    private var toNV12: PixelScaler?
    private var previewScaler: PixelScaler?
    private var mainEncoder: HXVideoEncoder?
    private var previewEncoder: HXVideoEncoder?
    private var previewW = 640, previewH = 360
    private var aac: AACEncoder?
    private var opus: OpusMultiEncoder?
    private var opusFailedKey = ""
    private var lastPts: Int64 = 0
    private var lastNV12: CVPixelBuffer?
    private var lastEncodeAt = Date.distantPast
    private var frameDur100ns: Int64 = 333_667
    private var captureTimeoutMs: UInt32 = 100
    private var framesIn = 0
    private var lastVideoAt = Date.distantPast

    init(config: BridgeConfig, settings: AppSettings,
         resolveURL: @escaping (String) -> String?, onStats: @escaping (BridgeStats) -> Void) {
        self.config = config
        self.settings = settings
        self.resolveURL = resolveURL
        self.onStats = onStats
    }

    private var tag: String { "[\(config.outputName)]" }
    private var shouldStop: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopRequested }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "bridge \(config.outputName)"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops and waits (up to 3 s) for the capture thread to clean up.
    func stop() {
        stateLock.lock(); stopRequested = true; stateLock.unlock()
        if thread != nil { _ = finished.wait(timeout: .now() + 3) }
        thread = nil
    }

    // MARK: - Main loop

    private func run() {
        var stats = BridgeStats()
        defer {
            teardown()
            if stats.state != .error {
                stats = BridgeStats()
                stats.state = .stopped
            }
            onStats(stats)
            finished.signal()
        }
        func fail(_ msg: String) {
            Log.error("\(tag) \(msg)")
            stats.state = .error
            stats.message = msg
            onStats(stats)
        }

        guard NDIRuntime.initialize() else { fail("NDI failed to initialize (unsupported CPU?)"); return }
        guard !config.sourceName.isEmpty else { fail("No input source selected"); return }

        let box = CStringBox()
        var sc = NDIlib_send_create_t()
        sc.p_ndi_name = box.make(config.outputName)
        sc.p_groups = box.make(config.outputGroups)
        sc.clock_video = false
        sc.clock_audio = false
        let sendJSON = settings.ndiConfigJSON(sendGroups: config.outputGroups)
        guard let s = NDIlib_send_create_v2(&sc, sendJSON) else {
            fail("Could not create NDI sender \"\(config.outputName)\"")
            return
        }
        sendLock.lock(); send = s; sendLock.unlock()
        let product = "<ndi_product long_name=\"Millstone Solutions HX Bridge\" short_name=\"HX Bridge\" manufacturer=\"\(xmlEscape(settings.vendorName.isEmpty ? "Millstone Solutions" : settings.vendorName))\" version=\"0.1.0\" model_name=\"HXBridge\" session=\"default\" serial=\"\(config.id.uuidString.prefix(8))\"/>"
        box.make(product).map { p in
            var md = NDIlib_metadata_frame_t()
            md.p_data = UnsafeMutablePointer(mutating: p)
            md.length = Int32(strlen(p))
            md.timecode = NDIlib_send_timecode_synthesize
            NDIlib_send_add_connection_metadata(s, &md)
        }
        stats.startedAt = Date()
        Log.info("\(tag) sender created in group(s) \"\(config.outputGroups)\" (\(config.codec.label), \(config.preset.label))")

        // Wait for the source to be discovered so we connect with its URL (respects our input groups).
        var recv: NDIlib_recv_instance_t?
        stats.state = .waitingForSource
        stats.message = "Looking for \"\(config.sourceName)\" in group(s) \"\(settings.inputGroups)\""
        onStats(stats)
        while recv == nil && !shouldStop {
            if let url = resolveURL(config.sourceName) {
                var rc = NDIlib_recv_create_v3_t()
                rc.source_to_connect_to.p_ndi_name = box.make(config.sourceName)
                rc.source_to_connect_to.p_url_address = box.make(url)
                rc.color_format = NDIlib_recv_color_format_UYVY_BGRA
                rc.bandwidth = NDIlib_recv_bandwidth_highest
                rc.allow_video_fields = false
                rc.p_ndi_recv_name = box.make("HX Bridge (\(config.outputName))")
                recv = NDIlib_recv_create_v4(&rc, settings.ndiConfigJSON(recvGroups: settings.inputGroups))
                if recv == nil { fail("Could not create NDI receiver"); return }
                Log.info("\(tag) connecting to \"\(config.sourceName)\"")
            } else {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        guard let r = recv, !shouldStop else { if let r = recv { NDIlib_recv_destroy(r) }; return }
        defer { NDIlib_recv_destroy(r) }

        var lastStats = Date()
        var lastTally = NDIlib_tally_t()
        var lastBytesMain = 0, lastBytesPreview = 0, lastFramesIn = 0

        while !shouldStop {
            var video = NDIlib_video_frame_v2_t()
            var audio = NDIlib_audio_frame_v2_t()
            var meta = NDIlib_metadata_frame_t()
            let type = NDIlib_recv_capture_v2(r, &video, &audio, &meta, captureTimeoutMs)
            switch type {
            case NDIlib_frame_type_video:
                handleVideo(video, stats: &stats)
                NDIlib_recv_free_video_v2(r, &video)
            case NDIlib_frame_type_audio:
                handleAudio(audio, stats: &stats)
                NDIlib_recv_free_audio_v2(r, &audio)
            case NDIlib_frame_type_metadata:
                NDIlib_recv_free_metadata(r, &meta)
            case NDIlib_frame_type_error:
                Log.warn("\(tag) receiver reported an error; NDI will retry the connection")
            default:
                break
            }

            repeatLastFrameIfDue()

            let now = Date()
            let elapsed = now.timeIntervalSince(lastStats)
            if elapsed >= 0.5 {
                // Tally: HX receivers -> ProPresenter.
                var tally = NDIlib_tally_t()
                NDIlib_send_get_tally(s, &tally, 0)
                if config.forwardTally && (tally.on_program != lastTally.on_program || tally.on_preview != lastTally.on_preview) {
                    NDIlib_recv_set_tally(r, &tally)
                    lastTally = tally
                }
                var total = NDIlib_recv_performance_t(), dropped = NDIlib_recv_performance_t()
                NDIlib_recv_get_performance(r, &total, &dropped)

                sendLock.lock()
                let bm = bytesMain, bp = bytesPreview, kf = keyframes, fe = framesEncoded
                sendLock.unlock()
                stats.outputMbps = Double(bm - lastBytesMain) * 8 / elapsed / 1_000_000
                stats.previewMbps = Double(bp - lastBytesPreview) * 8 / elapsed / 1_000_000
                stats.inputFPS = Double(framesIn - lastFramesIn) / elapsed
                lastBytesMain = bm; lastBytesPreview = bp; lastFramesIn = framesIn
                stats.keyframes = kf
                stats.framesEncoded = fe
                stats.droppedInput = Int(dropped.video_frames)
                stats.receivers = Int(NDIlib_send_get_no_connections(s, 0))
                stats.onProgram = tally.on_program
                stats.onPreview = tally.on_preview
                if lastNV12 == nil {
                    stats.state = .noVideo
                    stats.message = "Connected to \"\(config.sourceName)\" — waiting for video"
                } else {
                    stats.state = stats.receivers > 0 ? .running : .idle
                    stats.message = now.timeIntervalSince(lastVideoAt) > 2
                        ? "Source picture is static — repeating the last frame" : ""
                }
                onStats(stats)
                lastStats = now
            }
        }
    }

    // MARK: - Video

    private func handleVideo(_ v: NDIlib_video_frame_v2_t, stats: inout BridgeStats) {
        let w = Int(v.xres), h = Int(v.yres)
        let n = Int(v.frame_rate_N), d = Int(v.frame_rate_D)
        guard w > 0, h > 0, let base = v.p_data else { return }
        framesIn += 1
        lastVideoAt = Date()
        let fps = (n > 0 && d > 0) ? Double(n) / Double(d) : 30
        let frameDur = Int64(10_000_000.0 / fps)

        if w != curW || h != curH || n != curN || d != curD || mainEncoder == nil {
            rebuildVideo(w: w, h: h, n: n, d: d, fps: fps, stats: &stats)
        }
        guard let send = send, mainEncoder != nil, let conv = toNV12 else { return }

        // Always keep the latest picture (sources may send only on change), even with no receivers.
        guard let input = copyToPixelBuffer(v, base: base, w: w, h: h), let nv12 = conv.scale(input) else { return }
        lastNV12 = nv12
        frameDur100ns = frameDur
        captureTimeoutMs = UInt32(max(5, min(100, frameDur / 10_000 / 2)))

        if config.skipEncodeWithoutReceivers && NDIlib_send_get_no_connections(send, 0) == 0 { return }

        var pts = (v.timestamp != NDIlib_recv_timestamp_undefined && v.timestamp > 0) ? v.timestamp : v.timecode
        if pts <= lastPts { pts = lastPts + frameDur }
        encodeFrame(nv12, pts: pts, send: send)
    }

    /// NDI sources often stop sending when the picture is static. Keep a steady HX stream by
    /// re-encoding the last frame at the source frame rate (cheap: static P-frames are tiny).
    private func repeatLastFrameIfDue() {
        guard let last = lastNV12, let send = send else { return }
        let dur = Double(frameDur100ns) / 10_000_000
        guard Date().timeIntervalSince(lastEncodeAt) >= dur * 1.5 else { return }
        if config.skipEncodeWithoutReceivers && NDIlib_send_get_no_connections(send, 0) == 0 { return }
        encodeFrame(last, pts: lastPts + frameDur100ns, send: send)
    }

    private func encodeFrame(_ nv12: CVPixelBuffer, pts: Int64, send: NDIlib_send_instance_t) {
        guard let main = mainEncoder else { return }
        lastPts = pts
        lastEncodeAt = Date()
        var desc = describe(w: curW, h: curH, n: curN, d: curD, fourCC: mainFourCC)
        let forceKF = NDIlib_send_is_keyframe_required(send, &desc)
        main.encode(nv12, pts100ns: pts, duration100ns: frameDur100ns, forceKeyframe: forceKF)

        if let pe = previewEncoder, let ps = previewScaler, let small = ps.scale(nv12) {
            var pdesc = describe(w: previewW, h: previewH, n: curN, d: curD, fourCC: previewFourCC)
            let pkf = NDIlib_send_is_keyframe_required(send, &pdesc)
            pe.encode(small, pts100ns: pts, duration100ns: frameDur100ns, forceKeyframe: pkf)
        }
    }

    private var mainFourCC: UInt32 { config.codec == .h264 ? NDIFourCC.h264Highest : NDIFourCC.hevcHighest }
    private var previewFourCC: UInt32 { config.codec == .h264 ? NDIFourCC.h264Lowest : NDIFourCC.hevcLowest }

    private func describe(w: Int, h: Int, n: Int, d: Int, fourCC: UInt32) -> NDIlib_video_frame_v2_t {
        var f = NDIlib_video_frame_v2_t()
        f.xres = Int32(w)
        f.yres = Int32(h)
        f.FourCC = NDIlib_FourCC_video_type_e(rawValue: fourCC)
        f.frame_rate_N = Int32(n > 0 ? n : 30000)
        f.frame_rate_D = Int32(d > 0 ? d : 1001)
        f.picture_aspect_ratio = Float(w) / Float(h)
        f.frame_format_type = NDIlib_frame_format_type_progressive
        f.timecode = NDIlib_send_timecode_synthesize
        return f
    }

    private func rebuildVideo(w: Int, h: Int, n: Int, d: Int, fps: Double, stats: inout BridgeStats) {
        mainEncoder?.invalidate(); previewEncoder?.invalidate()
        mainEncoder = nil; previewEncoder = nil
        lastNV12 = nil
        curW = w; curH = h; curN = n; curD = d
        guard let send = send else { return }

        // Bit-rate: SDK recommendation x preset multiplier, or a fixed custom value.
        var desc = describe(w: w, h: h, n: n, d: d, fourCC: mainFourCC)
        var target = Int(NDIlib_send_get_target_bit_rate(send, &desc))
        if target <= 0 { target = Int(Double(w * h) * fps * 0.1) }   // fallback ≈ 0.1 bit/pixel
        let bitrate = config.preset == .custom
            ? Int(config.customBitrateMbps * 1_000_000)
            : Int(Double(target) * config.preset.bitrateMultiplier)
        stats.targetMbps = Double(bitrate) / 1_000_000

        toNV12 = PixelScaler(width: w, height: h)
        mainEncoder = HXVideoEncoder(
            width: w, height: h, codec: config.codec, bitrate: bitrate, fps: fps,
            keyframeSeconds: config.keyframeIntervalSec, lowLatency: config.lowLatencyEncoder,
            onFrame: { [weak self] f in self?.sendVideo(f, preview: false) },
            onError: { [weak self] m in Log.error("\(self?.tag ?? "") \(m)") })

        if config.sendPreviewStream {
            previewW = 640
            previewH = max(2, Int((640.0 * Double(h) / Double(w) / 2).rounded()) * 2)
            var pdesc = describe(w: previewW, h: previewH, n: n, d: d, fourCC: previewFourCC)
            var ptarget = Int(NDIlib_send_get_target_bit_rate(send, &pdesc))
            if ptarget <= 0 { ptarget = 1_000_000 }
            previewScaler = PixelScaler(width: previewW, height: previewH)
            previewEncoder = HXVideoEncoder(
                width: previewW, height: previewH, codec: config.codec,
                bitrate: max(500_000, Int(Double(ptarget) * config.preset.bitrateMultiplier)), fps: fps,
                keyframeSeconds: config.keyframeIntervalSec, lowLatency: config.lowLatencyEncoder,
                onFrame: { [weak self] f in self?.sendVideo(f, preview: true) },
                onError: { [weak self] m in Log.error("\(self?.tag ?? "") preview: \(m)") })
        } else {
            previewScaler = nil
        }

        mainEncoder?.logTag = "\(tag) main"
        previewEncoder?.logTag = "\(tag) preview"
        let hw = mainEncoder?.hardwareAccelerated == true ? "hardware" : "software"
        let ll = mainEncoder?.usingLowLatencyMode == true ? ", low-latency RC" : ", standard RC"
        stats.inputDescription = String(format: "%dx%d @ %.2f fps", w, h, fps)
        stats.encoderInfo = "\(config.codec.label) \(hw)\(ll), \(String(format: "%.1f", stats.targetMbps)) Mbps, GOP \(config.keyframeIntervalSec)s"
            + (config.sendPreviewStream ? ", preview \(previewW)x\(previewH)" : "")
        Log.info("\(tag) input \(stats.inputDescription) -> \(stats.encoderInfo) (SDK recommended \(String(format: "%.1f", Double(target) / 1_000_000)) Mbps)")
    }

    private func sendVideo(_ f: EncodedVideoFrame, preview: Bool) {
        var data = f.annexB
        if f.keyframe, config.inlineParameterSets, let ps = f.extraData {
            data = ps + f.annexB
        }
        let packet = makeCompressedPacket(
            fourCC: config.codec == .h264 ? NDIFourCC.packetH264 : NDIFourCC.packetHEVC,
            pts: f.pts100ns, dts: f.pts100ns, keyframe: f.keyframe, data: data, extra: f.keyframe ? f.extraData : nil)
        sendLock.lock()
        defer { sendLock.unlock() }
        guard let send = send else { return }
        var frame = describe(w: preview ? previewW : curW, h: preview ? previewH : curH, n: curN, d: curD,
                             fourCC: preview ? previewFourCC : mainFourCC)
        frame.timecode = f.pts100ns
        packet.withUnsafeBytes { raw in
            frame.p_data = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            frame.data_size_in_bytes = Int32(packet.count)
            NDIlib_send_send_video_v2(send, &frame)
        }
        if preview { bytesPreview += packet.count } else {
            bytesMain += packet.count
            framesEncoded += 1
            if f.keyframe { keyframes += 1 }
        }
    }

    /// Copies an NDI UYVY / BGRA frame into a pooled IOSurface-backed CVPixelBuffer.
    private func copyToPixelBuffer(_ v: NDIlib_video_frame_v2_t, base: UnsafeMutablePointer<UInt8>, w: Int, h: Int) -> CVPixelBuffer? {
        let fcc = v.FourCC.rawValue
        let pixelFormat: OSType
        let bytesPerRow: Int
        switch fcc {
        case NDIFourCC.uyvy, NDIFourCC.uyva:
            pixelFormat = kCVPixelFormatType_422YpCbCr8; bytesPerRow = w * 2
        case NDIFourCC.bgra, NDIFourCC.bgrx:
            pixelFormat = kCVPixelFormatType_32BGRA; bytesPerRow = w * 4
        case NDIFourCC.rgba, NDIFourCC.rgbx:
            pixelFormat = kCVPixelFormatType_32RGBA; bytesPerRow = w * 4
        default:
            Log.warn("\(tag) unsupported input FourCC \(fcc)")
            return nil
        }
        let key = "\(w)x\(h)-\(pixelFormat)"
        if key != inputPoolKey {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            inputPool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &inputPool)
            inputPoolKey = key
        }
        guard let pool = inputPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == noErr, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let dst = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let dstStride = CVPixelBufferGetBytesPerRow(pb)
        let srcStride = Int(v.line_stride_in_bytes) > 0 ? Int(v.line_stride_in_bytes) : bytesPerRow
        if dstStride == srcStride {
            memcpy(dst, base, srcStride * h)
        } else {
            for y in 0..<h { memcpy(dst + y * dstStride, base + y * srcStride, bytesPerRow) }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let matrix = h >= 720 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return pb
    }

    // MARK: - Audio

    private func handleAudio(_ a: NDIlib_audio_frame_v2_t, stats: inout BridgeStats) {
        guard let send = send, a.no_samples > 0, let data = a.p_data else { return }
        switch config.audioMode {
        case .off:
            return
        case .pcm:
            var copy = a
            NDIlib_send_send_audio_v2(send, &copy)
            stats.audioInfo = "PCM \(a.no_channels)ch @ \(a.sample_rate) Hz"
        case .opus:
            let sr = Int(a.sample_rate), srcCh = Int(a.no_channels)
            let ch = min(srcCh, 16)
            let key = "\(sr)-\(srcCh)"
            if opus == nil || opus!.channels != ch {
                guard sr == 48000 else {
                    if opusFailedKey != key { Log.error("\(tag) Opus needs 48 kHz audio; source is \(sr) Hz. Use AAC or uncompressed."); opusFailedKey = key }
                    return
                }
                opus = OpusMultiEncoder(channels: ch, bitratePerChannel: config.opusKbpsPerChannel * 1000, layout: config.opusLayout)
                if opus == nil {
                    if opusFailedKey != key { Log.error("\(tag) could not create Opus encoder for \(ch) channels"); opusFailedKey = key }
                    return
                }
                if srcCh > 16 { Log.warn("\(tag) source has \(srcCh) audio channels; Opus output carries the first 16") }
                stats.audioInfo = "Opus \(ch)ch @ 48 kHz, \(config.opusKbpsPerChannel * ch) kbps (\(opus!.streams) streams)"
                Log.info("\(tag) audio: \(stats.audioInfo), layout \(config.opusLayout.rawValue)")
            }
            let pts = (a.timestamp != NDIlib_recv_timestamp_undefined && a.timestamp > 0) ? a.timestamp : a.timecode
            let packets = opus!.encode(planar: data, frames: Int(a.no_samples), sourceChannels: srcCh,
                                       channelStrideBytes: Int(a.channel_stride_in_bytes), pts100ns: pts)
            for p in packets { sendOpus(send: send, packet: p, channels: ch) }
        case .aac:
            let sr = Int(a.sample_rate), ch = Int(a.no_channels)
            if aac == nil || aac!.sampleRate != sr || aac!.channels != min(ch, 2) {
                aac = AACEncoder(sampleRate: sr, channels: ch, bitrate: config.aacBitrateKbps * 1000)
                if aac == nil { Log.error("\(tag) could not create AAC encoder for \(ch)ch @ \(sr) Hz"); return }
                if ch > 2 { Log.warn("\(tag) source has \(ch) audio channels; AAC output uses the first 2") }
                stats.audioInfo = "AAC-LC \(min(ch, 2))ch @ \(sr) Hz, \(config.aacBitrateKbps) kbps"
            }
            let pts = (a.timestamp != NDIlib_recv_timestamp_undefined && a.timestamp > 0) ? a.timestamp : a.timecode
            let packets = aac!.encode(planar: data, frames: Int(a.no_samples), sourceChannels: ch,
                                      channelStrideBytes: Int(a.channel_stride_in_bytes), pts100ns: pts)
            for p in packets {
                let packet = makeCompressedPacket(fourCC: NDIFourCC.packetAAC, pts: p.pts100ns, dts: p.pts100ns,
                                                  keyframe: true, data: p.data, extra: aac!.audioSpecificConfig)
                var af = NDIlib_audio_frame_v3_t()
                af.sample_rate = Int32(sr)
                af.no_channels = Int32(aac!.channels)
                af.no_samples = Int32(p.samples)
                af.timecode = p.pts100ns
                af.FourCC = NDIlib_FourCC_audio_type_e(rawValue: NDIFourCC.audioAAC)
                packet.withUnsafeBytes { raw in
                    af.p_data = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
                    af.data_size_in_bytes = Int32(packet.count)
                    NDIlib_send_send_audio_v3(send, &af)
                }
            }
        }
    }

    private func sendOpus(send: NDIlib_send_instance_t, packet p: EncodedAudioPacket, channels: Int) {
        sendOpusFrame(send: send, data: p.data, channels: channels, samples: p.samples, timecode: p.pts100ns)
    }

    // MARK: - Cleanup

    private func teardown() {
        mainEncoder?.invalidate(); previewEncoder?.invalidate()   // flushes pending callbacks
        mainEncoder = nil; previewEncoder = nil
        toNV12 = nil; previewScaler = nil; aac = nil; opus = nil; inputPool = nil; lastNV12 = nil
        sendLock.lock()
        if let s = send { NDIlib_send_destroy(s) }
        send = nil
        sendLock.unlock()
    }
}

/// NDI multichannel Opus: raw Opus packet in the audio frame, no compressed-packet header.
func sendOpusFrame(send: NDIlib_send_instance_t, data: Data, channels: Int, samples: Int, timecode: Int64) {
    var af = NDIlib_audio_frame_v3_t()
    af.sample_rate = 48000
    af.no_channels = Int32(channels)
    af.no_samples = Int32(samples)
    af.timecode = timecode
    af.FourCC = NDIlib_FourCC_audio_type_e(rawValue: NDIFourCC.audioOpus)
    data.withUnsafeBytes { raw in
        af.p_data = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
        af.data_size_in_bytes = Int32(data.count)
        NDIlib_send_send_audio_v3(send, &af)
    }
}

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}
