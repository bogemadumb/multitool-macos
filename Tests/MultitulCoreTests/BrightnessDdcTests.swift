import Testing
import Foundation
@testable import MultitulCore

private final class DdcFakeTransport: DdcTransport {
    var writes: [[UInt8]] = []
    var acceptWrites = true
    var replies: [[UInt8]?] = []
    var reads = 0

    func write(_ bytes: [UInt8]) -> Bool {
        writes.append(bytes)
        return acceptWrites
    }

    func read(length: Int) -> [UInt8]? {
        defer { reads += 1 }
        guard reads < replies.count else { return nil }
        return replies[reads]
    }
}

@Suite struct DdcPacketTests {
    @Test func setVcpBytes() {
        #expect(DdcPacket.setVcp(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    @Test func getVcpBytes() {
        #expect(DdcPacket.getVcp(0x10) == [0x82, 0x01, 0x10, 0xFD])
    }

    @Test func valueIsBigEndian() {
        let p = DdcPacket.setVcp(0x12, value: 0x0164)
        #expect(Array(p[3...4]) == [0x01, 0x64])
    }

    @Test func getRequestChecksumOmitsSubAddress() {
        let p = DdcPacket.getVcp(0x10)
        #expect(p.last == UInt8(0x6E) ^ 0x82 ^ 0x01 ^ 0x10)
    }

    @Test func setChecksumIncludesSubAddress() {
        let p = DdcPacket.setVcp(0x10, value: 1)
        #expect(p.last == UInt8(0x6E) ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x01)
    }

    @Test func parsesGoodReply() {
        let r = DdcPacket.makeReply(code: 0x10, current: 37, maximum: 100)
        #expect(r.count == DdcPacket.replyLength)
        #expect(DdcPacket.parseReply(r, code: 0x10) == .value(current: 37, maximum: 100))
    }

    @Test func parsesSixteenBitValues() {
        let r = DdcPacket.makeReply(code: 0x10, current: 0x0201, maximum: 0x03E8)
        #expect(DdcPacket.parseReply(r, code: 0x10) == .value(current: 0x0201, maximum: 0x03E8))
    }

    @Test func rejectsReplyForOtherCode() {
        let r = DdcPacket.makeReply(code: 0x12, current: 5, maximum: 100)
        #expect(DdcPacket.parseReply(r, code: 0x10) == .wrongCode)
    }

    @Test func rejectsBadChecksum() {
        var r = DdcPacket.makeReply(code: 0x10, current: 5, maximum: 100)
        r[10] ^= 0xFF
        #expect(DdcPacket.parseReply(r, code: 0x10) == .checksumMismatch)
    }

    @Test func rejectsShortAndWrongOpcode() {
        #expect(DdcPacket.parseReply([1, 2, 3], code: 0x10) == .malformed)
        var r = DdcPacket.makeReply(code: 0x10, current: 5, maximum: 100)
        r[2] = 0x07
        #expect(DdcPacket.parseReply(r, code: 0x10) == .malformed)
    }

    @Test func unsupportedResultCode() {
        let r = DdcPacket.makeReply(code: 0xD6, current: 0, maximum: 0, resultCode: 1)
        #expect(DdcPacket.parseReply(r, code: 0xD6) == .unsupported)
    }
}

@Suite struct DdcScaleTests {
    @Test func normalizeAndBack() {
        #expect(DdcScale.normalized(current: 25, maximum: 100) == 0.25)
        #expect(DdcScale.deviceValue(for: 0.25, maximum: 100) == 25)
        #expect(DdcScale.deviceValue(for: 0.5, maximum: 255) == 128)
    }

    @Test func zeroMaximumMeansHundred() {
        #expect(DdcScale.sanitizedMaximum(0) == 100)
        #expect(DdcScale.normalized(current: 50, maximum: 0) == 0.5)
    }

    @Test func clampsOutOfRange() {
        #expect(DdcScale.deviceValue(for: 2, maximum: 100) == 100)
        #expect(DdcScale.deviceValue(for: -1, maximum: 100) == 0)
        #expect(DdcScale.deviceValue(for: .nan, maximum: 100) == 0)
        #expect(DdcScale.normalized(current: 300, maximum: 100) == 1)
    }

