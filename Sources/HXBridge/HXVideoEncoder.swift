import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// One encoded access unit ready for NDI: Annex B data (+ parameter sets on keyframes).
struct EncodedVideoFrame {
    var annexB: Data
    var extraData: Data?
    var keyframe: Bool
    var pts100ns: Int64
}

/// Hardware H.264 / HEVC encoder (Apple media engine) configured for low-latency NDI HX.
final class HXVideoEncoder {
    let width: Int
    let height: Int
    let codec: VideoCodec
    private(set) var bitrate: Int
    private var session: VTCompressionSession?
    private let onFrame: (EncodedVideoFrame) -> Void
    private let onError: (String) -> Void
    private(set) var usingLowLatencyMode = false
    private(set) var hardwareAccelerated = false

    private var nalLogCount = 0
    var logTag = ""

    init?(width: Int, height: Int, codec: VideoCodec, bitrate: Int, fps: Double, keyframeSeconds: Double,
          lowLatency: Bool = true,
          onFrame: @escaping (EncodedVideoFrame) -> Void, onError: @escaping (String) -> Void) {
        self.width = width
        self.height = height
        self.codec = codec
        self.bitrate = bitrate
        self.onFrame = onFrame
        self.onError = onError

        let codecType = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        var created: VTCompressionSession?
        // Try low-latency rate control first (Apple Silicon), then fall back to regular hardware encoding.
        let specs: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
             kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
            [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
            [:],
        ]
        for (i, spec) in specs.enumerated() where lowLatency || i > 0 {
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: codecType, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            if status == noErr, created != nil {
                usingLowLatencyMode = (i == 0)
                hardwareAccelerated = (i < 2)   // specs 0 and 1 require the hardware encoder
                break
            }
            created = nil
        }
        guard let s = created else {
            onError("Could not create \(codec.label) encoder for \(width)x\(height)")
            return nil
        }
        session = s

        func set(_ key: CFString, _ value: Any) {
            let st = VTSessionSetProperty(s, key: key, value: value as CFTypeRef)
            if st != noErr { NSLog("[encoder] property %@ not applied (%d)", key as String, st) }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)   // no B-frames: lowest latency
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
        if codec == .h264 { set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC) }
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        let gopFrames = max(1, Int((fps * keyframeSeconds).rounded()))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: gopFrames))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: keyframeSeconds))
        // Cap bursts so big I-frames don't delay the following P-frames (NDI latency guidance).
        let bytesPerSecondCap = Double(bitrate) * 1.5 / 8.0
        set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bytesPerSecondCap), NSNumber(value: 1.0)] as CFArray)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        if !hardwareAccelerated {
            var hw: CFBoolean?
            if VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                     allocator: nil, valueOut: &hw) == noErr, let hw = hw {
                hardwareAccelerated = CFBooleanGetValue(hw)
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { invalidate() }

    func invalidate() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
    }

    func updateBitrate(_ newBitrate: Int) {
        guard let s = session, newBitrate != bitrate, newBitrate > 0 else { return }
        bitrate = newBitrate
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: newBitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: Double(newBitrate) * 1.5 / 8.0), NSNumber(value: 1.0)] as CFArray)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts100ns: Int64, duration100ns: Int64, forceKeyframe: Bool) {
        guard let s = session else { return }
        let pts = CMTime(value: pts100ns, timescale: 10_000_000)
        let dur = CMTime(value: duration100ns, timescale: 10_000_000)
        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            s, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: dur,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self = self else { return }
            if status != noErr { self.onError("Encode error \(status)"); return }
            guard let sb = sampleBuffer else { return }  // frame dropped by encoder
            if let frame = self.package(sb) { self.onFrame(frame) }
        }
        if status != noErr { onError("EncodeFrame failed \(status)") }
    }

    // MARK: - AVCC/HVCC (length prefixed) -> Annex B

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private func package(_ sb: CMSampleBuffer) -> EncodedVideoFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copyStatus == noErr else { return nil }

        var keyframe = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]],
           let first = atts.first {
            let notSync = (first[kCMSampleAttachmentKey_NotSync as String] as? Bool) ?? false
            keyframe = !notSync
        }

        let fmt = CMSampleBufferGetFormatDescription(sb)
        var nalLengthSize = 4
        var extra: Data? = nil
        if let fmt = fmt {
            let (params, hdrLen) = parameterSets(fmt)
            if hdrLen > 0 { nalLengthSize = hdrLen }
            if keyframe && !params.isEmpty {
                var e = Data()
                for p in params { e.append(contentsOf: Self.startCode); e.append(p) }
                extra = e
            }
        }

        var annexB = Data(capacity: length + 64)
        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + nalLengthSize <= length {
                var nalLen = 0
                for i in 0..<nalLengthSize { nalLen = (nalLen << 8) | Int(bytes[offset + i]) }
                offset += nalLengthSize
                guard nalLen > 0, offset + nalLen <= length else { break }
                annexB.append(contentsOf: Self.startCode)
                annexB.append(bytes.baseAddress! + offset, count: nalLen)
                offset += nalLen
            }
        }

        if nalLogCount < 6 && (keyframe || nalLogCount < 3) {
            nalLogCount += 1
            Log.info("\(logTag) \(keyframe ? "keyframe" : "frame") NAL types: \(Self.nalTypes(annexB, hevc: codec == .hevc)) extra: \(extra.map { Self.nalTypes($0, hevc: codec == .hevc) } ?? "none")")
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let pts100 = pts.isValid ? Int64((CMTimeGetSeconds(pts) * 10_000_000).rounded()) : 0
        return EncodedVideoFrame(annexB: annexB, extraData: extra, keyframe: keyframe, pts100ns: pts100)
    }

    /// Lists NAL unit types in an Annex B buffer (H.264: 5=IDR, 1=slice, 6=SEI, 7=SPS, 8=PPS, 9=AUD;
    /// HEVC: 19/20=IDR, 1=slice, 32=VPS, 33=SPS, 34=PPS, 39=SEI).
    static func nalTypes(_ d: Data, hevc: Bool) -> String {
        var types: [Int] = []
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 3 < b.count {
                if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                    let h = b[i + 3]
                    types.append(hevc ? Int((h >> 1) & 0x3F) : Int(h & 0x1F))
                    i += 3
                } else { i += 1 }
            }
        }
        return types.map(String.init).joined(separator: ",")
    }

    private func parameterSets(_ fmt: CMFormatDescription) -> ([Data], Int) {
        var sets: [Data] = []
        var count = 0
        var headerLen: Int32 = 0
        if codec == .h264 {
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLen) == noErr else { return ([], 4) }
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr = ptr {
                    sets.append(Data(bytes: ptr, count: size))
                }
            }
        } else {
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLen) == noErr else { return ([], 4) }
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr = ptr {
                    sets.append(Data(bytes: ptr, count: size))
                }
            }
        }
        return (sets, Int(headerLen))
    }
}

/// GPU-backed scaler / format converter (VTPixelTransferSession) with a buffer pool.
final class PixelScaler {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    let width: Int
    let height: Int

    init?(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.width = width
        self.height = height
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
              let s = session else { return nil }
        VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        if pool == nil { return nil }
    }

    deinit { if let s = session { VTPixelTransferSessionInvalidate(s) } }

    func scale(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard let s = session, let pool = pool else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == noErr, let d = dst else { return nil }
        CVBufferSetAttachment(d, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(d, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(d, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return VTPixelTransferSessionTransferImage(s, from: src, to: d) == noErr ? d : nil
    }
}
