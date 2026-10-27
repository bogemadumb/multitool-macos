import Testing
import Foundation
@testable import MultitulCore

@Suite struct ExtraBrightnessTests {
    @Test func xdrMacBookProIsAvailable() {
        let a = ExtraBrightnessLogic.availability(XdrScreenInfo(isBuiltin: true, potentialEDR: 16, modelIdentifier: "Mac15,7"))
        #expect(a == .available(maxGain: ExtraBrightnessLogic.gainCeiling))
    }

    @Test func airIsNotXdrEvenWithEdrReported() {
        let a = ExtraBrightnessLogic.availability(XdrScreenInfo(isBuiltin: true, potentialEDR: 2, modelIdentifier: "Mac14,15"))
        #expect(a == .unavailable(.nonXdrModel))
        #expect(ExtraBrightnessLogic.availability(XdrScreenInfo(isBuiltin: true, potentialEDR: 2, modelIdentifier: "MacBookAir10,1")) == .unavailable(.nonXdrModel))
    }

    @Test func externalScreenIsRejected() {
        #expect(ExtraBrightnessLogic.availability(XdrScreenInfo(isBuiltin: false, potentialEDR: 16, modelIdentifier: "Mac15,7")) == .unavailable(.notBuiltin))
    }

    @Test func lowHeadroomIsRejected() {
        #expect(ExtraBrightnessLogic.availability(XdrScreenInfo(isBuiltin: true, potentialEDR: 1, modelIdentifier: "Mac15,7")) == .unavailable(.noHeadroom))
        #expect(ExtraBrightnessLogic.availability(XdrScreenInfo(isBuiltin: true, potentialEDR: .nan, modelIdentifier: "Mac15,7")) == .unavailable(.noHeadroom))
    }

    @Test func smallPotentialKeepsItsOwnCeiling() {
        let a = ExtraBrightnessLogic.availability(XdrScreenInfo(isBuiltin: true, potentialEDR: 1.5, modelIdentifier: "Mac15,7"))
        #expect(a == .available(maxGain: 1.5))
        #expect(a.isAvailable)
    }

    @Test func unavailableTextsAreRussian() {
        for r in [XdrUnavailableReason.notBuiltin, .noHeadroom, .nonXdrModel] { #expect(r.text.hasPrefix("недоступно на этом экране")) }
    }

    @Test func gainScalesWithLevel() {
        #expect(ExtraBrightnessLogic.gain(level: 0, maxGain: 1.6) == 1)
        #expect(ExtraBrightnessLogic.gain(level: 1, maxGain: 1.6) == 1.6)
        #expect(abs(ExtraBrightnessLogic.gain(level: 0.5, maxGain: 1.6) - 1.3) < 1e-12)
        #expect(ExtraBrightnessLogic.gain(level: 9, maxGain: 1.6) == 1.6)
        #expect(ExtraBrightnessLogic.gain(level: 1, maxGain: 0.5) == 1)
    }

    @Test func effectiveFactorFollowsGrantedHeadroom() {
        #expect(ExtraBrightnessLogic.effectiveFactor(target: 1.5, currentEDR: 1.2) == 1.2)
        #expect(ExtraBrightnessLogic.effectiveFactor(target: 1.5, currentEDR: 4) == 1.5)
        #expect(ExtraBrightnessLogic.effectiveFactor(target: 1.5, currentEDR: 1) == 1)
        #expect(ExtraBrightnessLogic.effectiveFactor(target: .nan, currentEDR: 2) == 1)
    }

    @Test func rampMovesInSmallSteps() {
        #expect(ExtraBrightnessLogic.ramp(current: 1, target: 1.5, step: 0.1) == 1.1)
        #expect(ExtraBrightnessLogic.ramp(current: 1.5, target: 1, step: 0.1) == 1.4)
        #expect(ExtraBrightnessLogic.ramp(current: 1.45, target: 1.5, step: 0.1) == 1.5)
    }

    @Test func batteryPolicy() {
        func boost(_ e: Bool, _ a: Bool, _ b: Bool, _ auto: Bool, _ lp: Bool) -> Bool {
            ExtraBrightnessLogic.shouldBoost(enabled: e, available: a, onBattery: b, autoOffOnBattery: auto, lowPower: lp)
        }
        #expect(boost(true, true, false, true, false))
        #expect(!boost(true, true, true, true, false))
        #expect(!boost(true, true, false, true, true))
        #expect(boost(true, true, true, false, false))
        #expect(!boost(false, true, false, true, false))
        #expect(!boost(true, false, false, true, false))
    }

    @Test func knownNonXdrModels() {
        #expect(ExtraBrightnessLogic.isKnownNonXdr(modelIdentifier: "Macmini9,1"))
        #expect(!ExtraBrightnessLogic.isKnownNonXdr(modelIdentifier: "MacBookPro18,2"))
    }

    @Test func settingsRoundTrip() {
        let d = InMemoryKeyValueStore()
        var s = ExtraBrightnessSettings()
        s.level = 0.8
        s.autoOffOnBattery = false
        s.save(to: d)
        #expect(ExtraBrightnessSettings.load(d) == s)
        ExtraBrightnessSettings().save(to: d)
        #expect(d.object(forKey: "extraBrightness.level") == nil)
        #expect(ExtraBrightnessSettings.load(d) == ExtraBrightnessSettings())
    }
}