    @Test func channelOutcomes() {
        #expect(DdcScale.channelOutcome(writeAccepted: true, replyParsed: true) == .live)
        #expect(DdcScale.channelOutcome(writeAccepted: true, replyParsed: false) == .writeOnly)
        #expect(DdcScale.channelOutcome(writeAccepted: false, replyParsed: false) == .dead)
    }

    @Test func commandDelayHonoursInterval() {
        let t = DdcTiming.standard
        #expect(t.commandDelay(now: 1_000, lastEnd: nil) == 0)
        #expect(t.commandDelay(now: 1_000, lastEnd: 990) == 50_000 - 10)
        #expect(t.commandDelay(now: 100_000, lastEnd: 1_000) == 0)
        #expect(t.commandDelay(now: 10, lastEnd: 500) == 0)
    }
}

@Suite struct DdcClientTests {
    private func client(_ t: DdcFakeTransport, timing: DdcTiming = .none) -> DdcClient {
        DdcClient(transport: t, timing: timing, sleep: { _ in }, clock: { 0 })
    }

    @Test func readsOnFirstAttempt() {
        let t = DdcFakeTransport()
        t.replies = [DdcPacket.makeReply(code: 0x10, current: 70, maximum: 100)]
        let r = client(t).read(0x10)
        #expect(r.result == .value(current: 70, maximum: 100))
        #expect(r.writeAccepted)
        #expect(t.writes == [DdcPacket.getVcp(0x10)])
    }

    @Test func retriesAfterMissingReply() {
        let t = DdcFakeTransport()
        t.replies = [nil, DdcPacket.makeReply(code: 0x10, current: 10, maximum: 100)]
        let r = client(t).read(0x10)
        #expect(r.result == .value(current: 10, maximum: 100))
        #expect(t.writes.count == 2)
    }

    @Test func skipsStaleReplyForAnotherCode() {
        let t = DdcFakeTransport()
        t.replies = [DdcPacket.makeReply(code: 0x12, current: 1, maximum: 100), DdcPacket.makeReply(code: 0x10, current: 80, maximum: 100)]
        #expect(client(t).read(0x10).result == .value(current: 80, maximum: 100))
    }

    @Test func probeDeadWhenWritesRejected() {
        let t = DdcFakeTransport()
        t.acceptWrites = false
        #expect(client(t).probe().outcome == .dead)
    }

    @Test func probeWriteOnlyWhenNoReplies() {
        let t = DdcFakeTransport()
        #expect(client(t).probe().outcome == .writeOnly)
    }

    @Test func probeLiveCarriesValues() {
        let t = DdcFakeTransport()
        t.replies = [DdcPacket.makeReply(code: 0x10, current: 40, maximum: 90)]
        let p = client(t).probe()
        #expect(p.outcome == .live)
        #expect(p.current == 40)
        #expect(p.maximum == 90)
    }

    @Test func unsupportedStopsRetrying() {
        let t = DdcFakeTransport()
        t.replies = [DdcPacket.makeReply(code: 0xD6, current: 0, maximum: 0, resultCode: 1)]
        #expect(client(t).read(0xD6).result == .unsupported)
        #expect(t.writes.count == 1)
    }

    @Test func writeSendsPacketTwiceWithStandardTiming() {
        let t = DdcFakeTransport()
        #expect(client(t, timing: .standard).write(0x10, value: 30))
        #expect(t.writes == [DdcPacket.setVcp(0x10, value: 30), DdcPacket.setVcp(0x10, value: 30)])
    }

    @Test func writeFailsAfterAllRetries() {
        let t = DdcFakeTransport()
        t.acceptWrites = false
        let timing = DdcTiming.none
        #expect(client(t, timing: timing).write(0x10, value: 30) == false)
        #expect(t.writes.count == timing.retries + 1)
    }

    @Test func commandsAreSpacedByInterval() {
        let t = DdcFakeTransport()
        var slept: [UInt32] = []
        var now: UInt64 = 1_000
        let c = DdcClient(transport: t, timing: DdcTiming(writePause: 0, readPause: 0, retryPause: 0, writeCycles: 1, retries: 0, commandInterval: 50_000),
                          sleep: { slept.append($0) }, clock: { now })
        _ = c.write(0x10, value: 1)
        now = 11_000
        _ = c.write(0x10, value: 2)
        #expect(slept.contains(40_000))
    }
}
