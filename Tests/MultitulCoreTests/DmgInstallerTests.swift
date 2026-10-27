import Testing
import Foundation
@testable import MultitulCore

final class DmgFakeSystem: DmgSystem {
    var entries: [String: [DmgEntry]] = [:]
    var infos: [String: AppBundleInfo] = [:]
    var existing: Set<String> = []
    var running: Set<String> = []
    var writable: Set<String> = ["/Applications", "/Users/me/Applications"]
    var signature = SignatureCheck.valid
    var copyError: Error?
    var detachResults: [Bool] = [true]
    var trashError: Error?
    var log: [String] = []

    func listTopLevel(_ path: String) -> [DmgEntry] { entries[path] ?? [] }
    func bundleInfo(_ appPath: String) -> AppBundleInfo? { infos[appPath] }
    func exists(_ path: String) -> Bool { existing.contains(path) }
    func isRunning(appAt path: String) -> Bool { running.contains(path) }
    func isWritableDirectory(_ path: String) -> Bool { writable.contains(path) }
    func verifySignature(_ appPath: String) -> SignatureCheck { log.append("verify"); return signature }

    func copyBundle(from: String, to: String, replacing: Bool) throws {
        log.append("copy \(from) -> \(to) replacing=\(replacing)")
        if let copyError { throw copyError }
    }

    func moveToTrash(_ path: String) throws {
        log.append("trash \(path)")
        if let trashError { throw trashError }
    }

    func detach(mountPoint: String, force: Bool) -> Bool {
        log.append("detach force=\(force)")
        return detachResults.isEmpty ? true : detachResults.removeFirst()
    }

    func reveal(_ path: String) { log.append("reveal \(path)") }
}

struct DmgBoom: Error {}

@Suite struct DmgScannerTests {
    private func app(_ n: String) -> DmgEntry { DmgEntry(name: n, isDirectory: true) }

    @Test func singleAppWithTypicalDecorations() {
        let list = [app("Foo.app"), DmgEntry(name: "Applications", isDirectory: false, isSymlink: true), DmgEntry(name: ".background", isDirectory: true),
                    DmgEntry(name: ".DS_Store"), DmgEntry(name: "README.txt"), DmgEntry(name: ".VolumeIcon.icns")]
        #expect(DmgScanner.scan(list) == .singleApp("Foo.app"))
    }

    @Test func emptyAndNonAppContentsMeanNoApp() {
        #expect(DmgScanner.scan([]) == .noApp)
        #expect(DmgScanner.scan([DmgEntry(name: "doc.pdf"), DmgEntry(name: "Folder", isDirectory: true)]) == .noApp)
    }

    @Test func severalAppsAreReportedSorted() {
        #expect(DmgScanner.scan([app("B.app"), app("A.app")]) == .multiple(["A.app", "B.app"]))
    }

    @Test func installerPackagesAreDetected() {
        #expect(DmgScanner.scan([DmgEntry(name: "Install Foo.pkg")]) == .installerOnly(["Install Foo.pkg"]))
        #expect(DmgScanner.scan([app("Foo.app"), DmgEntry(name: "Extras.mpkg")]) == .appAndInstaller(app: ["Foo.app"], installer: ["Extras.mpkg"]))
    }

    @Test func symlinkedAppAndHiddenAppAreIgnored() {
        #expect(DmgScanner.scan([DmgEntry(name: "Alias.app", isDirectory: true, isSymlink: true), app(".Hidden.app")]) == .noApp)
        #expect(DmgScanner.scan([app("Файл.APP")]) == .singleApp("Файл.APP"))
    }
}

@Suite struct DmgPlannerTests {
    private func system(apps: [String] = ["Foo.app"]) -> DmgFakeSystem {
        let s = DmgFakeSystem()
        s.entries["/Volumes/Foo"] = apps.map { DmgEntry(name: $0, isDirectory: true) }
        s.infos["/Volumes/Foo/Foo.app"] = AppBundleInfo(bundleID: "com.foo", version: "2.0")
        return s
    }

