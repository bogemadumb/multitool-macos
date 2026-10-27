import Testing
import Foundation
@testable import MultitulCore

private func allGranted(_ p: Permission) -> PermissionStatus { .granted }
private func denied(_ p: Permission) -> PermissionStatus { p == .fullDiskAccess ? .denied : .granted }

@Suite struct ModuleListTests {
    @Test func allFilterKeepsEveryModuleWhenNoQuery() {
        let secs = ModuleList.sections(query: "", filter: .all, isEnabled: { _ in false }, status: allGranted)
        #expect(secs.flatMap(\.modules).count == ModuleID.allCases.count)
        #expect(secs.map(\.group) == ModuleGroup.allCases.filter { g in ModuleID.allCases.contains { $0.info.group == g } })
    }

    @Test func enabledFilter() {
        let on: Set<ModuleID> = [.vpn, .screenshot]
        let secs = ModuleList.sections(query: "", filter: .enabled, isEnabled: { on.contains($0) }, status: allGranted)
        #expect(Set(secs.flatMap(\.modules).map(\.id)) == on)
    }

    @Test func needsPermissionsOnlyCountsEnabledModulesWithMissingRights() {
        let on: Set<ModuleID> = [.diskClean, .vpn]
        let secs = ModuleList.sections(query: "", filter: .needsPermissions, isEnabled: { on.contains($0) }, status: denied)
        #expect(secs.flatMap(\.modules).map(\.id) == [.diskClean])
        let none = ModuleList.sections(query: "", filter: .needsPermissions, isEnabled: { _ in false }, status: denied)
        #expect(none.isEmpty)
    }

    @Test func unknownStatusIsNotMissing() {
        let info = ModuleID.vpn.info
        #expect(ModuleList.missingPermissions(info, status: { _ in .unknown }).isEmpty)
        #expect(ModuleList.missingPermissions(info, status: { _ in .undetermined }).count == info.permissions.count)
    }

    @Test func searchByTitleSummaryAndPermission() {
        func ids(_ q: String) -> [ModuleID] {
            ModuleList.sections(query: q, filter: .all, isEnabled: { _ in true }, status: allGranted).flatMap(\.modules).map(\.id)
        }
        #expect(ids("keep awake").contains(.keepAwake))
        #expect(ids("ЯРКОСТЬ").contains(.brightness))
        #expect(ids("полный доступ").contains(.diskClean))
        #expect(ids("zzzzqqq").isEmpty)
    }

    @Test func searchCombinesWithFilter() {
        let on: Set<ModuleID> = [.brightness]
        let r = ModuleList.sections(query: "яркость", filter: .enabled, isEnabled: { on.contains($0) }, status: allGranted).flatMap(\.modules).map(\.id)
        #expect(r == [.brightness])
    }
}

@Suite struct PermissionPortalTests {
    @Test func usageListsModulesAndSplitsEnabled() {
        let u = PermissionPortal.usage(.fullDiskAccess, isEnabled: { $0 == .diskClean })
        #expect(u.all.contains(ModuleID.diskClean.info.title))
        #expect(u.enabled == [ModuleID.diskClean.info.title])
    }

    @Test func usagesCoverEveryPermissionOnceNeededFirst() {
        let u = PermissionPortal.usages(isEnabled: { $0 == .diskClean })
        #expect(u.count == Permission.allCases.count)
        #expect(Set(u.map(\.permission)) == Set(Permission.allCases))
        #expect(u.first?.enabled.isEmpty == false)
        let firstEmpty = u.firstIndex { $0.enabled.isEmpty } ?? u.count
        #expect(u[firstEmpty...].allSatisfy { $0.enabled.isEmpty })
    }

    @Test func summaryTruncatesAndHandlesEmpty() {
        let long = PermissionUsage(permission: .accessibility, all: ["A", "B", "C", "D", "E"], enabled: ["A", "B", "C", "D", "E"])
        #expect(PermissionPortal.summary(long) == "Нужно: A, B, C и ещё 2")
        let off = PermissionUsage(permission: .camera, all: ["Z"], enabled: [])
        #expect(PermissionPortal.summary(off) == "Нужно выключенным: Z")
        let none = PermissionUsage(permission: .camera, all: [], enabled: [])
        #expect(PermissionPortal.summary(none) == "Пока ни один модуль не требует")
    }

    @Test func blockedModulesAreEnabledOnesWithMissingRights() {
        let b = PermissionPortal.blockedModules(isEnabled: { $0 == .diskClean || $0 == .vpn }, status: denied)
        #expect(b.map(\.id) == [.diskClean])
        #expect(PermissionPortal.blockedModules(isEnabled: { _ in true }, status: allGranted).isEmpty)
    }

    @Test func everyPermissionHasPurposeText() {
        for p in Permission.allCases { #expect(!PermissionPortal.purpose(p).isEmpty) }
    }
}

@Suite struct HotkeyRegistryTests {
    private let a = KeyCombo(keyCode: 9, modifiers: KeyCombo.cmd)
    private let b = KeyCombo(keyCode: 0, modifiers: KeyCombo.cmd)

    @Test func rowsCoverCoreAndModulesWithUniqueIDs() {
        let ids = HotkeyRegistry.rows.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == Set(HotkeyHints.allSpecs.map(\.id)))
        #expect(HotkeyRegistry.rows.first?.group == HotkeyRegistry.coreGroup)
        #expect(HotkeyRegistry.rows.filter { $0.module == nil }.count == CoreHotkeys.all.count)
    }

