import Foundation

public enum H264Stream {
    public static let startCode: [UInt8] = [0, 0, 0, 1]
    public static let accessUnitDelimiter: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]

    // VideoToolbox gives length-prefixed NAL units (AVCC); MPEG-TS wants start codes, an AUD first and SPS/PPS before every key frame.
    public static func annexB(fromAVCC data: Data, nalLengthSize: Int, parameterSets: [Data]) -> Data? {
        guard (1...4).contains(nalLengthSize) else { return nil }
        var out = Data(accessUnitDelimiter)
        for ps in parameterSets {
            out.append(contentsOf: startCode)
            out.append(ps)
        }
        let bytes = [UInt8](data)
        var i = 0
        var count = 0
        while i < bytes.count {
            guard i + nalLengthSize <= bytes.count else { return nil }
            var len = 0
            for k in 0..<nalLengthSize { len = (len << 8) | Int(bytes[i + k]) }
            i += nalLengthSize
            guard len > 0, i + len <= bytes.count else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[i..<(i + len)])
            i += len
            count += 1
        }
        return count > 0 ? out : nil
    }
}

public enum AdtsHeader {
    public static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    public static func make(payloadLength: Int, sampleRate: Int = 48000, channels: Int = 2) -> Data? {
        guard let idx = sampleRates.firstIndex(of: sampleRate), (1...7).contains(channels) else { return nil }
        let len = payloadLength + 7
        guard len < 8192 else { return nil }
        return Data([
            0xFF, 0xF1,
            UInt8((1 << 6) | (idx << 2) | (channels >> 2)),
            UInt8(((channels & 3) << 6) | (len >> 11)),
            UInt8((len & 0x7FF) >> 3),
            UInt8(((len & 7) << 5) | 0x1F),
            0xFC
        ])
    }
}

public final class TsMuxer {
    public static let packetSize = 188
    public static let videoPID: UInt16 = 0x100
    public static let audioPID: UInt16 = 0x101
    public static let pmtPID: UInt16 = 0x1000

    public let hasAudio: Bool
    private var counters: [UInt16: UInt8] = [:]
    private var psiCounters: [UInt16: UInt8] = [:]

    public init(hasAudio: Bool = true) { self.hasAudio = hasAudio }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes {
            crc ^= UInt32(b) << 24
            for _ in 0..<8 { crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04C11DB7 : crc << 1 }
        }
        return crc
    }

    private static func withCRC(_ section: [UInt8]) -> [UInt8] {
        let c = crc32(section)
        return section + [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
    }

    public func patSection() -> [UInt8] {
        Self.withCRC([0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF)])
    }

    public func pmtSection() -> [UInt8] {
        var streams: [UInt8] = [0x1B, 0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        if hasAudio { streams += [0x0F, 0xE0 | UInt8(Self.audioPID >> 8), UInt8(Self.audioPID & 0xFF), 0xF0, 0x00] }
        let length = 13 + streams.count
        var s: [UInt8] = [0x02, 0xB0 | UInt8((length >> 8) & 0x0F), UInt8(length & 0xFF), 0x00, 0x01, 0xC1, 0x00, 0x00,
                          0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        s += streams
        return Self.withCRC(s)
    }

    private func nextCC(_ pid: UInt16, psi: Bool = false) -> UInt8 {
        if psi {
            let v = psiCounters[pid] ?? 0
            psiCounters[pid] = (v + 1) & 0x0F
            return v
        }
        let v = counters[pid] ?? 0
        counters[pid] = (v + 1) & 0x0F
        return v
    }

    private func psiPacket(pid: UInt16, section: [UInt8]) -> Data {
        var p = [UInt8](repeating: 0xFF, count: Self.packetSize)
        p[0] = 0x47
        p[1] = 0x40 | UInt8(pid >> 8)
        p[2] = UInt8(pid & 0xFF)
        p[3] = 0x10 | nextCC(pid, psi: true)
        p[4] = 0x00
        for (i, b) in section.enumerated() { p[5 + i] = b }
        return Data(p)
    }

    public func patPmt() -> Data {
        var d = psiPacket(pid: 0, section: patSection())
        d.append(psiPacket(pid: Self.pmtPID, section: pmtSection()))
        return d
    }

    static func pts(_ marker: UInt8, _ v: Int64) -> [UInt8] {
        [
            (marker << 4) | UInt8((v >> 29) & 0x0E) | 1,
            UInt8((v >> 22) & 0xFF),
            UInt8(((v >> 14) & 0xFE)) | 1,
            UInt8((v >> 7) & 0xFF),
            UInt8((v << 1) & 0xFE) | 1
        ]
    }

    static func pcr(_ base: Int64) -> [UInt8] {
        [UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF), UInt8((base >> 9) & 0xFF), UInt8((base >> 1) & 0xFF),
         UInt8(((base & 1) << 7) | 0x7E), 0x00]
    }

    func packetize(pid: UInt16, payload: [UInt8], pcrBase: Int64?, randomAccess: Bool) -> Data {
        var out = Data()
        var offset = 0
        var first = true
        while offset < payload.count {
            var p = [UInt8](repeating: 0xFF, count: Self.packetSize)
            p[0] = 0x47
            p[1] = (first ? 0x40 : 0) | UInt8(pid >> 8)
            p[2] = UInt8(pid & 0xFF)
            var af: [UInt8] = []
            var hasAF = false
            if first && (pcrBase != nil || randomAccess) {
                hasAF = true
                af = [(randomAccess ? 0x40 : 0) | (pcrBase != nil ? 0x10 : 0)]
                if let b = pcrBase { af += Self.pcr(b) }
            }
            let remaining = payload.count - offset
            var space = 184 - (hasAF ? 1 + af.count : 0)
            if remaining < space {
                let stuffing = space - remaining
                if hasAF {
                    af += [UInt8](repeating: 0xFF, count: stuffing)
                } else if stuffing == 1 {
                    hasAF = true
                    af = []
                } else {
                    hasAF = true
                    af = [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2)
                }
                space = remaining
            }
            var pos = 4
            if hasAF {
                p[pos] = UInt8(af.count)
                pos += 1
                for b in af { p[pos] = b; pos += 1 }
            }
            for i in 0..<space { p[pos + i] = payload[offset + i] }
            p[3] = (hasAF ? 0x30 : 0x10) | nextCC(pid)
            out.append(contentsOf: p)
            offset += space
            first = false
        }
        return out
    }

    // pts is in 90 kHz ticks.
    public func video(annexB: Data, pts: Int64, isKey: Bool) -> Data {
        var pes: [UInt8] = [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x84, 0x80, 0x05]
        pes += Self.pts(0x2, pts)
        pes += [UInt8](annexB)
        var out = isKey ? patPmt() : Data()
        out.append(packetize(pid: Self.videoPID, payload: pes, pcrBase: max(pts - 4500, 0), randomAccess: isKey))
        return out
    }

    public func audio(adts: Data, pts: Int64) -> Data {
        let body = [UInt8](adts)
        let length = min(3 + 5 + body.count, 0xFFFF)
        var pes: [UInt8] = [0x00, 0x00, 0x01, 0xC0, UInt8(length >> 8), UInt8(length & 0xFF), 0x84, 0x80, 0x05]
        pes += Self.pts(0x2, pts)
        pes += body
        return packetize(pid: Self.audioPID, payload: pes, pcrBase: nil, randomAccess: false)
    }
}
