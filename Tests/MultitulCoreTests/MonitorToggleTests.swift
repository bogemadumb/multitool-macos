import Testing
import Foundation
@testable import MultitulCore

private final class FakeDisplays: DisplayProviding {
    var list: [DisplayInfo]
    var canSwitch = true
    var canList = true
    var applied: [(ids: [UInt32], enabled: Bool)] = []
    var failWith: String?

    init(_ list: [DisplayInfo]) { self.list = list }

    func displays() -> [DisplayInfo] { list }
    func setEnabled(_ ids: [UInt32], enabled: Bool) -> DisplayApplyResult {
        applied.append((ids, enabled))
        if let f = failWith { return .failed(f) }
        return .ok
    }
}

private let builtin = DisplayInfo(id: 1, isOnline: true, isBuiltin: true, isMain: true, vendor: 1552, width: 1470, height: 956)
private let placeholder = DisplayInfo(id: 2, isOnline: false, isBuiltin: false, vendor: 0, width: 1, height: 1)
private let extOn = DisplayInfo(id: 5, isOnline: true, isBuiltin: false, isMain: false, vendor: 4268, width: 2560, height: 1440)
private let extOff = DisplayInfo(id: 5, isOnline: false, isBuiltin: false, isMain: false, vendor: 4268, width: 1, height: 1)
private let extMain = DisplayInfo(id: 5, isOnline: true, isBuiltin: false, isMain: true, vendor: 4268, width: 2560, height: 1440)

@Suite struct MonitorClassifyTests {
    @Test func classification() {
        #expect(MonitorLogic.classify(builtin) == .builtin)
        #expect(MonitorLogic.classify(DisplayInfo(id: 1, isOnline: false, isBuiltin: true, vendor: 1552)) == .builtin)
        #expect(MonitorLogic.classify(extOn) == .externalActive)
        #expect(MonitorLogic.classify(extOff) == .externalDisabled)
        #expect(MonitorLogic.classify(placeholder) == .placeholder)
        #expect(MonitorLogic.classify(DisplayInfo(id: 9, isOnline: true, vendor: 0)) == .externalActive)
    }

    @Test func placeholderIsNeverDisabledMonitor() {
        let all = [builtin, placeholder, extOn]
        #expect(MonitorLogic.disabledExternals(all).isEmpty)
        #expect(MonitorLogic.state(all) == .on)
        #expect(MonitorLogic.state([builtin, placeholder, extOff]) == .off)
        #expect(MonitorLogic.disabledExternals([builtin, placeholder, extOff]).map(\.id) == [5])
    }

    @Test func statusLinesMentionMainAndState() {
        let on = MonitorLogic.statusLines([builtin, extOn])
        #expect(on.contains { $0.contains("главный") })
        #expect(on.last == "Состояние: монитор ВКЛЮЧЁН")
        #expect(MonitorLogic.statusLines([builtin, extOff]).last == "Состояние: монитор ВЫКЛЮЧЕН")
        #expect(MonitorLogic.label(extOff) == "5 (внешний, vendor 4268)")
        #expect(MonitorLogic.label(extOn) == "5 (внешний, 2560x1440, vendor 4268)")
    }
}

@Suite struct MonitorDecisionTests {
    @Test func offTable() {
        #expect(MonitorLogic.plan(.off, displays: [builtin, extOn]) == .apply(ids: [5], enabled: false))
        #expect(MonitorLogic.plan(.off, displays: [builtin]) == .unchanged("нечего выключать"))
        #expect(MonitorLogic.plan(.off, displays: [builtin, extOff]) == .unchanged("нечего выключать"))
        if case .refuse = MonitorLogic.plan(.off, displays: [builtin, extMain]) {} else { Issue.record("main external must be refused") }
    }

    @Test func onTable() {
        #expect(MonitorLogic.plan(.on, displays: [builtin, extOff]) == .apply(ids: [5], enabled: true))
        #expect(MonitorLogic.plan(.on, displays: [builtin, extOn]) == .unchanged("нечего включать"))
        #expect(MonitorLogic.plan(.on, displays: [builtin, placeholder]) == .unchanged("нечего включать"))
    }

