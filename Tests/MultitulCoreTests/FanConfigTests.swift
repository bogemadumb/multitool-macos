import Testing
import Foundation
@testable import MultitulCore

@Suite struct FanSettingsTests {
    @Test func defaultsAreSafe() {
        let c = FanConfig()
        #expect(c.mode == .auto && !c.resumeOnLaunch)
        #expect(c.curveUsable && c.hysteresis > 0 && c.rampUp > 0 && c.rampDown > 0)
        #expect(FanSettingsStore(WndMemoryStore()).load() == FanConfig())
    }

    @Test func roundTripKeepsEveryField() {
        let kv = WndMemoryStore()
        var c = FanConfig()
        c.mode = .curve
        c.manualRpm = 4100
        c.manualPercent = 77
        c.curve = [FanCurvePoint(temp: 45, percent: 10), FanCurvePoint(temp: 75, percent: 90)]
        c.source = .gpu
        c.aggregate = .average
        c.hysteresis = 5.5
        c.rampUp = 1200
        c.rampDown = 90
        c.resumeOnLaunch = true
        FanSettingsStore(kv).save(c)
        #expect(FanSettingsStore(kv).load() == c)
    }

    @Test func defaultsAreNotWrittenToTheStore() {
        let kv = WndMemoryStore()
        FanSettingsStore(kv).save(FanConfig())
        #expect(kv.values.isEmpty)
    }

    @Test func loadClampsDamagedValues() {
        let kv = WndMemoryStore()
        kv.values = ["fanControl.rpm": 99999, "fanControl.pct": -5, "fanControl.hyst": 400.0, "fanControl.up": -3, "fanControl.down": 99999,
                     "fanControl.mode": "turbo", "fanControl.source": 7]
        let c = FanSettingsStore(kv).load()
        #expect(c.manualRpm == 10000 && c.manualPercent == 0 && c.hysteresis == 15 && c.rampUp == 0 && c.rampDown == 5000)
        #expect(c.mode == .auto && c.source == .soc)
    }

    @Test func damagedCurveFallsBackToDefault() {
        let kv = WndMemoryStore()
        kv.values = ["fanControl.curve": [["t": 50.0], ["x": 1.0]]]
        #expect(FanSettingsStore(kv).load().curve == FanCurve.defaultPoints)
    }

    @Test func savedCurveIsNormalized() {
        let kv = WndMemoryStore()
        var c = FanConfig()
        c.curve = [FanCurvePoint(temp: 80, percent: 100), FanCurvePoint(temp: 40, percent: 0)]
        FanSettingsStore(kv).save(c)
        #expect(FanSettingsStore(kv).load().curve.first?.temp == 40)
    }

    @Test func keysAreAscii() {
        let kv = WndMemoryStore()
        var c = FanConfig()
        c.mode = .curve
        c.manualRpm = 3000
        c.resumeOnLaunch = true
        c.curve = [FanCurvePoint(temp: 50, percent: 50)]
        let store = FanSettingsStore(kv)
        store.save(c)
        store.dirty = true
        store.activePreset = "quiet"
        #expect(kv.values.keys.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } && $0.hasPrefix("fanControl.") })
    }

    @Test func dirtyFlagPersistsAndClears() {
        let kv = WndMemoryStore()
        let s = FanSettingsStore(kv)
        #expect(!s.dirty)
        s.dirty = true
        #expect(FanSettingsStore(kv).dirty)
        s.dirty = false
        #expect(kv.values["fanControl.dirty"] == nil)
    }
}

@Suite struct FanPresetTests {
    private func lib(_ kv: WndMemoryStore = WndMemoryStore()) -> FanPresetLibrary { FanPresetLibrary(store: FanSettingsStore(kv)) }

    @Test func builtInsAreFixedAndValid() {
        let b = FanPresets.builtIn
        #expect(b.map(\.id) == ["quiet", "balanced", "cool", "max"])
        #expect(b.allSatisfy { $0.builtIn && !$0.name.isEmpty && $0.config == $0.config.sanitized && FanPresets.isValidID($0.id) })
        #expect(b.last?.config.mode == .manualPercent && b.last?.config.manualPercent == 100)
    }

    @Test func quietIsNeverLouderThanCoolAtTheSameTemperature() {
        let quiet = FanPresets.builtIn[0].config.curve
        let cool = FanPresets.builtIn[2].config.curve
        for t in stride(from: 30.0, through: 100.0, by: 5) {
            #expect(FanCurve.percent(at: t, in: quiet)! <= FanCurve.percent(at: t, in: cool)!)
        }
    }

