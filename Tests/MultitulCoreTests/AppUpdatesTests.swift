import Testing
import Foundation
@testable import MultitulCore

private let feedURL = "https://example.com/appcast.xml"
private let lookupBase = "https://itunes.apple.com/lookup?bundleId="

private func lookupJSON(version: String, id: Int = 12345, minOS: String = "12.0") -> String {
    #"{"resultCount":1,"results":[{"trackId":\#(id),"trackName":"Thing","version":"\#(version)","minimumOsVersion":"\#(minOS)","trackViewUrl":"https://apps.apple.com/app/id\#(id)","releaseNotes":"Fixes"}]}"#
}

@MainActor
private struct URig {
    let catalog = MgrCatalog()
    let http = MgrHTTP()
    let runner = MgrRunner()
    let casks = MgrCasks()
    let installer = MgrInstaller()
    let kv = WndMemoryStore()
    let clock = TlsClock()
    let store: AppUpdateStore
    let service: AppUpdateService

    init(mas: Bool = false, withCasks: Bool = false, os: String = "14.5.0", settings: AppUpdateSettings = AppUpdateSettings()) {
        store = AppUpdateStore(kv)
        store.saveSettings(settings)
        let files = mgrFiles(executables: mas ? ["/opt/homebrew/bin/mas"] : [])
        service = AppUpdateService(catalog: catalog, http: http, runner: runner, locator: ToolLocator(files: files), casks: withCasks ? casks : nil, store: store, clock: clock, osVersion: os)
        service.installer = installer
    }

    func sparkleApp(_ name: String, build: String = "100", short: String = "1.0", feed: String = feedURL) -> UpdateAppBundle {
        let a = mgrApp(name, short: short, build: build, feed: feed)
        catalog.apps.append(a)
        return a
    }
}

@Suite struct UpdateBundleReaderTests {
    @Test func readsTheKeysThatMatter() throws {
        let a = try #require(UpdateAppBundleReader.parse(plist: ["CFBundleIdentifier": "org.x.app", "CFBundleName": "X", "CFBundleDisplayName": "Икс", "CFBundleShortVersionString": "1.2",
                                                                  "CFBundleVersion": "345", "SUFeedURL": " https://x.org/feed.xml "], path: "/Applications/X.app", hasStoreReceipt: false))
        #expect(a.name == "Икс" && a.bundleId == "org.x.app" && a.shortVersion == "1.2" && a.build == "345" && a.feedURL == "https://x.org/feed.xml" && a.fileName == "X.app")
    }

    @Test func nameFallsBackToTheFileName() throws {
        let a = try #require(UpdateAppBundleReader.parse(plist: ["CFBundleIdentifier": "org.x.app", "CFBundleName": ""], path: "/Applications/My Tool.app", hasStoreReceipt: true))
        #expect(a.name == "My Tool" && a.hasStoreReceipt && a.feedURL == nil && a.shortVersion.isEmpty)
    }

    @Test func missingIdentifierMeansNotAnApp() {
        #expect(UpdateAppBundleReader.parse(plist: ["CFBundleName": "X"], path: "/x.app", hasStoreReceipt: false) == nil)
        #expect(UpdateAppBundleReader.parse(plist: ["CFBundleIdentifier": ""], path: "/x.app", hasStoreReceipt: false) == nil)
    }

    @Test func blankFeedUrlIsDropped() throws {
        let a = try #require(UpdateAppBundleReader.parse(plist: ["CFBundleIdentifier": "a.b", "SUFeedURL": "   "], path: "/x.app", hasStoreReceipt: false))
        #expect(a.feedURL == nil)
    }

    @Test func appleAndSystemAppsAreSystem() {
        #expect(mgrApp("Safari", id: "com.apple.Safari").isSystem)
        #expect(UpdateAppBundle(path: "/System/Applications/Mail.app", bundleId: "x.y", name: "Mail").isSystem)
        #expect(!mgrApp("Thing").isSystem)
    }
}

@Suite struct AppStoreParserTests {
    @Test func masOutdatedLines() {
        let out = "497799835 Xcode (14.0 -> 14.1)\n409183694  Keynote (13.1 -> 14.0)\n1444383602 GoodNotes 5 (5.9.1 -> 5.9.2)\n"
        let e = AppStoreParsers.parseMasOutdated(out)
        #expect(e.count == 3)
        #expect(e[0] == MasOutdatedEntry(id: 497799835, name: "Xcode", installed: "14.0", latest: "14.1"))
        #expect(e[1].name == "Keynote" && e[2].name == "GoodNotes 5" && e[2].latest == "5.9.2")
    }

