import Testing
import Foundation
@testable import MultitulCtlCore

@Suite struct SmcKeyNameTests {
    @Test func fourCharCodesRoundTrip() {
        #expect(SmcKeyName.fourCC("#KEY") == 0x234B4559)
        #expect(SmcKeyName.fourCC("FS! ") == 0x46532120)
        #expect(SmcKeyName.string(0x46304163) == "F0Ac")
        #expect(SmcKeyName.string(SmcKeyName.fourCC("Tp01")!) == "Tp01")
    }

    @Test func invalidNamesAreRejected() {
        for bad in ["", "ABC", "ABCDE", "Ф0Ac", "F0\nA", "F0\u{7f}A"] {
            #expect(!SmcKeyName.isValid(bad), "\(bad)")
            #expect(SmcKeyName.fourCC(bad) == nil)
        }
    }

    @Test func fanKeysAreBuiltFromIndex() {
        #expect(SmcKeyName.fan(0, "Ac") == "F0Ac")
        #expect(SmcKeyName.fan(9, "Tg") == "F9Tg")
        #expect(SmcKeyName.isValid(SmcKeyName.fan(9, "Md")))
    }
}

@Suite struct SmcCodecTests {
    @Test func fpe2RoundTrip() {
        #expect(SmcCodec.encode(2000, type: "fpe2", size: 2) == [0x1F, 0x40])
        #expect(SmcCodec.decode([0x1F, 0x40], type: "fpe2") == 2000)
        #expect(SmcCodec.encode(1234.5, type: "fpe2", size: 2) == [0x13, 0x4A])
        #expect(SmcCodec.decode([0x13, 0x4A], type: "fpe2") == 1234.5)
    }

    @Test func fpe2RoundsToQuarters() {
        #expect(SmcCodec.decode(SmcCodec.encode(1000.1, type: "fpe2", size: 2)!, type: "fpe2") == 1000.0)
        #expect(SmcCodec.decode(SmcCodec.encode(1000.2, type: "fpe2", size: 2)!, type: "fpe2") == 1000.25)
    }

    @Test func fpe2RejectsOutOfRange() {
        #expect(SmcCodec.encode(16384, type: "fpe2", size: 2) == nil)
        #expect(SmcCodec.encode(-1, type: "fpe2", size: 2) == nil)
        #expect(SmcCodec.encode(16383.75, type: "fpe2", size: 2) == [0xFF, 0xFF])
    }

    @Test func sp78RoundTrip() {
        #expect(SmcCodec.encode(26.25, type: "sp78", size: 2) == [0x1A, 0x40])
        #expect(SmcCodec.decode([0x1A, 0x40], type: "sp78") == 26.25)
        #expect(SmcCodec.encode(-1, type: "sp78", size: 2) == [0xFF, 0x00])
        #expect(SmcCodec.decode([0xFF, 0x00], type: "sp78") == -1)
        #expect(SmcCodec.encode(200, type: "sp78", size: 2) == nil)
    }

    @Test func floatIsLittleEndian() {
        #expect(SmcCodec.encode(50, type: "flt ", size: 4) == [0x00, 0x00, 0x48, 0x42])
        #expect(SmcCodec.decode([0x00, 0x00, 0x48, 0x42], type: "flt") == 50)
        #expect(SmcCodec.encode(-10, type: "flt", size: 4) == [0x00, 0x00, 0x20, 0xC1])
        #expect(SmcCodec.decode([0, 0, 0xC0, 0x7F], type: "flt") == nil)
    }

    @Test func floatRoundTripKeepsRpm() {
        for v in [0.0, 1200, 2317.5, 6550] {
            #expect(SmcCodec.decode(SmcCodec.encode(v, type: "flt", size: 4)!, type: "flt") == v)
        }
    }

    @Test func unsignedIntegers() {
        #expect(SmcCodec.encode(1, type: "ui8", size: 1) == [1])
        #expect(SmcCodec.encode(255, type: "ui8", size: 1) == [255])
        #expect(SmcCodec.encode(256, type: "ui8", size: 1) == nil)
        #expect(SmcCodec.encode(-1, type: "ui8", size: 1) == nil)
        #expect(SmcCodec.encode(258, type: "ui16", size: 2) == [1, 2])
        #expect(SmcCodec.decode([1, 2], type: "ui16") == 258)
        #expect(SmcCodec.encode(256, type: "ui32", size: 4) == [0, 0, 1, 0])
        #expect(SmcCodec.decode([0, 0, 1, 0], type: "ui32") == 256)
        #expect(SmcCodec.encode(65536, type: "ui16", size: 2) == nil)
    }

    @Test func signedIntegers() {
        #expect(SmcCodec.encode(-1, type: "si8", size: 1) == [0xFF])
        #expect(SmcCodec.decode([0xFF], type: "si8") == -1)
        #expect(SmcCodec.encode(-2, type: "si16", size: 2) == [0xFF, 0xFE])
        #expect(SmcCodec.decode([0xFF, 0xFE], type: "si16") == -2)
        #expect(SmcCodec.encode(128, type: "si8", size: 1) == nil)
    }

    @Test func ioftIsLittleEndianFixedPoint() {
        #expect(SmcCodec.encode(1, type: "ioft", size: 8) == [0, 0, 1, 0, 0, 0, 0, 0])
        #expect(SmcCodec.decode([0, 0, 1, 0, 0, 0, 0, 0], type: "ioft") == 1)
        #expect(SmcCodec.decode(SmcCodec.encode(12.5, type: "ioft", size: 8)!, type: "ioft") == 12.5)
        #expect(SmcCodec.encode(-1, type: "ioft", size: 8) == nil)
    }

    @Test func sizeMismatchAndUnknownTypesAreRejected() {
        #expect(SmcCodec.encode(1, type: "flt", size: 2) == nil)
        #expect(SmcCodec.encode(1, type: "fpe2", size: 4) == nil)
        #expect(SmcCodec.encode(1, type: "ui8", size: 2) == nil)
        #expect(SmcCodec.encode(1, type: "????", size: 2) == nil)
        #expect(SmcCodec.decode([1, 2, 3], type: "ui16") == nil)
        #expect(SmcCodec.decode([1, 2], type: "xx88") == nil)
    }

    @Test func nonFiniteValuesAreRejected() {
        for t in [("flt", 4), ("fpe2", 2), ("ui8", 1), ("ioft", 8)] {
            #expect(SmcCodec.encode(.nan, type: t.0, size: t.1) == nil)
            #expect(SmcCodec.encode(.infinity, type: t.0, size: t.1) == nil)
        }
    }

    @Test func typeNamesIgnoreTrailingPadding() {
        #expect(SmcCodec.normalizedType("flt ") == "flt")
        #expect(SmcCodec.normalizedType("ui8 ") == "ui8")
        #expect(SmcCodec.decode([7], type: "ui8 ") == 7)
    }

    @Test func wireStructMatchesAppleSmcAbi() {
        #expect(SmcWireLayout.size == 80 && SmcWireLayout.stride == 80)
        #expect(SmcWireLayout.infoSizeOffset == 28)
        #expect(SmcWireLayout.resultOffset == 40)
        #expect(SmcWireLayout.data8Offset == 42)
        #expect(SmcWireLayout.data32Offset == 44)
        #expect(SmcWireLayout.bytesOffset == 48)
    }
}
