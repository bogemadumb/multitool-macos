import Testing
import Foundation
@testable import MultitulCore

private func rel(_ l: [Leftover], _ f: CleanFixture) -> Set<String> {
    Set(l.map { $0.path.replacingOccurrences(of: f.home + "/", with: "").replacingOccurrences(of: f.root + "/", with: "") })
}

@Suite struct UninstallerTests {
    private func fooFixture() -> (CleanFixture, InstalledApp) {
        let f = CleanFixture()
        let path = f.app("Foo", id: "com.vendor.foo")
        for r in ["Library/Containers/com.vendor.foo/x", "Library/Group Containers/ABCDE12345.com.vendor.foo/x", "Library/Group Containers/group.com.vendor.foo/x",
                  "Library/Application Support/Foo/x", "Library/Application Support/com.vendor.foo/x", "Library/Caches/com.vendor.foo/x", "Library/Caches/Foo/x",
                  "Library/Preferences/com.vendor.foo.plist", "Library/Preferences/ByHost/com.vendor.foo.ABCD.plist",
                  "Library/Saved Application State/com.vendor.foo.savedState/x", "Library/HTTPStorages/com.vendor.foo/x", "Library/Logs/Foo/x",
                  "Library/LaunchAgents/com.vendor.foo.helper.plist", "Library/WebKit/com.vendor.foo/x", "Library/Cookies/com.vendor.foo.binarycookies",
                  "Library/Application Scripts/com.vendor.foo/x"] {
            f.file(r, bytes: 4000)
        }
        f.file("sys/Library/LaunchDaemons/com.vendor.foo.helper.plist", bytes: 100)
        f.file("sys/private/var/db/receipts/com.vendor.foo.bom", bytes: 100)
        f.file("sys/Library/Application Support/Foo/x", bytes: 100)
        return (f, InstalledApp(path: path, bundleId: "com.vendor.foo", name: "Foo", version: "1.0"))
    }

