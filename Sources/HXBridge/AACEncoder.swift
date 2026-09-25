import Foundation
import AVFoundation

struct EncodedAudioPacket {
    var data: Data
    var pts100ns: Int64
    var samples: Int
}

/// Float planar PCM -> AAC-LC packets (1024 samples each) using AudioToolbox via AVAudioConverter.
final class AACEncoder {
    let sampleRate: Int
    let channels: Int
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var pending: [AVAudioPCMBuffer] = []
    private var samplesOut: Int64 = 0
    private var basePts: Int64?
    /// 2-byte AudioSpecificConfig required by NDI as extra data on every AAC packet.
    let audioSpecificConfig: Data

    init?(sampleRate: Int, channels: Int, bitrate: Int) {
        let ch = max(1, min(channels, 2))
        guard let inF = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(ch))
        else { return nil }
        var desc = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(ch), mBitsPerChannel: 0, mReserved: 0)
        guard let outF = AVAudioFormat(streamDescription: &desc),
              let conv = AVAudioConverter(from: inF, to: outF) else { return nil }
        conv.bitRate = bitrate
        self.sampleRate = sampleRate
        self.channels = ch
        self.inputFormat = inF
        self.outputFormat = outF
        self.converter = conv

        let freqTable = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let freqIndex = UInt16(freqTable.firstIndex(of: sampleRate) ?? 3)
        let asc: UInt16 = (2 << 11) | (freqIndex << 7) | (UInt16(ch) << 3)   // AAC-LC
        audioSpecificConfig = Data([UInt8(asc >> 8), UInt8(asc & 0xFF)])
    }

    /// Feed planar float audio. `channelStrideBytes` is the distance between channel planes.
    func encode(planar: UnsafePointer<Float>, frames: Int, sourceChannels: Int, channelStrideBytes: Int,
                pts100ns: Int64) -> [EncodedAudioPacket] {
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        buf.frameLength = AVAudioFrameCount(frames)
        let floatsPerPlane = channelStrideBytes / MemoryLayout<Float>.size
        for c in 0..<channels {
            let srcChannel = min(c, sourceChannels - 1)
            let src = planar + srcChannel * floatsPerPlane
            buf.floatChannelData![c].update(from: src, count: frames)
        }
        if basePts == nil { basePts = pts100ns }
        pending.append(buf)
        return drain()
    }

    private func drain() -> [EncodedAudioPacket] {
        var packets: [EncodedAudioPacket] = []
        while true {
            let out = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 8,
                                              maximumPacketSize: max(converter.maximumOutputPacketSize, 2048))
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { [weak self] _, inStatus in
                guard let self = self, !self.pending.isEmpty else {
                    inStatus.pointee = .noDataNow
                    return nil
                }
                inStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            if status == .error { if let e = error { NSLog("[aac] %@", e.localizedDescription) }; break }
            let count = Int(out.packetCount)
            if count == 0 { break }
            for i in 0..<count {
                guard let d = out.packetDescriptions?[i] else { continue }
                let bytes = Data(bytes: out.data + Int(d.mStartOffset), count: Int(d.mDataByteSize))
                let pts = (basePts ?? 0) + samplesOut * 10_000_000 / Int64(sampleRate)
                packets.append(EncodedAudioPacket(data: bytes, pts100ns: pts, samples: 1024))
                samplesOut += 1024
            }
            if status == .inputRanDry { break }
        }
        return packets
    }
}
