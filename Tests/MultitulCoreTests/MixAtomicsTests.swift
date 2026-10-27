import Testing
import Foundation
@testable import MultitulCore

@Suite struct MixAtomicsTests {
    @Test func u32StoreLoadExchange() {
        let a = MixAtomicU32(5)
        #expect(a.load() == 5)
        a.store(9)
        #expect(a.load() == 9)
        #expect(a.exchange(2) == 9)
        #expect(a.load() == 2)
    }

    @Test func u32AddReturnsPreviousAndWraps() {
        let a = MixAtomicU32(UInt32.max)
        #expect(a.add(1) == UInt32.max)
        #expect(a.load() == 0)
    }

    @Test func u32CompareExchange() {
        let a = MixAtomicU32(3)
        #expect(!a.compareExchange(expected: 4, desired: 8))
        #expect(a.load() == 3)
        #expect(a.compareExchange(expected: 3, desired: 8))
        #expect(a.load() == 8)
    }

    @Test func floatRoundTrip() {
        let f = MixAtomicFloat(0.25)
        #expect(f.load() == 0.25)
        f.store(-3.5)
        #expect(f.load() == -3.5)
        f.store(0)
        #expect(f.load() == 0)
    }

    @Test func floatArrayStoresPerSlot() {
        let a = MixAtomicFloatArray(count: 4)
        a.store(0.5, at: 2)
        a.store(1, at: 3)
        #expect(a.snapshot() == [0, 0, 0.5, 1])
        #expect(a.count == 4)
    }

    @Test func tripleBufferStartsWithInitial() {
        let t = MixTripleBuffer(initial: 7)
        #expect(t.read() == 7)
        #expect(!t.hasPending)
    }

    @Test func tripleBufferDeliversPublishedValue() {
        let t = MixTripleBuffer(initial: 0)
        t.publish(11)
        #expect(t.hasPending)
        #expect(t.read() == 11)
        #expect(!t.hasPending)
        #expect(t.read() == 11)
    }

    @Test func tripleBufferKeepsOnlyTheLatest() {
        let t = MixTripleBuffer(initial: 0)
        for v in 1...10 { t.publish(v) }
        #expect(t.read() == 10)
        t.publish(20)
        t.publish(21)
        #expect(t.read() == 21)
    }

    @Test func tripleBufferCarriesStructs() {
        let t = MixTripleBuffer(initial: MixParams())
        t.publish(MixParams(volume: 2.5, muted: true, ceiling: 0.5, bandsOn: true))
        #expect(t.read() == MixParams(volume: 2.5, muted: true, ceiling: 0.5, bandsOn: true))
    }

    private struct Triple { var a: UInt64; var b: UInt64; var c: UInt64 }

    @Test func tripleBufferNeverTearsAcrossThreads() {
        let t = MixTripleBuffer(initial: Triple(a: 0, b: 1, c: ~0))
        let total: UInt64 = 200_000
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for i in 1...total { t.publish(Triple(a: i, b: i &* 3 &+ 1, c: ~i)) }
            done.signal()
        }
        var last: UInt64 = 0
        var torn = 0
        var backwards = 0
        var finished = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let v = t.read()
            if v.b != v.a &* 3 &+ 1 || v.c != ~v.a { torn += 1 }
            if v.a < last { backwards += 1 }
            last = v.a
            if v.a == total { finished = true; break }
        }
        done.wait()
        let final = t.read()
        #expect(torn == 0 && backwards == 0)
        #expect(finished || final.a == total)
    }
}