    @Test func masOutdatedNoiseAndEmpty() {
        #expect(AppStoreParsers.parseMasOutdated("").isEmpty)
        #expect(AppStoreParsers.parseMasOutdated("Error: Not signed in\nWarning: x\n").isEmpty)
        #expect(AppStoreParsers.parseMasOutdated("497799835 Xcode (14.0 -> 14.1)\ngarbage line\n").count == 1)
        #expect(AppStoreParsers.parseMasOutdated("12 App (Beta (2) -> 3)").isEmpty || AppStoreParsers.parseMasOutdated("12 App (Beta (2) -> 3)").count == 1)
    }

    @Test func lookupResult() throws {
        let r = try #require(AppStoreParsers.parseLookup(Data(lookupJSON(version: "2.5").utf8)))
        #expect(r.version == "2.5" && r.trackId == 12345 && r.minimumOS == "12.0" && r.viewURL?.host == "apps.apple.com" && r.releaseNotes == "Fixes" && r.name == "Thing")
    }

    @Test func lookupWithoutResultsOrGarbage() {
        #expect(AppStoreParsers.parseLookup(Data(#"{"resultCount":0,"results":[]}"#.utf8)) == nil)
        #expect(AppStoreParsers.parseLookup(Data("<html>".utf8)) == nil)
        #expect(AppStoreParsers.parseLookup(Data()) == nil)
        #expect(AppStoreParsers.parseLookup(Data(#"{"results":[{"trackId":1}]}"#.utf8)) == nil)
    }

    @Test func lookupUrlCarriesBundleAndStorefront() {
        let u = AppStoreParsers.lookupURL(bundleId: "com.x.y", country: "ru")
        #expect(u?.absoluteString == "https://itunes.apple.com/lookup?bundleId=com.x.y&country=ru&entity=macSoftware")
    }
}

@Suite struct AppUpdateStoreTests {
    @Test func defaultsAreNotWritten() {
        let kv = WndMemoryStore()
        AppUpdateStore(kv).saveSettings(AppUpdateSettings())
        #expect(kv.values.isEmpty && AppUpdateStore(kv).loadSettings() == AppUpdateSettings())
    }

    @Test func roundTripAndAsciiKeys() {
        let kv = WndMemoryStore()
        var s = AppUpdateSettings()
        s.includeAppStore = false
        s.includeOther = false
        s.notifyNew = false
        s.includePrerelease = true
        s.betaChannels = "beta, nightly"
        s.checkIntervalHours = 6
        s.storefront = "us"
        s.maxConcurrent = 2
        s.extraFolders = "/Volumes/Apps\n/Users/x/Tools"
        AppUpdateStore(kv).saveSettings(s)
        #expect(AppUpdateStore(kv).loadSettings() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("appUpdates.") && $0.allSatisfy(\.isASCII) })
        #expect(s.channels == ["beta", "nightly"] && s.folders == ["/Volumes/Apps", "/Users/x/Tools"])
    }

    @Test func sanitizing() {
        var s = AppUpdateSettings()
        s.checkIntervalHours = 9999
        s.maxConcurrent = 0
        s.storefront = "Россия"
        #expect(s.sanitized.checkIntervalHours == 168 && s.sanitized.maxConcurrent == 1 && s.sanitized.storefront == "ru")
        s.storefront = "US"
        #expect(s.sanitized.storefront == "us")
        s.extraFolders = "relative/path\n  /ok  "
        #expect(s.folders == ["/ok"])
    }

    @Test func notifiedListIsCapped() {
        let st = AppUpdateStore(WndMemoryStore())
        st.notified = (0..<700).map { "a@\($0)" }
        #expect(st.notified.count == AppUpdateStore.notifiedLimit && st.notified.last == "a@699")
        st.notified = []
        #expect(st.notified.isEmpty)
    }

    @Test func lastCheckedRoundTrips() {
        let st = AppUpdateStore(WndMemoryStore())
        #expect(st.lastChecked == nil)
        st.lastChecked = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(st.lastChecked == Date(timeIntervalSince1970: 1_800_000_000))
        st.lastChecked = nil
        #expect(st.lastChecked == nil)
    }
}

