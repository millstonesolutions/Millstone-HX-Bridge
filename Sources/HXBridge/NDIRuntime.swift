import Foundation
import CNDI

func fourCC(_ s: String) -> UInt32 {
    var r: UInt32 = 0
    for (i, b) in s.utf8.prefix(4).enumerated() { r |= UInt32(b) << (8 * UInt32(i)) }
    return r
}

enum NDIFourCC {
    // Video frame FourCCs for compressed sends (Advanced SDK).
    static let h264Highest = fourCC("H264")
    static let h264Lowest = fourCC("h264")
    static let hevcHighest = fourCC("HEVC")
    static let hevcLowest = fourCC("hevc")
    // FourCC inside NDIlib_compressed_packet_t.
    static let packetH264 = fourCC("H264")
    static let packetHEVC = fourCC("HEVC")
    static let packetAAC: UInt32 = 0x00FF
    // Audio frame FourCC for AAC.
    static let audioAAC: UInt32 = 0x00FF
    static let audioOpus = fourCC("Opus")
    // Uncompressed.
    static let uyvy = fourCC("UYVY")
    static let uyva = fourCC("UYVA")
    static let bgra = fourCC("BGRA")
    static let bgrx = fourCC("BGRX")
    static let rgba = fourCC("RGBA")
    static let rgbx = fourCC("RGBX")
}

enum NDIRuntime {
    private static var initialized = false
    static func initialize() -> Bool {
        if initialized { return true }
        initialized = NDIlib_initialize()
        return initialized
    }
    static var version: String {
        guard let v = NDIlib_version() else { return "unknown" }
        return String(cString: v)
    }
}

/// Keeps C strings alive for the duration of an NDI create call (and beyond, if retained).
final class CStringBox {
    private var ptrs: [UnsafeMutablePointer<CChar>] = []
    func make(_ s: String?) -> UnsafePointer<CChar>? {
        guard let s = s, !s.isEmpty else { return nil }
        let p = strdup(s)!
        ptrs.append(p)
        return UnsafePointer(p)
    }
    deinit { ptrs.forEach { free($0) } }
}

/// Builds the Advanced SDK compressed packet: 44-byte header + data + extra data (little endian).
func makeCompressedPacket(fourCC: UInt32, pts: Int64, dts: Int64, keyframe: Bool, data: Data, extra: Data?) -> Data {
    var out = Data(capacity: 44 + data.count + (extra?.count ?? 0))
    func put<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }
    put(Int32(44))                    // version (structure size)
    put(fourCC)                       // fourCC
    put(pts)                          // pts (100 ns)
    put(dts)                          // dts (100 ns)
    put(UInt64(0))                    // reserved
    put(UInt32(keyframe ? 1 : 0))     // flags
    put(UInt32(data.count))           // data_size
    put(UInt32(extra?.count ?? 0))    // extra_data_size
    out.append(data)
    if let e = extra { out.append(e) }
    return out
}