    @Test func duplicatesAreSymmetricAndIgnoreNone() {
        let d = HotkeyRegistry.duplicates([("x", "X", a), ("y", "Y", a), ("z", "Z", b), ("n1", "N1", .none), ("n2", "N2", .none)])
        #expect(d["x"] == ["Y"] && d["y"] == ["X"])
        #expect(d["z"] == nil && d["n1"] == nil && d["n2"] == nil)
    }

    @Test func threeWayDuplicate() {
        let d = HotkeyRegistry.duplicates([("x", "X", a), ("y", "Y", a), ("w", "W", a)])
        #expect(Set(d["x"] ?? []) == ["Y", "W"])
        #expect(d.count == 3)
    }

    private func combo(_ s: HotkeySpec) -> KeyCombo { s.defaultCombo.isNone ? .none : s.defaultCombo }

    @Test func searchByTitleOwnerAndKeys() {
        let panel = HotkeyRegistry.sections(query: "панель", filter: .all, combo: combo, conflicting: []).flatMap(\.rows)
        #expect(panel.contains { $0.id == CoreHotkeys.panel.id })
        let byKeys = HotkeyRegistry.sections(query: "⌥⌘M", filter: .all, combo: combo, conflicting: []).flatMap(\.rows)
        #expect(byKeys.contains { $0.id == CoreHotkeys.panel.id })
        let none = HotkeyRegistry.sections(query: "zzzzqqq", filter: .all, combo: combo, conflicting: []).flatMap(\.rows)
        #expect(none.isEmpty)
    }

    @Test func changedAndConflictFilters() {
        let spec = CoreHotkeys.panel
        let moved: (HotkeySpec) -> KeyCombo = { $0.id == spec.id ? KeyCombo(keyCode: 12, modifiers: KeyCombo.cmd) : $0.defaultCombo }
        let changed = HotkeyRegistry.sections(query: "", filter: .changed, combo: moved, conflicting: []).flatMap(\.rows)
        #expect(changed.map(\.id) == [spec.id])
        let conf = HotkeyRegistry.sections(query: "", filter: .conflicts, combo: combo, conflicting: [CoreHotkeys.window.id]).flatMap(\.rows)
        #expect(conf.map(\.id) == [CoreHotkeys.window.id])
        #expect(HotkeyRegistry.sections(query: "", filter: .conflicts, combo: combo, conflicting: []).isEmpty)
    }

    @Test func sectionsFollowGroupOrderWithCoreFirst() {
        let secs = HotkeyRegistry.sections(query: "", filter: .all, combo: combo, conflicting: [])
        #expect(secs.first?.title == HotkeyRegistry.coreGroup)
        let titles = secs.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(secs.flatMap(\.rows).count == HotkeyRegistry.rows.count)
    }
}

@Suite struct TodayLogicTests {
    private let gb: UInt64 = 1_073_741_824

    @Test func diskTones() {
        #expect(TodayLogic.diskTone(free: 5 * gb, total: 500 * gb) == .bad)
        #expect(TodayLogic.diskTone(free: 26 * gb, total: 500 * gb) == .warn)
        #expect(TodayLogic.diskTone(free: 200 * gb, total: 500 * gb) == .good)
        #expect(TodayLogic.diskTone(free: 40 * gb, total: 100 * gb) == .good)
        #expect(TodayLogic.diskTone(free: 20 * gb, total: 100 * gb) == .warn)
    }

    @Test func batteryTones() {
        #expect(TodayLogic.batteryTone(percent: 5, onAC: false) == .bad)
        #expect(TodayLogic.batteryTone(percent: 15, onAC: false) == .warn)
        #expect(TodayLogic.batteryTone(percent: 5, onAC: true) == .good)
        #expect(TodayLogic.batteryTone(percent: nil, onAC: false) == .neutral)
        #expect(TodayLogic.batteryTone(percent: 80, onAC: false) == .good)
    }

    @Test func calmInputGivesNoAttention() {
        var x = TodayInput()
        x.vpnEnabled = true; x.vpnState = .ok
        x.diskFreeBytes = 200 * gb; x.diskTotalBytes = 500 * gb
        x.batteryPercent = 80
        #expect(TodayLogic.attention(x).isEmpty)
    }

    @Test func attentionCollectsProblemsInOrderWithSections() {
        var x = TodayInput()
        x.warnings = ["Code Helper: процессор", "node: память"]
        x.vpnEnabled = true; x.vpnState = .down
        x.diskFreeBytes = 8 * gb; x.diskTotalBytes = 500 * gb
        x.batteryPercent = 9
        x.blockedModules = 2
        let a = TodayLogic.attention(x)
        #expect(a.map(\.section) == ["guard", "guard", "net", "storage", "energy", "perm"])
        #expect(a.first?.text == "Сторож: Code Helper: процессор")
        #expect(a.first { $0.id == "disk" }?.text == "Диск: свободно 8,0 ГБ")
    }

    @Test func manyWarningsAreFolded() {
        var x = TodayInput()
        x.warnings = (1...6).map { "w\($0)" }
        let a = TodayLogic.attention(x, maxWarnings: 3)
        #expect(a.count == 4)
        #expect(a.last?.text == "Сторож: ещё 3")
    }

    @Test func disabledVpnAndOffStateAreNotProblems() {
        var x = TodayInput()
        x.vpnEnabled = false; x.vpnState = .down
        #expect(TodayLogic.attention(x).isEmpty)
        x.vpnEnabled = true; x.vpnState = .off
        #expect(TodayLogic.attention(x).isEmpty)
        x.vpnState = .degraded
        #expect(TodayLogic.attention(x).map(\.section) == ["net"])
    }
}