    private func plan(_ s: DmgFakeSystem, _ settings: DmgSettings = DmgSettings(), dmg: String? = "/Users/me/Downloads/Foo.dmg") -> Result<DmgPlan, DmgRefusal> {
        DmgPlanner.plan(mountPoint: "/Volumes/Foo", dmgPath: dmg, settings: settings, system: s, home: "/Users/me")
    }

    @Test func defaultPlanVerifiesCopiesEjectsAndReveals() throws {
        let p = try plan(system()).get()
        #expect(p.appName == "Foo.app")
        #expect(p.sourcePath == "/Volumes/Foo/Foo.app")
        #expect(p.destinationPath == "/Applications/Foo.app")
        #expect(!p.replaces)
        #expect(p.steps == [.verifySignature, .copy, .eject, .reveal])
        #expect(p.version == "2.0")
    }

    @Test func trashStepOnlyWithEjectAndKnownDmg() throws {
        var s = DmgSettings()
        s.trashDmg = true
        #expect(try plan(system(), s).get().steps == [.verifySignature, .copy, .eject, .trashDmg, .reveal])
        #expect(try plan(system(), s, dmg: nil).get().steps == [.verifySignature, .copy, .eject, .reveal])
        s.ejectAfter = false
        #expect(try plan(system(), s).get().steps == [.verifySignature, .copy, .reveal])
    }

    @Test func signatureStepCanBeSwitchedOff() throws {
        var s = DmgSettings()
        s.requireValidSignature = false
        s.reveal = false
        #expect(try plan(system(), s).get().steps == [.copy, .eject])
    }

    @Test func userApplicationsDestination() throws {
        var s = DmgSettings()
        s.destination = .user
        let sys = system()
        sys.existing.insert("/Users/me/Applications")
        #expect(try plan(sys, s).get().destinationPath == "/Users/me/Applications/Foo.app")
    }

    @Test func refusalsForUnsuitableImages() {
        #expect(plan(system(apps: [])) == .failure(.noApp))
        #expect(plan(system(apps: ["Foo.app", "Bar.app"])) == .failure(.multipleApps(["Bar.app", "Foo.app"])))
        let pkg = DmgFakeSystem()
        pkg.entries["/Volumes/Foo"] = [DmgEntry(name: "Setup.pkg")]
        #expect(plan(pkg) == .failure(.installerOnly))
        #expect(DmgRefusal.noApp.isQuiet)
        #expect(!DmgRefusal.appRunning.isQuiet)
    }

    @Test func existingSameVersionIsRefusedUnlessReinstallAllowed() throws {
        let s = system()
        s.existing.insert("/Applications/Foo.app")
        s.infos["/Applications/Foo.app"] = AppBundleInfo(bundleID: "com.foo", version: "2.0")
        #expect(plan(s) == .failure(.alreadyInstalled("2.0")))
        var allow = DmgSettings()
        allow.reinstallSameVersion = true
        let p = try plan(s, allow).get()
        #expect(p.replaces)
    }

    @Test func upgradeReplacesExistingCopy() throws {
        let s = system()
        s.existing.insert("/Applications/Foo.app")
        s.infos["/Applications/Foo.app"] = AppBundleInfo(bundleID: "com.foo", version: "1.0")
        #expect(try plan(s).get().replaces)
    }

    @Test func runningInstalledAppBlocksReplacement() {
        let s = system()
        s.existing.insert("/Applications/Foo.app")
        s.infos["/Applications/Foo.app"] = AppBundleInfo(bundleID: "com.foo", version: "1.0")
        s.running.insert("/Applications/Foo.app")
        #expect(plan(s) == .failure(.appRunning))
    }

    @Test func appLaunchedFromTheImageDoesNotCountAsRunning() throws {
        let s = system()
        s.running.insert("/Volumes/Foo/Foo.app")
        #expect(try plan(s).get().steps.contains(.copy))
    }

    @Test func unwritableDestinationIsReported() {
        let s = system()
        s.writable = []
        s.existing.insert("/Applications")
        #expect(plan(s) == .failure(.destinationNotWritable("/Applications")))
    }
}

