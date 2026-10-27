import Testing
import Foundation
@testable import MultitulCore

@Suite struct QuickToggleCatalogTests {
    @Test func catalogHasTheEightActions() {
        #expect(QuickToggleID.allCases.map(\.rawValue) == ["darkMode", "desktopIcons", "ejectDisks", "emptyTrash", "restartFinder", "lockScreen", "displaySleep", "screenSaver"])
    }

    @Test func everyActionHasTextAndSymbol() {
        for id in QuickToggleID.allCases {
            #expect(!id.title.isEmpty && !id.caption.isEmpty && !id.symbol.isEmpty && !id.summary.isEmpty)
            #expect(id.rawValue.allSatisfy { $0.isASCII })
        }
    }

    @Test func onlyTwoAreSwitches() {
        #expect(QuickToggleID.allCases.filter(\.isSwitch) == [.darkMode, .desktopIcons])
    }

    @Test func onlyTrashNeedsConfirmationAndAutomation() {
        #expect(QuickToggleID.allCases.filter(\.needsConfirmation) == [.emptyTrash])
        #expect(QuickToggleID.allCases.compactMap(\.permission) == [.automation])
    }
}

@Suite struct EjectPolicyTests {
    private let usb = VolumeInfo(name: "USB", path: "/Volumes/USB")
    private let dmg = VolumeInfo(name: "Image", path: "/Volumes/Image", isEjectable: true)

    @Test func externalEjectableVolumesAreTargets() {
        #expect(EjectPolicy.targets([usb, dmg]).map(\.name) == ["USB", "Image"])
    }

    @Test func internalRootAndSystemVolumesAreSkipped() {
        let all = [VolumeInfo(name: "Macintosh HD", path: "/", isInternal: true, isEjectable: false),
                   VolumeInfo(name: "Data", path: "/System/Volumes/Data", isInternal: true, isEjectable: false),
                   VolumeInfo(name: "VM", path: "/System/Volumes/VM", isInternal: false, isEjectable: true),
                   VolumeInfo(name: "Internal", path: "/Volumes/Internal", isInternal: true, isEjectable: true),
                   VolumeInfo(name: "Tmp", path: "/private/var/x", isInternal: false, isEjectable: true), usb]
        #expect(EjectPolicy.targets(all).map(\.name) == ["USB"])
    }

    @Test func networkSharesAreSkipped() {
        #expect(EjectPolicy.targets([VolumeInfo(name: "NAS", path: "/Volumes/NAS", isLocal: false)]).isEmpty)
    }

    @Test func fixedExternalDisksAreSkippedUnlessRemovable() {
        let fixed = VolumeInfo(name: "SSD", path: "/Volumes/SSD", isEjectable: false, isRemovable: false)
        let removable = VolumeInfo(name: "Card", path: "/Volumes/Card", isEjectable: false, isRemovable: true)
        #expect(EjectPolicy.targets([fixed, removable]).map(\.name) == ["Card"])
    }
}

@Suite struct QuickToggleRegistryTests {
    private func rig(_ s: QuickToggleSettings = QuickToggleSettings()) -> (QuickToggleRegistry, TlsToggleDriver) {
        let d = TlsToggleDriver()
        return (QuickToggleRegistry(driver: d, settings: s), d)
    }

    @Test func darkModeFlipsBothWays() {
        let (r, d) = rig()
        #expect(r.perform(.darkMode) == .done(message: "Тёмная тема включена", state: true))
        #expect(d.dark && r.state(of: .darkMode) == true)
        #expect(r.perform(.darkMode) == .done(message: "Светлая тема включена", state: false))
        #expect(!d.dark)
    }

    @Test func desktopIconsFlip() {
        let (r, d) = rig()
        #expect(r.perform(.desktopIcons) == .done(message: "Иконки рабочего стола скрыты", state: true))
        #expect(d.hidden)
        #expect(r.perform(.desktopIcons) == .done(message: "Иконки рабочего стола вернулись", state: false))
    }

    @Test func switchFailureIsReportedWithoutStateChange() {
        let (r, d) = rig()
        d.okAll = false
        #expect(r.perform(.darkMode) == .failed(message: "Не удалось переключить тему"))
        #expect(!d.dark && r.state(of: .darkMode) == false)
    }