    @Test func findsEveryRelatedFolderWithSizes() {
        let (f, app) = fooFixture()
        let found = Uninstaller.findRelated(app: app, installed: [app], env: f.env(), systemRoot: f.home + "/sys")
        let user = found.filter { $0.blocked == nil }
        #expect(rel(user, f) == [
            "Applications/Foo.app", "Library/Containers/com.vendor.foo", "Library/Group Containers/ABCDE12345.com.vendor.foo", "Library/Group Containers/group.com.vendor.foo",
            "Library/Application Support/Foo", "Library/Application Support/com.vendor.foo", "Library/Caches/com.vendor.foo", "Library/Caches/Foo",
            "Library/Preferences/com.vendor.foo.plist", "Library/Preferences/ByHost/com.vendor.foo.ABCD.plist", "Library/Saved Application State/com.vendor.foo.savedState",
            "Library/HTTPStorages/com.vendor.foo", "Library/Logs/Foo", "Library/LaunchAgents/com.vendor.foo.helper.plist", "Library/WebKit/com.vendor.foo",
            "Library/Cookies/com.vendor.foo.binarycookies", "Library/Application Scripts/com.vendor.foo",
        ])
        #expect(user.allSatisfy { $0.bytes > 0 })
        let sys = found.filter { $0.blocked != nil }
        #expect(sys.count == 3)
        #expect(sys.allSatisfy { $0.blocked?.contains("администратор") == true && $0.path.hasPrefix(f.home + "/sys") })
        #expect(Set(sys.map(\.kind)) == [.system, .receipt])
    }

    @Test func similarNamesAreNotClaimed() {
        let (f, app) = fooFixture()
        for r in ["Library/Containers/com.vendor.foobar/x", "Library/Caches/com.vendor.foo2/x", "Library/Application Support/Foo Bar/x", "Library/Application Support/Food/x",
                  "Library/Caches/com.other.foo/x", "Library/Preferences/com.vendor.fo.plist", "Library/Caches/com.apple.foo/x",
                  "Library/Containers/com.vendor.foo.pro/x", "Library/Preferences/com.vendor.foo.pro.plist"] {
            f.file(r, bytes: 100)
        }
        let pro = InstalledApp(path: f.app("FooPro", id: "com.vendor.foo.pro"), bundleId: "com.vendor.foo.pro", name: "Foo Pro")
        let found = Uninstaller.findRelated(app: app, installed: [app, pro], env: f.env(), systemRoot: f.home + "/sys")
        let names = Set(found.map(\.title))
        for bad in ["com.vendor.foobar", "com.vendor.foo2", "Foo Bar", "Food", "com.other.foo", "com.vendor.fo.plist", "com.apple.foo", "com.vendor.foo.pro", "com.vendor.foo.pro.plist"] {
            #expect(!names.contains(bad), "must not claim \(bad)")
        }
        #expect(names.contains("com.vendor.foo"))
    }

    @Test func genericAndSystemNamesAreNotMatchedByDisplayName() {
        let f = CleanFixture()
        let code = InstalledApp(path: f.app("Code", id: "com.ms.code"), bundleId: "com.ms.code", name: "Code")
        f.file("Library/Application Support/Code/x")
        f.file("Library/Caches/Code/x")
        #expect(Uninstaller.findRelated(app: code, installed: [code], env: f.env()).count == 1)
        let twin1 = InstalledApp(path: f.app("Twin", id: "com.a.twin"), bundleId: "com.a.twin", name: "Twin")
        let twin2 = InstalledApp(path: f.app("Twin", id: "com.b.twin", in: "Applications/Other"), bundleId: "com.b.twin", name: "Twin")
        f.file("Library/Application Support/Twin/x")
        #expect(Uninstaller.findRelated(app: twin1, installed: [twin1, twin2], env: f.env()).count == 1)
        let solo = Uninstaller.findRelated(app: twin1, installed: [twin1], env: f.env())
        #expect(solo.count == 2)
    }

    @Test func runningAppBlocksEverything() {
        let (f, app) = fooFixture()
        let found = Uninstaller.findRelated(app: app, installed: [app], env: f.env(running: [RunningApp(bundleId: "com.vendor.foo", name: "Foo")]))
        #expect(found.allSatisfy { $0.blocked != nil })
        #expect(found.first?.kind == .app && found.first?.blocked == "закрой приложение")
    }

    @Test func appleAndSystemAndSelfAreProtected() {
        #expect(InstalledApp(path: "/Applications/Safari.app", bundleId: "com.apple.Safari", name: "Safari").protection != nil)
        #expect(InstalledApp(path: "/System/Applications/Mail.app", bundleId: "org.x.mail", name: "Mail").protection != nil)
        #expect(InstalledApp(path: "/Applications/Multitul.app", bundleId: "dev.multitool.app", name: "Multitul").protection != nil)
        #expect(InstalledApp(path: "/Applications/Foo.app", bundleId: "com.vendor.foo", name: "Foo").protection == nil)
        let f = CleanFixture()
        let safari = InstalledApp(path: f.app("Safari", id: "com.apple.Safari"), bundleId: "com.apple.Safari", name: "Safari")
        f.file("Library/Caches/com.apple.Safari/x")
        let found = Uninstaller.findRelated(app: safari, installed: [safari], env: f.env())
        #expect(found.allSatisfy { $0.blocked != nil })
    }

    @Test func deniedPathRules() {
        let f = CleanFixture()
        let app = f.app("Foo", id: "com.vendor.foo")
        let apple = f.app("Pages", id: "com.apple.Pages")
        let elsewhere = f.home + "/Documents/Foo.app"
        let dirs = [f.root + "/Applications"]
        func denied(_ p: String) -> Bool { Uninstaller.isDenied(p, home: f.home, appDirs: dirs) }
        #expect(!denied(app))
        #expect(denied(apple))
        #expect(denied(elsewhere))
        #expect(denied("/System/Applications/Mail.app"))
        for ok in ["Library/Containers/com.x.y", "Library/Preferences/com.x.y.plist", "Library/Caches/com.x.y", "Library/LaunchAgents/com.x.y.plist"] {
            #expect(!denied(f.home + "/" + ok), "must allow \(ok)")
        }
        for bad in ["Library", "Library/Caches", "Documents/Система/x", "Documents/Универ/a", ".ssh/id", "Library/Mail/V10", "Downloads/x", "Library/Caches/com.apple.x",
                    ".cache/uv/archive-v0", "Library/Keychains/login.keychain-db"] {
            #expect(denied(f.home + "/" + bad), "must deny \(bad)")
        }
        #expect(denied("/Library/LaunchDaemons/com.x.plist"))
        #expect(denied("/etc/hosts"))
    }

    @Test func executeMovesSelectedToTrashSkipsBlockedRefusesForged() {
        let (f, app) = fooFixture()
        let secret = f.file("Documents/Система/секрет.txt")
        var found = Uninstaller.findRelated(app: app, installed: [app], env: f.env(), systemRoot: f.home + "/sys")
        found.append(Leftover(kind: .caches, path: secret, bytes: 10, blocked: nil))
        let e = f.env()
        let rep = Uninstaller.execute(found, app: app, env: e)
        #expect(rep.movedCount == 17)
        #expect(rep.denied == [secret])
        #expect(rep.skipped.count == 3)
        #expect(FileManager.default.fileExists(atPath: secret))
        #expect(!f.existsAbs(app.path))
        #expect(!f.exists("Library/Containers/com.vendor.foo"))
        #expect(f.trashContents().count == 17)
        #expect(f.existsAbs(f.home + "/sys/Library/LaunchDaemons/com.vendor.foo.helper.plist"))
        #expect(Uninstaller.reportLines(rep).first?.hasPrefix("Перенесено в Корзину: 17") == true)
    }

    @Test func serviceDiedAfterUninstallIsReportedNotHidden() {
        let (f, app) = fooFixture()
        f.services(before: [("dev.multitool.singbox", 5, 0)], after: [("dev.multitool.singbox", nil, 1)])
        let found = Uninstaller.findRelated(app: app, installed: [app], env: f.env())
        let rep = Uninstaller.execute(found, app: app, env: f.env())
        #expect(rep.diedServices == ["dev.multitool.singbox"])
        #expect(Uninstaller.reportLines(rep).contains { $0.hasPrefix("ВНИМАНИЕ") })
        #expect(f.trashContents().count == rep.movedCount)
    }

    @Test func installedAppsScanReadsInfoPlistAndSubfolders() {
        let f = CleanFixture()
        f.app("Alpha", id: "com.a.alpha", version: "2.0")
        f.app("Beta", id: "com.b.beta", in: "Applications/Utilities")
        f.dir("Applications/NotAnApp.app/Contents")
        let apps = InstalledApps.scan(dirs: [f.root + "/Applications"])
        #expect(apps.map(\.bundleId) == ["com.a.alpha", "com.b.beta"])
        #expect(apps.first?.version == "2.0")
        #expect(InstalledApps.read(appPath: f.root + "/Applications/NotAnApp.app") == nil)
    }
}