@Suite struct DmgExecutorTests {
    private func plan(_ steps: [DmgStep], replaces: Bool = false) -> DmgPlan {
        DmgPlan(appName: "Foo.app", sourcePath: "/Volumes/Foo/Foo.app", destinationPath: "/Applications/Foo.app", mountPoint: "/Volumes/Foo", dmgPath: "/d/Foo.dmg", replaces: replaces, steps: steps, version: "2.0")
    }

    @Test func fullRunFollowsThePlanInOrder() {
        let s = DmgFakeSystem()
        let r = DmgInstaller(system: s).execute(plan([.verifySignature, .copy, .eject, .trashDmg, .reveal], replaces: true))
        #expect(r.ok)
        #expect(r.done == [.verifySignature, .copy, .eject, .trashDmg, .reveal])
        #expect(s.log == ["verify", "copy /Volumes/Foo/Foo.app -> /Applications/Foo.app replacing=true", "detach force=false", "trash /d/Foo.dmg", "reveal /Applications/Foo.app"])
    }

    @Test func badSignatureStopsBeforeCopyAndKeepsImageMounted() {
        let s = DmgFakeSystem()
        s.signature = .invalid("a sealed resource is missing")
        let r = DmgInstaller(system: s).execute(plan([.verifySignature, .copy, .eject]))
        #expect(!r.ok)
        #expect(r.failedStep == .verifySignature)
        #expect(r.message?.contains("a sealed resource") == true)
        #expect(s.log == ["verify"])
    }

    @Test func unsignedAppIsRejectedWhenSignatureRequired() {
        let s = DmgFakeSystem()
        s.signature = .unsigned
        let r = DmgInstaller(system: s).execute(plan([.verifySignature, .copy]))
        #expect(r.failedStep == .verifySignature)
        #expect(r.message == "Приложение без подписи")
    }

    @Test func copyFailureLeavesImageAndDmgAlone() {
        let s = DmgFakeSystem()
        s.copyError = DmgBoom()
        let r = DmgInstaller(system: s).execute(plan([.verifySignature, .copy, .eject, .trashDmg]))
        #expect(r.failedStep == .copy)
        #expect(!s.log.contains { $0.hasPrefix("detach") || $0.hasPrefix("trash") })
    }

    @Test func busyImageIsForceEjectedOnRetry() {
        let s = DmgFakeSystem()
        s.detachResults = [false, true]
        let r = DmgInstaller(system: s).execute(plan([.copy, .eject, .trashDmg]))
        #expect(r.ok)
        #expect(s.log.filter { $0.hasPrefix("detach") } == ["detach force=false", "detach force=true"])
        #expect(r.done.contains(.trashDmg))
    }

    @Test func failedEjectSkipsTrashingTheDmgAndWarns() {
        let s = DmgFakeSystem()
        s.detachResults = [false, false]
        let r = DmgInstaller(system: s).execute(plan([.copy, .eject, .trashDmg, .reveal]))
        #expect(r.ok)
        #expect(r.warnings.count == 2)
        #expect(!r.done.contains(.eject))
        #expect(!r.done.contains(.trashDmg))
        #expect(r.done.contains(.reveal))
        #expect(!s.log.contains { $0.hasPrefix("trash") })
    }

    @Test func trashFailureIsOnlyAWarning() {
        let s = DmgFakeSystem()
        s.trashError = DmgBoom()
        let r = DmgInstaller(system: s).execute(plan([.copy, .eject, .trashDmg]))
        #expect(r.ok)
        #expect(r.warnings.count == 1)
    }
}

@Suite struct HdiutilParserTests {
    private let attach = """
    some EULA text printed before the plist
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>system-entities</key><array>
    <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk4</string></dict>
    <dict><key>content-hint</key><string>Apple_HFS</string><key>mount-point</key><string>/Volumes/Тест Foo</string></dict>
    </array></dict></plist>
    """