    @Test func toggleTable() {
        #expect(MonitorLogic.plan(.toggle, displays: [builtin, extOn]) == .apply(ids: [5], enabled: false))
        #expect(MonitorLogic.plan(.toggle, displays: [builtin, extOff]) == .apply(ids: [5], enabled: true))
        #expect(MonitorLogic.plan(.toggle, displays: [builtin]) == .unchanged("нечего выключать"))
        if case .refuse = MonitorLogic.plan(.toggle, displays: [builtin, extMain]) {} else { Issue.record("toggle must refuse main external") }
    }

    @Test func protectedDisplayIsNeverSwitchedOff() {
        let virt = DisplayInfo(id: 7, isOnline: true, isBuiltin: false, vendor: 99, width: 1920, height: 1080)
        #expect(MonitorLogic.plan(.off, displays: [builtin, extOn, virt], protected: [7]) == .apply(ids: [5], enabled: false))
        #expect(MonitorLogic.plan(.off, displays: [builtin, virt], protected: [7]) == .unchanged("нечего выключать"))
    }

    @Test func serviceAppliesAndReports() {
        let fake = FakeDisplays([builtin, extOn])
        let svc = MonitorToggleService(provider: fake)
        #expect(svc.run(.off) == .changed("выключен дисплей 5"))
        #expect(fake.applied.count == 1 && fake.applied[0].ids == [5] && fake.applied[0].enabled == false)
        fake.list = [builtin, extOff]
        #expect(svc.run(.toggle) == .changed("включён дисплей 5"))
        #expect(fake.applied.last?.enabled == true)
        #expect(svc.run(.status) == .unchanged("Состояние: монитор ВЫКЛЮЧЕН"))
        #expect(fake.applied.count == 2)
    }

    @Test func serviceRefusesMainAndDoesNotTouchProvider() {
        let fake = FakeDisplays([builtin, extMain])
        let r = MonitorToggleService(provider: fake).run(.off)
        #expect(r.isFailure)
        #expect(fake.applied.isEmpty)
    }

    @Test func serviceGracefulWhenSymbolsMissing() {
        let fake = FakeDisplays([builtin, extOn])
        fake.canSwitch = false
        let r = MonitorToggleService(provider: fake).run(.off)
        #expect(r.isFailure && r.message.contains("недоступна"))
        #expect(fake.applied.isEmpty)
        fake.canSwitch = true
        fake.canList = false
        #expect(MonitorToggleService(provider: fake).run(.on).isFailure)
        #expect(MonitorToggleService(provider: fake).run(.toggle).isFailure)
        #expect(fake.applied.isEmpty)
    }

    @Test func serviceReportsProviderFailure() {
        let fake = FakeDisplays([builtin, extOn])
        fake.failWith = "дисплей 5: ошибка 1001"
        #expect(MonitorToggleService(provider: fake).run(.off) == .failed("дисплей 5: ошибка 1001"))
    }

    @Test func serviceHonoursProtectedProvider() {
        let fake = FakeDisplays([builtin, extOn])
        let svc = MonitorToggleService(provider: fake, protectedIDs: { [5] })
        #expect(svc.run(.off) == .unchanged("нечего выключать"))
        #expect(fake.applied.isEmpty)
    }

    @Test func cliParsing() {
        let fake = FakeDisplays([builtin, extOn])
        var out: [String] = [], err: [String] = []
        #expect(MonitorCLI.run(arguments: ["Multitul", "--monitor", "status"], provider: fake, out: { out.append($0) }, err: { err.append($0) }) == 0)
        #expect(out.last == "Состояние: монитор ВКЛЮЧЁН")
        #expect(MonitorCLI.run(arguments: ["Multitul", "--monitor", "bogus"], provider: fake, out: { out.append($0) }, err: { err.append($0) }) == 2)
        #expect(MonitorCLI.run(arguments: ["Multitul", "--monitor", "off"], provider: fake, out: { out.append($0) }, err: { err.append($0) }) == 0)
        #expect(fake.applied.count == 1)
    }

    @Test func hotkeyDefaultIsNone() {
        let spec = ModuleID.monitorToggle.info.hotkeys[0]
        #expect(spec.defaultCombo.isNone)
        #expect(spec.defaultCombo.display == "—")
        #expect(!KeyCombo(keyCode: 9, modifiers: KeyCombo.cmd).isNone)
    }

    @Test func realProviderResolvesWithoutSwitching() {
        let p = CGSDisplayProvider()
        _ = p.canSwitch
        _ = p.canList
    }
}