    @Test func savingCreatesAUserPresetAndPersistsIt() {
        let kv = WndMemoryStore()
        let l = lib(kv)
        var c = FanConfig()
        c.mode = .manualRpm
        c.manualRpm = 3300
        let p = l.save(name: "  Игры  ", config: c)
        #expect(p?.name == "Игры" && p?.id == "u1")
        let again = lib(kv)
        #expect(again.user.count == 1 && again.user[0].config.manualRpm == 3300 && again.user[0].config.mode == .manualRpm)
    }

    @Test func sameNameReplacesTheUserPreset() {
        let l = lib()
        var a = FanConfig(); a.manualRpm = 2000
        var b = FanConfig(); b.manualRpm = 4000
        l.save(name: "X", config: a)
        l.save(name: "X", config: b)
        #expect(l.user.count == 1 && l.user[0].config.manualRpm == 4000)
    }

    @Test func idsAreUniqueAfterDeletion() {
        let l = lib()
        l.save(name: "A", config: FanConfig())
        l.save(name: "B", config: FanConfig())
        l.delete("u1")
        let c = l.save(name: "C", config: FanConfig())
        #expect(c?.id == "u1")
        #expect(Set(l.all.map(\.id)).count == l.all.count)
    }

    @Test func builtInsCannotBeDeletedOrOverwritten() {
        let l = lib()
        #expect(!l.delete("quiet"))
        #expect(l.save(name: "Тихий", config: FanConfig()) == nil)
        #expect(l.all.count == 4)
    }

    @Test func emptyNameIsRejected() {
        #expect(lib().save(name: "   ", config: FanConfig()) == nil)
    }

    @Test func listIsCapped() {
        let l = lib()
        for i in 0..<(FanPresets.maxUser + 3) { l.save(name: "P\(i)", config: FanConfig()) }
        #expect(l.user.count == FanPresets.maxUser)
    }

    @Test func deleteRemovesFromStoreAndClearsActive() {
        let kv = WndMemoryStore()
        let l = lib(kv)
        l.save(name: "A", config: FanConfig())
        FanSettingsStore(kv).activePreset = "u1"
        #expect(l.delete("u1"))
        #expect(kv.values["fanControl.presets"] == nil && kv.values["fanControl.preset"] == nil)
    }

    @Test func renameKeepsConfigAndRejectsDuplicates() {
        let l = lib()
        var c = FanConfig(); c.manualPercent = 61
        l.save(name: "A", config: c)
        l.save(name: "B", config: FanConfig())
        #expect(l.rename("u1", to: "Новое"))
        #expect(!l.rename("u1", to: "B"))
        #expect(!l.rename("quiet", to: "Z"))
        #expect(l.preset("u1")?.name == "Новое" && l.preset("u1")?.config.manualPercent == 61)
    }

    @Test func applyingAPresetKeepsLaunchResumeChoice() {
        let l = lib()
        var cur = FanConfig(); cur.resumeOnLaunch = true
        let applied = l.config(applying: "balanced", to: cur)
        #expect(applied?.mode == .curve && applied?.resumeOnLaunch == true)
        #expect(l.config(applying: "nope", to: cur) == nil)
    }

    @Test func savedPresetNeverCarriesResume() {
        let l = lib()
        var c = FanConfig(); c.resumeOnLaunch = true
        #expect(l.save(name: "R", config: c)?.config.resumeOnLaunch == false)
    }

    @Test func damagedStoredPresetsAreSkipped() {
        let kv = WndMemoryStore()
        kv.values["fanControl.presets"] = [
            ["id": "ok1", "name": "Нормальный", "cfg": ["mode": "curve"]],
            ["id": "Bad ID", "name": "x", "cfg": [:]],
            ["id": "quiet", "name": "дубль встроенного", "cfg": [:]],
            ["id": "ok2", "name": "  ", "cfg": [:]],
            ["id": "ok3", "cfg": [:]]
        ] as [[String: Any]]
        let l = lib(kv)
        #expect(l.user.map(\.id) == ["ok1"])
    }

    @Test func idValidation() {
        #expect(FanPresets.isValidID("u12") && FanPresets.isValidID("quiet"))
        for bad in ["", "U1", "u 1", "ю1", "u-1", String(repeating: "a", count: 25)] { #expect(!FanPresets.isValidID(bad), "\(bad)") }
    }
}