    private let info = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict><key>images</key><array>
    <dict><key>image-path</key><string>/Users/me/Downloads/Foo.dmg</string><key>system-entities</key><array>
    <dict><key>mount-point</key><string>/Volumes/Foo</string></dict><dict><key>dev-entry</key><string>/dev/disk5</string></dict></array></dict>
    <dict><key>image-path</key><string>/Users/me/Other.dmg</string><key>system-entities</key><array><dict><key>mount-point</key><string>/Volumes/Other</string></dict></array></dict>
    </array></dict></plist>
    """

    @Test func attachOutputYieldsMountPointsEvenWithLeadingNoise() {
        #expect(HdiutilParser.mountPoints(attachPlist: Data(attach.utf8)) == ["/Volumes/Тест Foo"])
        #expect(HdiutilParser.mountPoints(attachPlist: Data("garbage".utf8)).isEmpty)
    }

    @Test func infoOutputMapsMountPointsToImages() {
        let imgs = HdiutilParser.images(infoPlist: Data(info.utf8))
        #expect(imgs.count == 2)
        #expect(HdiutilParser.imagePath(forMountPoint: "/Volumes/Foo", in: imgs) == "/Users/me/Downloads/Foo.dmg")
        #expect(HdiutilParser.imagePath(forMountPoint: "/Volumes/Usb", in: imgs) == nil)
    }
}

@Suite struct DownloadsDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func f(_ n: String, size: Int64 = 100, age: TimeInterval = 10) -> DownloadFile { DownloadFile(name: n, size: size, modified: t0.addingTimeInterval(-age)) }

    @Test func existingDmgsAreIgnoredAtStartup() {
        var d = DownloadsDmgDetector()
        #expect(d.poll([f("old.dmg")], now: t0).isEmpty)
        #expect(d.poll([f("old.dmg")], now: t0.addingTimeInterval(5)).isEmpty)
    }

    @Test func newDmgIsReportedOnceAfterTheSizeSettles() {
        var d = DownloadsDmgDetector()
        _ = d.poll([], now: t0)
        #expect(d.poll([f("new.dmg", size: 50)], now: t0).isEmpty)
        #expect(d.poll([f("new.dmg", size: 80)], now: t0).isEmpty)
        #expect(d.poll([f("new.dmg", size: 80)], now: t0) == ["new.dmg"])
        #expect(d.poll([f("new.dmg", size: 80)], now: t0).isEmpty)
    }

    @Test func freshlyModifiedFileWaitsForTheSettleTime() {
        var d = DownloadsDmgDetector()
        _ = d.poll([], now: t0)
        _ = d.poll([f("n.dmg", age: 0.5)], now: t0)
        #expect(d.poll([f("n.dmg", age: 0.5)], now: t0).isEmpty)
        #expect(d.poll([f("n.dmg", age: 0.5)], now: t0.addingTimeInterval(5)) == ["n.dmg"])
    }

    @Test func partialDownloadsAreRecognised() {
        #expect(DownloadsDmgDetector.isPartial("Foo.dmg.crdownload"))
        #expect(DownloadsDmgDetector.isPartial("Foo.dmg.download"))
        #expect(!DownloadsDmgDetector.isPartial("Foo.dmg"))
    }

    @Test func nonDmgAndEmptyFilesNeverTrigger() {
        var d = DownloadsDmgDetector()
        _ = d.poll([], now: t0)
        for _ in 0..<3 { #expect(d.poll([f("a.zip"), f("empty.dmg", size: 0)], now: t0).isEmpty) }
    }

    @Test func deletedAndReDownloadedDmgIsReportedAgain() {
        var d = DownloadsDmgDetector()
        _ = d.poll([], now: t0)
        _ = d.poll([f("x.dmg")], now: t0)
        #expect(d.poll([f("x.dmg")], now: t0) == ["x.dmg"])
        _ = d.poll([], now: t0)
        _ = d.poll([f("x.dmg")], now: t0)
        #expect(d.poll([f("x.dmg")], now: t0) == ["x.dmg"])
    }
}