    @Test func actionsHaveNoSwitchState() {
        let (r, _) = rig()
        for id in QuickToggleID.allCases where !id.isSwitch { #expect(r.state(of: id) == nil) }
    }

    @Test func ejectWithoutExternalDisks() {
        let (r, d) = rig()
        d.vols = [VolumeInfo(name: "HD", path: "/", isInternal: true, isEjectable: false)]
        #expect(r.perform(.ejectDisks) == .nothingToDo(message: "Внешних дисков нет"))
        #expect(d.ejected.isEmpty)
    }

    @Test func ejectAllExternalDisks() {
        let (r, d) = rig()
        d.vols = [VolumeInfo(name: "A", path: "/Volumes/A"), VolumeInfo(name: "B", path: "/Volumes/B"), VolumeInfo(name: "HD", path: "/", isInternal: true)]
        #expect(r.perform(.ejectDisks) == .done(message: "Извлечено дисков: 2", state: nil))
        #expect(d.ejected == ["A", "B"])
    }

    @Test func ejectPartialAndTotalFailure() {
        let (r, d) = rig()
        d.vols = [VolumeInfo(name: "A", path: "/Volumes/A"), VolumeInfo(name: "B", path: "/Volumes/B")]
        d.failEject = ["B"]
        #expect(r.perform(.ejectDisks) == .done(message: "Извлечено: 1, не вышло: B", state: nil))
        d.failEject = ["A", "B"]
        #expect(r.perform(.ejectDisks) == .failed(message: "Не удалось извлечь: A, B"))
    }

    @Test func trashAsksForConfirmationFirst() {
        let (r, d) = rig()
        let first = r.perform(.emptyTrash)
        #expect(first == .needsConfirmation(prompt: "Очистить Корзину? Элементов: 3. Это нельзя отменить."))
        #expect(!d.calls.contains("trash"))
        #expect(r.perform(.emptyTrash, confirmed: true) == .done(message: "Корзина очищена", state: nil))
        #expect(d.calls.contains("trash") && d.trash == 0)
    }

    @Test func trashWithUnknownCountStillAsks() {
        let (r, d) = rig()
        d.trash = nil
        #expect(r.perform(.emptyTrash) == .needsConfirmation(prompt: "Очистить Корзину? Это нельзя отменить."))
    }

    @Test func emptyTrashIsNotTouched() {
        let (r, d) = rig()
        d.trash = 0
        #expect(r.perform(.emptyTrash) == .nothingToDo(message: "Корзина уже пуста"))
        #expect(!d.calls.contains("trash"))
    }

    @Test func confirmationCanBeDisabled() {
        var s = QuickToggleSettings()
        s.confirmTrash = false
        let (r, d) = rig(s)
        #expect(r.perform(.emptyTrash) == .done(message: "Корзина очищена", state: nil))
        #expect(d.calls == ["trash"])
    }

    @Test func trashFailureMentionsAutomation() {
        var s = QuickToggleSettings()
        s.confirmTrash = false
        let (r, d) = rig(s)
        d.okAll = false
        #expect(r.perform(.emptyTrash).message.contains("автоматизации"))
    }

    @Test func singleShotActionsCallTheirDriverMethod() {
        let (r, d) = rig()
        _ = r.perform(.restartFinder); _ = r.perform(.lockScreen); _ = r.perform(.displaySleep); _ = r.perform(.screenSaver)
        #expect(d.calls == ["finder", "lock", "display", "saver"])
    }

    @Test func singleShotFailuresAreExplained() {
        let (r, d) = rig()
        d.okAll = false
        for id in [QuickToggleID.restartFinder, .lockScreen, .displaySleep, .screenSaver] {
            if case .failed(let m) = r.perform(id) { #expect(m.hasPrefix("Не удалось")) } else { Issue.record("\(id) did not fail") }
        }
    }
}

@Suite struct QuickToggleSettingsTests {
    @Test func defaultsShowEverythingWithConfirmation() {
        let s = QuickToggleSettings()
        #expect(s.enabled == QuickToggleID.allCases && s.confirmTrash && s.showHud)
    }

    @Test func registryReportsOnlyEnabledToggles() {
        var s = QuickToggleSettings()
        s.enabled = [.screenSaver, .darkMode, .darkMode]
        let r = QuickToggleRegistry(driver: TlsToggleDriver(), settings: s)
        #expect(r.visible == [.screenSaver, .darkMode])
    }

    @Test func storeRoundTripKeepsOrder() {
        let kv = WndMemoryStore()
        let store = QuickToggleSettingsStore(kv)
        store.save(QuickToggleSettings())
        #expect(kv.values.isEmpty)
        var s = QuickToggleSettings()
        s.enabled = [.lockScreen, .darkMode]
        s.confirmTrash = false
        store.save(s)
        #expect(store.load().enabled == [.lockScreen, .darkMode])
        #expect(!store.load().confirmTrash)
    }

    @Test func unknownStoredIdsAreDropped() {
        let kv = WndMemoryStore()
        kv.set("darkMode,bogus,lockScreen", forKey: "quickToggles.enabled")
        #expect(QuickToggleSettingsStore(kv).load().enabled == [.darkMode, .lockScreen])
    }

    @Test func emptyListIsAllowed() {
        let kv = WndMemoryStore()
        let store = QuickToggleSettingsStore(kv)
        var s = QuickToggleSettings()
        s.enabled = []
        store.save(s)
        #expect(store.load().enabled.isEmpty)
    }
}
