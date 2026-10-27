import Foundation
import CMixAtomics

public final class MixAtomicU32: @unchecked Sendable {
    private let p: UnsafeMutablePointer<UInt32>

    public init(_ value: UInt32 = 0) {
        p = .allocate(capacity: 1)
        p.initialize(to: value)
    }

    deinit { p.deallocate() }

    public func load() -> UInt32 { mix_load_u32(p) }
    public func store(_ v: UInt32) { mix_store_u32(p, v) }
    public func exchange(_ v: UInt32) -> UInt32 { mix_exchange_u32(p, v) }
    @discardableResult public func add(_ v: UInt32) -> UInt32 { mix_fetch_add_u32(p, v) }
    public func compareExchange(expected: UInt32, desired: UInt32) -> Bool { mix_compare_exchange_u32(p, expected, desired) != 0 }
}

public final class MixAtomicFloat: @unchecked Sendable {
    private let cell: MixAtomicU32

    public init(_ value: Float = 0) { cell = MixAtomicU32(value.bitPattern) }

    public func load() -> Float { Float(bitPattern: cell.load()) }
    public func store(_ v: Float) { cell.store(v.bitPattern) }
}

public final class MixAtomicFloatArray: @unchecked Sendable {
    public let count: Int
    private let p: UnsafeMutablePointer<UInt32>

    public init(count: Int) {
        self.count = count
        p = .allocate(capacity: max(count, 1))
        p.initialize(repeating: 0, count: max(count, 1))
    }

    deinit { p.deallocate() }

    public func store(_ v: Float, at i: Int) { mix_store_u32(p + i, v.bitPattern) }
    public func load(at i: Int) -> Float { Float(bitPattern: mix_load_u32(p + i)) }
    public func snapshot() -> [Float] { (0..<count).map { load(at: $0) } }
}

// Single writer, single reader. T must be plain data (no references), so a read never allocates or retains.
public final class MixTripleBuffer<T>: @unchecked Sendable {
    private let slots: UnsafeMutablePointer<T>
    private let middle: MixAtomicU32
    private var back = 0
    private var front = 1
    private static var dirtyBit: UInt32 { 4 }

    public init(initial: T) {
        slots = .allocate(capacity: 3)
        slots.initialize(repeating: initial, count: 3)
        middle = MixAtomicU32(2)
    }

    deinit {
        slots.deinitialize(count: 3)
        slots.deallocate()
    }

    public func publish(_ value: T) {
        slots[back] = value
        let old = middle.exchange(UInt32(back) | Self.dirtyBit)
        back = Int(old & 3)
    }

    public var hasPending: Bool { middle.load() & Self.dirtyBit != 0 }

    public func read() -> T {
        if middle.load() & Self.dirtyBit != 0 {
            let old = middle.exchange(UInt32(front))
            front = Int(old & 3)
        }
        return slots[front]
    }
}

@inline(__always) func mixLoop(_ n: Int, _ body: (Int) -> Void) {
    var i = 0
    while i < n {
        body(i)
        i += 1
    }
}
