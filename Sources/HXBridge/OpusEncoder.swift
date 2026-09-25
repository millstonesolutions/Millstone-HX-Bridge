import Foundation
import COpus

enum OpusLayout: String, Codable, CaseIterable {
    /// What NDI's decoder expects (found by round-trip test): channels in their original order, grouped as
    /// stereo pairs (1-2, 3-4, …) with a trailing mono stream for an odd count; identity mapping, no LFE.
    case ndi
    /// Every channel its own mono stream. NDI does not decode this.
    case independent
    /// Opus surround encoder (family 1): NDI decodes it, but reorders channels and low-passes one as LFE.
    case surround

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OpusLayout(rawValue: raw) ?? .ndi
    }

    /// Family-1 (Vorbis) streams / coupled streams for 1...8 channels.
    static func family1Counts(_ channels: Int) -> (streams: Int, coupled: Int) {
        let table: [(Int, Int)] = [(1, 0), (1, 1), (2, 1), (2, 2), (3, 2), (4, 2), (5, 2), (5, 3)]
        return table[max(1, min(channels, 8)) - 1]
    }
}

/// Float planar PCM (48 kHz) -> multichannel Opus packets (20 ms each) for NDI.
final class OpusMultiEncoder {
    let channels: Int
    let frameSize = 960              // 20 ms at 48 kHz
    let sampleRate = 48000
    private var enc: OpaquePointer?
    private var fifo: [Float] = []   // interleaved
    private var samplesOut: Int64 = 0
    private var basePts: Int64?
    private var outBuf = [UInt8](repeating: 0, count: 1)
    private(set) var streams = 0
    private(set) var coupled = 0

    init?(channels: Int, bitratePerChannel: Int, layout: OpusLayout) {
        guard channels >= 1, channels <= 255 else { return nil }
        self.channels = channels
        var err: Int32 = 0
        switch layout {
        case .ndi:
            let c = channels / 2, s = (channels + 1) / 2
            var mapping = (0..<channels).map { UInt8($0) }
            enc = opus_multistream_encoder_create(48000, Int32(channels), Int32(s), Int32(c),
                                                  &mapping, OPUS_APPLICATION_AUDIO, &err)
            streams = s; coupled = c
        case .independent:
            var mapping = (0..<channels).map { UInt8($0) }
            enc = opus_multistream_encoder_create(48000, Int32(channels), Int32(channels), 0,
                                                  &mapping, OPUS_APPLICATION_AUDIO, &err)
            streams = channels; coupled = 0
        case .surround:
            var s: Int32 = 0, c: Int32 = 0
            var mapping = [UInt8](repeating: 0, count: 256)
            enc = opus_multistream_surround_encoder_create(48000, Int32(channels), channels <= 8 ? 1 : 255,
                                                           &s, &c, &mapping, OPUS_APPLICATION_AUDIO, &err)
            streams = Int(s); coupled = Int(c)
        }
        guard err == OPUS_OK, let e = enc else { return nil }
        copus_ms_set_bitrate(e, Int32(bitratePerChannel * channels))
        copus_ms_set_complexity(e, 8)
        outBuf = [UInt8](repeating: 0, count: 1500 * channels)
    }

    deinit { if let e = enc { opus_multistream_encoder_destroy(e) } }

    func encode(planar: UnsafePointer<Float>, frames: Int, sourceChannels: Int, channelStrideBytes: Int,
                pts100ns: Int64) -> [EncodedAudioPacket] {
        guard let e = enc, frames > 0 else { return [] }
        if basePts == nil { basePts = pts100ns }
        let plane = channelStrideBytes / MemoryLayout<Float>.size
        let start = fifo.count
        fifo.reserveCapacity(start + frames * channels)
        fifo.append(contentsOf: repeatElement(0, count: frames * channels))
        for c in 0..<min(channels, sourceChannels) {
            let src = planar + c * plane
            for i in 0..<frames { fifo[start + i * channels + c] = src[i] }
        }
        var packets: [EncodedAudioPacket] = []
        let chunk = frameSize * channels
        while fifo.count >= chunk {
            let n = fifo.withUnsafeBufferPointer { inp in
                outBuf.withUnsafeMutableBufferPointer { out in
                    opus_multistream_encode_float(e, inp.baseAddress!, Int32(frameSize), out.baseAddress!, Int32(out.count))
                }
            }
            fifo.removeFirst(chunk)
            if n > 0 {
                let pts = (basePts ?? 0) + samplesOut * 10_000_000 / Int64(sampleRate)
                packets.append(EncodedAudioPacket(data: Data(outBuf[0..<Int(n)]), pts100ns: pts, samples: frameSize))
            } else {
                NSLog("[opus] encode error %d", n)
            }
            samplesOut += Int64(frameSize)
        }
        return packets
    }
}