@MainActor @Suite struct AppUpdateCheckTests {
    @Test func sparkleAppWithANewerBuildIsReported() async {
        let r = URig()
        let app = r.sparkleApp("Thing", build: "100", short: "1.0")
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "110", short: "1.1", extra: "<sparkle:releaseNotesLink>https://example.com/n</sparkle:releaseNotesLink>")))
        await r.service.check()
        let u = r.service.visibleUpdates
        #expect(u.count == 1 && u[0].app == app && u[0].source == .sparkle && u[0].newVersion == "1.1" && u[0].installedVersion == "1.0")
        #expect(u[0].notesURL?.absoluteString == "https://example.com/n" && u[0].downloadURL?.absoluteString == "https://example.com/app.zip")
        #expect(u[0].action == .sparkle(appPath: app.path, download: URL(string: "https://example.com/app.zip")))
        #expect(r.service.report.checked == 1 && r.service.report.finishedAt == r.clock.now && !r.service.isChecking)
    }

    @Test func upToDateAppsProduceNothing() async {
        let r = URig()
        _ = r.sparkleApp("Thing", build: "110", short: "1.1")
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "110", short: "1.1") + mgrItem(version: "100", short: "1.0")))
        await r.service.check()
        #expect(r.service.visibleUpdates.isEmpty && r.service.report.checked == 1)
    }

    @Test func betaChannelAndPrereleaseAreIgnoredByDefault() async {
        let r = URig()
        _ = r.sparkleApp("Thing", build: "100", short: "1.0")
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "120", short: "1.2b1", extra: "<sparkle:channel>beta</sparkle:channel>") + mgrItem(version: "130", short: "1.3rc1")))
        await r.service.check()
        #expect(r.service.visibleUpdates.isEmpty)
    }

    @Test func betaChannelOptIn() async {
        var s = AppUpdateSettings()
        s.betaChannels = "beta"
        s.includePrerelease = true
        let r = URig(settings: s)
        _ = r.sparkleApp("Thing", build: "100", short: "1.0")
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "120", short: "1.2b1", extra: "<sparkle:channel>beta</sparkle:channel>")))
        await r.service.check()
        #expect(r.service.visibleUpdates.first?.newVersion == "1.2b1")
    }

    @Test func releaseThatNeedsANewerMacosIsHidden() async {
        let r = URig(os: "12.6.0")
        _ = r.sparkleApp("Thing")
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "200", short: "2.0", extra: "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>")))
        await r.service.check()
        #expect(r.service.visibleUpdates.isEmpty)
    }

    @Test func unreachableOrBrokenFeedsAreRecordedNotFatal() async {
        let r = URig()
        _ = r.sparkleApp("Gone", feed: "https://gone.example/a.xml")
        _ = r.sparkleApp("Broken", feed: "https://broken.example/a.xml")
        _ = r.sparkleApp("Down", feed: "https://down.example/a.xml")
        _ = r.sparkleApp("Fine", feed: "https://fine.example/a.xml")
        r.http.set("https://broken.example/a.xml", "<html><body>oops")
        r.http.failing = ["https://down.example/a.xml"]
        r.http.set("https://fine.example/a.xml", mgrAppcast(mgrItem(version: "999", short: "9.9")))
        await r.service.check()
        let rep = r.service.report
        #expect(rep.updates.map(\.app.name) == ["Fine"] && rep.checked == 4)
        #expect(rep.failures.keys.contains("org.test.gone") && rep.failures.keys.contains("org.test.broken") && rep.failures.keys.contains("org.test.down") && rep.failures.count == 3)
        #expect(rep.failures["org.test.gone"] == "HTTP 404")
    }

    @Test func appsWithoutAnySourceAreCountedSeparately() async {
        let r = URig()
        r.catalog.apps = [mgrApp("Plain"), mgrApp("Other")]
        _ = r.sparkleApp("Thing")
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "1", short: "0.1")))
        await r.service.check()
        #expect(r.service.report.withoutSource == 2 && r.service.report.checked == 1)
    }

    @Test func appleAppsAndDuplicatePathsAreSkipped() async {
        let r = URig()
        let a = r.sparkleApp("Thing")
        r.catalog.apps.append(a)
        r.catalog.apps.append(mgrApp("Safari", id: "com.apple.Safari", feed: feedURL))
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "500", short: "5.0")))
        await r.service.check()
        #expect(r.service.visibleUpdates.count == 1 && r.http.requested.count == 1)
    }

    @Test func otherAppsSwitchSkipsSparkleFeeds() async {
        var s = AppUpdateSettings()
        s.includeOther = false
        let r = URig(settings: s)
        _ = r.sparkleApp("Thing")
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "500", short: "5.0")))
        await r.service.check()
        #expect(r.service.visibleUpdates.isEmpty && r.http.requested.isEmpty)
    }

    @Test func nonHttpFeedsAreNotFetched() async {
        let r = URig()
        _ = r.sparkleApp("Local", feed: "file:///etc/passwd")
        _ = r.sparkleApp("Weird", feed: "ftp://x/y")
        await r.service.check()
        #expect(r.http.requested.isEmpty && r.service.report.withoutSource == 2)
    }

    @Test func storeAppWithoutMasUsesThePublicCatalog() async {
        let r = URig()
        let app = mgrApp("Thing", short: "1.0", build: "10", receipt: true)
        r.catalog.apps = [app]
        r.http.set(lookupBase + "org.test.thing&country=ru&entity=macSoftware", lookupJSON(version: "1.1"))
        await r.service.check()
        let u = r.service.visibleUpdates
        #expect(u.count == 1 && u[0].source == .appStore && u[0].newVersion == "1.1" && u[0].action == .appStore(id: 12345, masAvailable: false))
        #expect(u[0].downloadURL?.host == "apps.apple.com" && u[0].notesText == "Fixes")
    }

    @Test func storeAppRespectsTheMinimumSystem() async {
        let r = URig(os: "12.0.0")
        r.catalog.apps = [mgrApp("Thing", short: "1.0", receipt: true)]
        r.http.set(lookupBase + "org.test.thing&country=ru&entity=macSoftware", lookupJSON(version: "1.1", minOS: "14.0"))
        await r.service.check()
        #expect(r.service.visibleUpdates.isEmpty)
    }

    @Test func storeSwitchOffSkipsStoreApps() async {
        var s = AppUpdateSettings()
        s.includeAppStore = false
        let r = URig(settings: s)
        r.catalog.apps = [mgrApp("Thing", short: "1.0", receipt: true)]
        await r.service.check()
        #expect(r.http.requested.isEmpty && r.service.visibleUpdates.isEmpty)
    }

    @Test func masTakesOverStoreAppsWhenInstalled() async {
        let r = URig(mas: true)
        r.catalog.apps = [mgrApp("Keynote", short: "13.1", receipt: true), mgrApp("Numbers", short: "13.1", receipt: true)]
        r.runner.on("outdated", out: "409183694 Keynote (13.1 -> 14.0)\n")
        await r.service.check()
        let u = r.service.visibleUpdates
        #expect(u.count == 1 && u[0].app.name == "Keynote" && u[0].newVersion == "14.0" && u[0].action == .appStore(id: 409183694, masAvailable: true))
        #expect(r.http.requested.isEmpty)
    }

    @Test func brewCaskOutdatedBecomesAnUpdate() async {
        let r = URig(withCasks: true)
        let app = mgrApp("Firefox", short: "129.0", build: "1", feed: feedURL)
        r.catalog.apps = [app]
        r.casks.installed = [BrewPackage(name: "firefox", kind: .cask, homepage: "https://mozilla.org", installedVersion: "129.0", appNames: ["Firefox.app"])]
        r.casks.outdated = [BrewOutdatedItem(name: "firefox", kind: .cask, installedVersions: ["129.0"], currentVersion: "130.0")]
        await r.service.check()
        let u = r.service.visibleUpdates
        #expect(u.count == 1 && u[0].source == .homebrewCask && u[0].action == .brewCask(token: "firefox") && u[0].newVersion == "130.0" && u[0].installedVersion == "129.0")
        #expect(r.http.requested.isEmpty)
    }

    @Test func caskThatUpdatesItselfFallsBackToItsFeed() async {
        let r = URig(withCasks: true)
        r.catalog.apps = [mgrApp("Slack", short: "4.0", build: "40", feed: feedURL)]
        r.casks.installed = [BrewPackage(name: "slack", kind: .cask, installedVersion: "4.0", autoUpdates: true, appNames: ["Slack.app"])]
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "50", short: "5.0")))
        await r.service.check()
        #expect(r.service.visibleUpdates.first?.source == .sparkle)
    }

    @Test func caskWithoutNewVersionIsFine() async {
        let r = URig(withCasks: true)
        r.catalog.apps = [mgrApp("Firefox", short: "130.0")]
        r.casks.installed = [BrewPackage(name: "firefox", kind: .cask, installedVersion: "130.0", appNames: ["Firefox.app"])]
        await r.service.check()
        #expect(r.service.visibleUpdates.isEmpty && r.service.report.checked == 1)
    }

    @Test func criticalUpdatesSortFirst() async {
        let r = URig()
        _ = r.sparkleApp("Zeta", feed: "https://z.example/a.xml")
        _ = r.sparkleApp("Alpha", feed: "https://a.example/a.xml")
        r.http.set("https://z.example/a.xml", mgrAppcast(mgrItem(version: "900", short: "9", extra: "<sparkle:tags><sparkle:criticalUpdate/></sparkle:tags>")))
        r.http.set("https://a.example/a.xml", mgrAppcast(mgrItem(version: "900", short: "9")))
        await r.service.check()
        #expect(r.service.visibleUpdates.map(\.app.name) == ["Zeta", "Alpha"])
    }

    @Test func manyAppsAreAllChecked() async {
        let r = URig()
        for i in 0..<25 {
            _ = r.sparkleApp("App\(i)", feed: "https://h\(i).example/a.xml")
            r.http.set("https://h\(i).example/a.xml", mgrAppcast(mgrItem(version: "999", short: "9.9")))
        }
        await r.service.check()
        #expect(r.service.visibleUpdates.count == 25 && r.http.requested.count == 25)
    }

    @Test func secondCheckReplacesTheFirstReport() async {
        let r = URig()
        _ = r.sparkleApp("Thing")
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "500", short: "5.0")))
        await r.service.check()
        #expect(r.service.visibleUpdates.count == 1)
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "100", short: "1.0")))
        await r.service.check()
        #expect(r.service.visibleUpdates.isEmpty)
    }
}

