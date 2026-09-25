import Foundation

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264" : "H.265 / HEVC" }
}

/// HX2 / HX3 are encoder presets. NDI does not publish exact encoder settings for these formats,
/// so these map to the SDK's recommended bit-rate (NDIlib_send_get_target_bit_rate) plus GOP/latency choices.
enum HXPreset: String, Codable, CaseIterable, Identifiable {
    case hx2, hx3, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hx2: return "HX2"
        case .hx3: return "HX3"
        case .custom: return "Custom"
        }
    }
    /// Multiplier applied to the SDK's recommended HX bit-rate (NDI recommends 0.1x – 2.0x).
    var bitrateMultiplier: Double {
        switch self {
        case .hx2: return 1.0
        case .hx3: return 2.0
        case .custom: return 1.0
        }
    }
    var defaultKeyframeSeconds: Double { self == .hx2 ? 2.0 : 1.0 }
}

enum AudioMode: String, Codable, CaseIterable, Identifiable {
    case opus, aac, pcm, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .opus: return "Opus, all channels (NDI 5+ receivers)"
        case .aac: return "AAC stereo, channels 1–2 (works with NDI 4)"
        case .pcm: return "Uncompressed, all channels (high bandwidth)"
        case .off: return "No audio"
        }
    }
}

struct BridgeConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var sourceName = ""
    var outputName = "HX Bridge"
    var outputGroups = "public"
    var codec: VideoCodec = .h264
    var preset: HXPreset = .hx3
    var customBitrateMbps: Double = 20
    var keyframeIntervalSec: Double = 1.0
    var sendPreviewStream = true
    var skipEncodeWithoutReceivers = true
    var audioMode: AudioMode = .opus
    var aacBitrateKbps = 192
    var opusKbpsPerChannel = 96
    var opusLayout: OpusLayout = .ndi
    var forwardTally = true
    var autoStart = true
    /// Apple's low-latency rate control (video-conferencing mode). Turn off if a receiver can't decode.
    var lowLatencyEncoder = true
    /// Also put SPS/PPS (VPS) in front of every keyframe's data, not only in NDI's extra-data field.
    var inlineParameterSets = true

    init() {}

    // Tolerant decoding so older config files keep working as fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BridgeConfig()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? d.sourceName
        outputName = try c.decodeIfPresent(String.self, forKey: .outputName) ?? d.outputName
        outputGroups = try c.decodeIfPresent(String.self, forKey: .outputGroups) ?? d.outputGroups
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? d.codec
        preset = try c.decodeIfPresent(HXPreset.self, forKey: .preset) ?? d.preset
        customBitrateMbps = try c.decodeIfPresent(Double.self, forKey: .customBitrateMbps) ?? d.customBitrateMbps
        keyframeIntervalSec = try c.decodeIfPresent(Double.self, forKey: .keyframeIntervalSec) ?? d.keyframeIntervalSec
        sendPreviewStream = try c.decodeIfPresent(Bool.self, forKey: .sendPreviewStream) ?? d.sendPreviewStream
        skipEncodeWithoutReceivers = try c.decodeIfPresent(Bool.self, forKey: .skipEncodeWithoutReceivers) ?? d.skipEncodeWithoutReceivers
        audioMode = try c.decodeIfPresent(AudioMode.self, forKey: .audioMode) ?? d.audioMode
        aacBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .aacBitrateKbps) ?? d.aacBitrateKbps
        opusKbpsPerChannel = try c.decodeIfPresent(Int.self, forKey: .opusKbpsPerChannel) ?? d.opusKbpsPerChannel
        opusLayout = try c.decodeIfPresent(OpusLayout.self, forKey: .opusLayout) ?? d.opusLayout
        forwardTally = try c.decodeIfPresent(Bool.self, forKey: .forwardTally) ?? d.forwardTally
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? d.autoStart
        lowLatencyEncoder = try c.decodeIfPresent(Bool.self, forKey: .lowLatencyEncoder) ?? d.lowLatencyEncoder
        inlineParameterSets = try c.decodeIfPresent(Bool.self, forKey: .inlineParameterSets) ?? d.inlineParameterSets
    }
}

struct AppSettings: Codable, Equatable {
    /// NDI groups searched for input sources (comma separated), e.g. "propres-local" or "public,propres-local".
    var inputGroups = "public"
    var vendorName = ""
    var vendorID = ""
    var startBridgesOnLaunch = true
    var bridges: [BridgeConfig] = [BridgeConfig()]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        inputGroups = try c.decodeIfPresent(String.self, forKey: .inputGroups) ?? d.inputGroups
        vendorName = try c.decodeIfPresent(String.self, forKey: .vendorName) ?? d.vendorName
        vendorID = try c.decodeIfPresent(String.self, forKey: .vendorID) ?? d.vendorID
        startBridgesOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .startBridgesOnLaunch) ?? d.startBridgesOnLaunch
        bridges = try c.decodeIfPresent([BridgeConfig].self, forKey: .bridges) ?? d.bridges
    }

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("MillstoneHXBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.json")
        // One-time migration from the app's earlier name.
        let old = support.appendingPathComponent("NDIHXBridge/config.json")
        if !FileManager.default.fileExists(atPath: file.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: file)
        }
        return file
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: AppSettings.fileURL, options: .atomic) }
    }

    /// JSON passed to NDI create functions (vendor + optional groups).
    func ndiConfigJSON(sendGroups: String? = nil, recvGroups: String? = nil) -> String {
        var ndi: [String: Any] = [:]
        if !vendorID.trimmingCharacters(in: .whitespaces).isEmpty {
            ndi["vendor"] = ["name": vendorName, "id": vendorID.trimmingCharacters(in: .whitespaces)]
        }
        var groups: [String: String] = [:]
        if let s = sendGroups, !s.isEmpty { groups["send"] = s }
        if let r = recvGroups, !r.isEmpty { groups["recv"] = r }
        if !groups.isEmpty { ndi["groups"] = groups }
        let obj: [String: Any] = ["ndi": ndi]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Stand-in for @State (the Command Line Tools lack the SwiftUI macro plugin that @State needs on newer SDKs).
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}
