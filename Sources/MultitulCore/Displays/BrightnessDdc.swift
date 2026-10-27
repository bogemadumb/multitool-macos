import Foundation

public enum VcpCode {
    public static let brightness: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let power: UInt8 = 0xD6
}

public enum DdcPowerState: UInt16, Sendable {
    case on = 1
    case standby = 4
    case off = 5
}

public enum DdcReadResult: Equatable, Sendable {
    case value(current: UInt16, maximum: UInt16)
    case unsupported
    case wrongCode
    case checksumMismatch
    case malformed
}

public enum DdcChannelOutcome: Equatable, Sendable {
    case live
    case writeOnly
    case dead
}

public enum DdcPacket {
    public static let chipAddress: UInt32 = 0x37
    public static let dataAddress: UInt32 = 0x51
    public static let replyLength = 11
    static let hostReplySeed: UInt8 = 0x50
    static let opcodeSet: UInt8 = 0x03
    static let opcodeGet: UInt8 = 0x01
    static let opcodeReply: UInt8 = 0x02

    // Destination byte (chip << 1) always seeds the XOR; the 0x51 sub-address joins only multi-argument packets.
    public static func checksum(opcode: UInt8, arguments: [UInt8]) -> UInt8 {
        let lengthByte = UInt8(0x80 | (arguments.count + 1))
        var seed = UInt8(chipAddress << 1)
        if arguments.count != 1 { seed ^= UInt8(dataAddress) }
        var sum = seed ^ lengthByte ^ opcode
        for b in arguments { sum ^= b }
        return sum
    }

    public static func frame(opcode: UInt8, arguments: [UInt8]) -> [UInt8] {
        [UInt8(0x80 | (arguments.count + 1)), opcode] + arguments + [checksum(opcode: opcode, arguments: arguments)]
    }

    public static func setVcp(_ code: UInt8, value: UInt16) -> [UInt8] {
        frame(opcode: opcodeSet, arguments: [code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    public static func getVcp(_ code: UInt8) -> [UInt8] {
        frame(opcode: opcodeGet, arguments: [code])
    }

    public static func replyChecksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.dropLast().reduce(hostReplySeed) { $0 ^ $1 }
    }

    public static func parseReply(_ bytes: [UInt8], code: UInt8) -> DdcReadResult {
        guard bytes.count >= replyLength else { return .malformed }
        let b = Array(bytes.prefix(replyLength))
        guard b[2] == opcodeReply else { return .malformed }
        guard replyChecksum(b) == b[replyLength - 1] else { return .checksumMismatch }
        guard b[4] == code else { return .wrongCode }
        if b[3] != 0 { return .unsupported }
        let maximum = UInt16(b[6]) << 8 | UInt16(b[7])
        let current = UInt16(b[8]) << 8 | UInt16(b[9])
        return .value(current: current, maximum: maximum)
    }

    public static func makeReply(code: UInt8, current: UInt16, maximum: UInt16, resultCode: UInt8 = 0) -> [UInt8] {
        var b: [UInt8] = [0x6E, 0x88, opcodeReply, resultCode, code, 0x00, UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
        b.append(b.reduce(hostReplySeed) { $0 ^ $1 })
        return b
    }
}

public enum DdcScale {
    public static func sanitizedMaximum(_ maximum: UInt16) -> UInt16 { maximum > 0 ? maximum : 100 }

    public static func normalized(current: UInt16, maximum: UInt16) -> Double {
        let m = Double(sanitizedMaximum(maximum))
        return min(max(Double(current) / m, 0), 1)
    }

    public static func deviceValue(for normalized: Double, maximum: UInt16) -> UInt16 {
        guard normalized.isFinite else { return 0 }
        let m = Double(sanitizedMaximum(maximum))
        return UInt16((min(max(normalized, 0), 1) * m).rounded())
    }

    public static func channelOutcome(writeAccepted: Bool, replyParsed: Bool) -> DdcChannelOutcome {
        if replyParsed { return .live }
        return writeAccepted ? .writeOnly : .dead
    }
}

public struct DdcTiming: Equatable, Sendable {
    public var writePause: UInt32
    public var readPause: UInt32
    public var retryPause: UInt32
    public var writeCycles: Int
    public var retries: Int
    public var commandInterval: UInt64

    public init(writePause: UInt32, readPause: UInt32, retryPause: UInt32, writeCycles: Int, retries: Int, commandInterval: UInt64) {
        self.writePause = writePause
        self.readPause = readPause
        self.retryPause = retryPause
        self.writeCycles = writeCycles
        self.retries = retries
        self.commandInterval = commandInterval
    }

    public static let standard = DdcTiming(writePause: 10_000, readPause: 50_000, retryPause: 20_000, writeCycles: 2, retries: 4, commandInterval: 50_000)
    public static let none = DdcTiming(writePause: 0, readPause: 0, retryPause: 0, writeCycles: 1, retries: 2, commandInterval: 0)

    public func commandDelay(now: UInt64, lastEnd: UInt64?) -> UInt32 {
        guard let last = lastEnd, last <= now else { return 0 }
        let elapsed = now - last
        guard elapsed < commandInterval else { return 0 }
        return UInt32(commandInterval - elapsed)
    }
}

public protocol DdcTransport: AnyObject {
    func write(_ bytes: [UInt8]) -> Bool
    func read(length: Int) -> [UInt8]?
}

public final class DdcClient {
    private let transport: DdcTransport
    public let timing: DdcTiming
    private let sleep: (UInt32) -> Void
    private let clock: () -> UInt64
    private var lastEnd: UInt64?

    public init(transport: DdcTransport, timing: DdcTiming = .standard, sleep: @escaping (UInt32) -> Void = { usleep($0) },
                clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1000 }) {
        self.transport = transport
        self.timing = timing
        self.sleep = sleep
        self.clock = clock
    }

    private func gate() {
        let d = timing.commandDelay(now: clock(), lastEnd: lastEnd)
        if d > 0 { sleep(d) }
    }

    private func finish() { lastEnd = clock() }

    public func read(_ code: UInt8) -> (result: DdcReadResult, writeAccepted: Bool) {
        gate()
        defer { finish() }
        let request = DdcPacket.getVcp(code)
        var accepted = false
        var last = DdcReadResult.malformed
        for attempt in 0...timing.retries {
            if attempt > 0 { sleep(timing.retryPause) }
            sleep(timing.writePause)
            if transport.write(request) { accepted = true } else { continue }
            sleep(timing.readPause)
            guard let reply = transport.read(length: DdcPacket.replyLength) else { continue }
            last = DdcPacket.parseReply(reply, code: code)
            if case .value = last { return (last, accepted) }
            if last == .unsupported { return (last, accepted) }
        }
        return (last, accepted)
    }

    @discardableResult
    public func write(_ code: UInt8, value: UInt16) -> Bool {
        gate()
        defer { finish() }
        let packet = DdcPacket.setVcp(code, value: value)
        var ok = false
        for attempt in 0...timing.retries {
            if attempt > 0 { sleep(timing.retryPause) }
            var accepted = false
            for _ in 0..<max(timing.writeCycles, 1) {
                sleep(timing.writePause)
                if transport.write(packet) { accepted = true }
            }
            if accepted { ok = true; break }
        }
        return ok
    }

    public func probe(_ code: UInt8 = VcpCode.brightness) -> (outcome: DdcChannelOutcome, current: UInt16?, maximum: UInt16?) {
        let r = read(code)
        if case .value(let c, let m) = r.result { return (.live, c, m) }
        return (DdcScale.channelOutcome(writeAccepted: r.writeAccepted, replyParsed: false), nil, nil)
    }
}