@MainActor @Suite struct AppUpdateActionsTests {
    private func updated(_ r: URig) async -> AppUpdate {
        _ = r.sparkleApp("Thing")
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "500", short: "5.0")))
        await r.service.check()
        return r.service.visibleUpdates[0]
    }

    @Test func skippingAVersionHidesOnlyThatVersion() async {
        let r = URig()
        let u = await updated(r)
        r.service.skip(u)
        #expect(r.service.visibleUpdates.isEmpty)
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "600", short: "6.0")))
        await r.service.check()
        #expect(r.service.visibleUpdates.first?.newVersion == "6.0")
    }

    @Test func ignoringAnAppHidesItUntilRestored() async {
        let r = URig()
        let u = await updated(r)
        r.service.ignoreApp(u.app.bundleId)
        #expect(r.service.visibleUpdates.isEmpty && r.service.ignoredBundleIds == ["org.test.thing"])
        r.service.unignoreApp(u.app.bundleId)
        #expect(r.service.visibleUpdates.count == 1 && r.service.ignoredBundleIds.isEmpty)
    }

    @Test func notificationsFireOncePerVersion() async {
        let r = URig()
        let u = await updated(r)
        let first = r.service.unreportedForNotification()
        #expect(first == [u])
        r.service.markNotified(first)
        #expect(r.service.unreportedForNotification().isEmpty)
        r.http.set(feedURL, mgrAppcast(mgrItem(version: "600", short: "6.0")))
        await r.service.check()
        #expect(r.service.unreportedForNotification().count == 1)
    }

    @Test func notificationsCanBeSwitchedOff() async {
        var s = AppUpdateSettings()
        s.notifyNew = false
        let r = URig(settings: s)
        _ = await updated(r)
        #expect(r.service.unreportedForNotification().isEmpty)
    }

    @Test func notificationText() async {
        let r = URig()
        let u = await updated(r)
        let one = AppUpdateService.notificationText(for: [u])
        #expect(one?.title == "Вышло обновление" && one?.body == "Thing 5.0")
        let many = AppUpdateService.notificationText(for: Array(repeating: u, count: 6))
        #expect(many?.title == "Вышло обновлений: 6" && many?.body.hasSuffix("и ещё 2") == true)
        #expect(AppUpdateService.notificationText(for: []) == nil)
    }

    @Test func scheduleFollowsTheInterval() async {
        var s = AppUpdateSettings()
        s.checkIntervalHours = 24
        let r = URig(settings: s)
        #expect(r.service.isDue)
        await r.service.check()
        #expect(!r.service.isDue)
        r.clock.advance(23 * 3600)
        #expect(!r.service.isDue)
        r.clock.advance(2 * 3600)
        #expect(r.service.isDue)
        r.service.settings.checkIntervalHours = 0
        #expect(!r.service.isDue)
    }

    @Test func installingACaskGoesThroughHomebrew() {
        let r = URig()
        let u = AppUpdate(app: mgrApp("Firefox"), source: .homebrewCask, installedVersion: "1", newVersion: "2", notesURL: nil, notesText: nil, downloadURL: nil, minimumOS: nil, published: nil, critical: false, action: .brewCask(token: "firefox"))
        #expect(r.service.install(u) == .queued(jobId: 7) && r.installer.casks == ["firefox"])
        r.installer.jobId = nil
        #expect(r.service.install(u) == .unavailable("Homebrew недоступен"))
    }

    @Test func installingFromTheSiteOpensTheDownload() async {
        let r = URig()
        let u = await updated(r)
        #expect(r.service.install(u) == .opened && r.installer.urls == [URL(string: "https://example.com/app.zip")!])
        r.service.openInOwnUpdater(u)
        #expect(r.installer.opened == ["/Applications/Thing.app"])
    }

    @Test func sparkleWithoutADownloadOpensTheApp() {
        let r = URig()
        let u = AppUpdate(app: mgrApp("Thing"), source: .sparkle, installedVersion: "1", newVersion: "2", notesURL: nil, notesText: nil, downloadURL: nil, minimumOS: nil, published: nil, critical: false, action: .sparkle(appPath: "/Applications/Thing.app", download: nil))
        #expect(r.service.install(u) == .opened && r.installer.opened == ["/Applications/Thing.app"])
    }

    @Test func storeUpdateWithoutMasOpensTheAppStore() {
        let r = URig()
        let page = URL(string: "https://apps.apple.com/app/id55")!
        let u = AppUpdate(app: mgrApp("Thing", receipt: true), source: .appStore, installedVersion: "1", newVersion: "2", notesURL: nil, notesText: nil, downloadURL: page, minimumOS: nil, published: nil, critical: false, action: .appStore(id: 55, masAvailable: false))
        #expect(r.service.install(u) == .opened && r.installer.urls == [page])
        var bare = u
        bare.downloadURL = nil
        bare.action = .appStore(id: 0, masAvailable: false)
        #expect(r.service.install(bare) == .unavailable("Нет ссылки на App Store"))
    }

    @Test func storeUpdateWithMasRunsAJob() async {
        let r = URig(mas: true)
        r.runner.on("upgrade 55", out: "==> Downloading Thing\n==> Installed Thing")
        let u = AppUpdate(app: mgrApp("Thing", receipt: true), source: .appStore, installedVersion: "1", newVersion: "2", notesURL: nil, notesText: nil, downloadURL: nil, minimumOS: nil, published: nil, critical: false, action: .appStore(id: 55, masAvailable: true))
        guard case .queued(let id) = r.service.install(u) else { Issue.record("expected a job"); return }
        await r.service.queue.waitUntilIdle()
        #expect(r.service.queue.job(id)?.state == .succeeded && r.runner.argLines == ["upgrade 55"])
        #expect(r.runner.calls[0].executable == "/opt/homebrew/bin/mas")
    }

    @Test func masFailureIsShown() async {
        let r = URig(mas: true)
        r.runner.on("upgrade", status: 1, err: "Error: Not signed in")
        let u = AppUpdate(app: mgrApp("Thing", receipt: true), source: .appStore, installedVersion: "1", newVersion: "2", notesURL: nil, notesText: nil, downloadURL: nil, minimumOS: nil, published: nil, critical: false, action: .appStore(id: 55, masAvailable: true))
        guard case .queued(let id) = r.service.install(u) else { Issue.record("expected a job"); return }
        await r.service.queue.waitUntilIdle()
        if case .failed(let m)? = r.service.queue.job(id)?.state { #expect(m.contains("Not signed in")) } else { Issue.record("expected failure") }
    }

    @Test func installerMissingMeansUnavailableForCasks() {
        let r = URig()
        r.service.installer = nil
        let u = AppUpdate(app: mgrApp("Firefox"), source: .homebrewCask, installedVersion: "1", newVersion: "2", notesURL: nil, notesText: nil, downloadURL: nil, minimumOS: nil, published: nil, critical: false, action: .brewCask(token: "firefox"))
        #expect(r.service.install(u) == .unavailable("Homebrew недоступен"))
    }
}
