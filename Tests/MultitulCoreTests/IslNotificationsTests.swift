import Testing
import Foundation
@testable import MultitulCore

private typealias F = ExtFix

private func item(_ id: String, app: String = "com.apple.MobileSMS", title: String = "Анна", body: String = "Привет", subtitle: String = "", at: TimeInterval = 0) -> IslNtfItem {
    IslNtfItem(id: id, bundleID: app, appName: "Сообщения", title: title, subtitle: subtitle, body: body, date: F.at(at))
}

struct IslNtfRow {
    var id: Int64
    var app: String?
    var title = ""
    var subtitle = ""
    var body = ""
    var delivered: Double = 780_000_000
    var rawBlob: Data?
}

final class IslNtfFixture {
    let dir: String
    let path: String
    private let store: Store

    init(apps: [String] = ["com.apple.MobileSMS", "ru.keepcoder.Telegram"], rows: [IslNtfRow] = []) throws {
        dir = NSTemporaryDirectory() + "multitul-ntf-fixture-\(UUID().uuidString)"
        path = dir + "/db"
        store = try Store(path: path, migrations: [Migration(scope: "ntf", version: 1, name: "fixture", sql: """
            CREATE TABLE app(app_id INTEGER PRIMARY KEY, identifier VARCHAR);
            CREATE TABLE record(rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL, request_last_date REAL, delivered_date REAL, presented INTEGER, style INTEGER, snooze_fire_date REAL);
            """)], retention: [])
        for (i, a) in apps.enumerated() { try store.run("INSERT INTO app(app_id, identifier) VALUES(?, ?)", [.int(Int64(i + 1)), .text(a)]) }
        for r in rows { try add(r) }
    }

    func blob(_ r: IslNtfRow) -> Data {
        let dict: [String: Any] = ["app": r.app ?? "", "req": ["titl": r.title, "subt": r.subtitle, "body": r.body, "iden": "x\(r.id)"] as [String: Any]]
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    func add(_ r: IslNtfRow) throws {
        let appID = r.app.flatMap { name in try? store.scalarInt("SELECT app_id FROM app WHERE identifier = ?", [.text(name)]) } ?? nil
        try store.run("INSERT INTO record(rec_id, app_id, data, delivered_date) VALUES(?, ?, ?, ?)",
                      [.int(r.id), appID.map { .int($0) } ?? .null, .blob(r.rawBlob ?? blob(r)), .real(r.delivered)])
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
}

@Suite struct IslNtfPlistTests {
    private func blob(_ dict: [String: Any]) -> Data { try! PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0) }

    @Test func requestFieldsBecomeAnItem() {
        let d = blob(["app": "com.apple.mail", "req": ["titl": "Письмо", "subt": "Иван", "body": "Текст"]])
        let i = IslNtfPlist.item(from: d, recID: 5, bundleID: nil, delivered: 780_000_000)
        #expect(i?.id == "rec-5" && i?.title == "Письмо" && i?.subtitle == "Иван" && i?.body == "Текст" && i?.bundleID == "com.apple.mail")
        #expect(i?.date == Date(timeIntervalSinceReferenceDate: 780_000_000))
    }

    @Test func tableBundleWinsOverTheBlobBundle() {
        let d = blob(["app": "blob.id", "req": ["body": "x"]])
        #expect(IslNtfPlist.item(from: d, recID: 1, bundleID: "table.id", delivered: nil)?.bundleID == "table.id")
        #expect(IslNtfPlist.item(from: d, recID: 1, bundleID: "", delivered: nil)?.bundleID == "blob.id")
    }

    @Test func fieldsAreTrimmed() {
        let d = blob(["req": ["titl": "  A  ", "body": "\nB\n"]])
        let i = IslNtfPlist.item(from: d, recID: 1, bundleID: "x", delivered: nil)
        #expect(i?.title == "A" && i?.body == "B")
    }

    @Test func emptyNotificationIsDropped() {
        #expect(IslNtfPlist.item(from: blob(["req": ["titl": " ", "body": ""]]), recID: 1, bundleID: "x", delivered: nil) == nil)
    }

    @Test func topLevelFieldsAreUsedWhenThereIsNoRequestDictionary() {
        let i = IslNtfPlist.item(from: blob(["titl": "T", "body": "B"]), recID: 1, bundleID: "x", delivered: nil)
        #expect(i?.title == "T")
    }

    @Test func nonPlistDataIsRejected() {
        #expect(IslNtfPlist.item(from: Data("nope".utf8), recID: 1, bundleID: "x", delivered: nil) == nil)
    }

    @Test func missingDeliveryDateFallsBackToTheBlobDate() {
        let when = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let i = IslNtfPlist.item(from: blob(["date": when, "req": ["body": "x"]]), recID: 1, bundleID: "a", delivered: nil)
        #expect(i?.date == when)
    }
}

@Suite struct IslNtfDBReaderTests {
    private func reader(_ f: IslNtfFixture, copy: Bool) -> IslNtfDBReader {
        IslNtfDBReader(path: f.path, copyFirst: copy, scratchDir: f.dir + "/scratch")
    }

    @Test func primeSkipsExistingRecordsAndPollSeesOnlyNewOnes() throws {
        let f = try IslNtfFixture(rows: [IslNtfRow(id: 1, app: "com.apple.MobileSMS", title: "Old", body: "x"), IslNtfRow(id: 2, app: "com.apple.MobileSMS", title: "Old2", body: "y")])
        defer { f.cleanup() }
        let r = reader(f, copy: true)
        r.prime()
        #expect(r.poll().isEmpty)
        try f.add(IslNtfRow(id: 3, app: "ru.keepcoder.Telegram", title: "Новый", body: "Привет"))
        let got = r.poll()
        #expect(got.count == 1 && got[0].title == "Новый" && got[0].bundleID == "ru.keepcoder.Telegram" && got[0].id == "rec-3" && got[0].appName == "Telegram")
        #expect(r.poll().isEmpty && r.health == .ok)
    }

    @Test func recordsArriveInOrder() throws {
        let f = try IslNtfFixture()
        defer { f.cleanup() }
        let r = reader(f, copy: true)
        r.prime()
        try f.add(IslNtfRow(id: 10, app: "com.apple.MobileSMS", title: "A", body: "1"))
        try f.add(IslNtfRow(id: 11, app: "com.apple.MobileSMS", title: "B", body: "2"))
        #expect(r.poll().map(\.title) == ["A", "B"])
    }

    @Test func readOnlyModeReadsTheFixtureDirectly() throws {
        let f = try IslNtfFixture(rows: [IslNtfRow(id: 1, app: "com.apple.MobileSMS", title: "A", body: "x")])
        defer { f.cleanup() }
        let r = reader(f, copy: false)
        #expect(r.poll().count == 1 && r.health == .ok)
    }

    @Test func recordsWithoutAnAppRowUseTheBlobBundle() throws {
        let f = try IslNtfFixture(rows: [IslNtfRow(id: 1, app: nil, title: "A", body: "x")])
        defer { f.cleanup() }
        let got = reader(f, copy: true).poll()
        #expect(got.count == 1 && got[0].bundleID == "")
    }

    @Test func brokenBlobsAreSkippedWithoutStoppingTheBatch() throws {
        let f = try IslNtfFixture(rows: [IslNtfRow(id: 1, app: "com.apple.MobileSMS", rawBlob: Data("junk".utf8)), IslNtfRow(id: 2, app: "com.apple.MobileSMS", title: "ok", body: "x")])
        defer { f.cleanup() }
        let r = reader(f, copy: true)
        #expect(r.poll().map(\.title) == ["ok"])
        #expect(r.poll().isEmpty)
    }

    @Test func missingDatabaseIsReported() {
        let r = IslNtfDBReader(path: NSTemporaryDirectory() + "no-such-\(UUID().uuidString)/db", copyFirst: true)
        #expect(r.poll().isEmpty && r.health == .missing)
    }

    @Test func foreignSchemaIsAFailureNotACrash() throws {
        let dir = NSTemporaryDirectory() + "multitul-ntf-bad-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try Store(path: dir + "/db", migrations: [Migration(scope: "x", version: 1, name: "x", sql: "CREATE TABLE other(a INTEGER);")], retention: [])
        _ = s
        let r = IslNtfDBReader(path: dir + "/db", copyFirst: true, scratchDir: dir + "/scratch")
        #expect(r.poll().isEmpty)
        if case .failed = r.health {} else { Issue.record("expected failure, got \(r.health)") }
    }

    @Test func copyModeLeavesNoScratchFilesBehind() throws {
        let f = try IslNtfFixture(rows: [IslNtfRow(id: 1, app: "com.apple.MobileSMS", title: "A", body: "x")])
        defer { f.cleanup() }
        let r = reader(f, copy: true)
        _ = r.poll()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: f.dir + "/scratch")) ?? []
        #expect(left.isEmpty)
    }

    @Test func candidatePathsAreUnderTheUserLibrary() {
        #expect(IslNtfDBReader.defaultPath(home: "/Users/x", exists: { _ in false }) == nil)
        #expect(IslNtfDBReader.defaultPath(home: "/Users/x", exists: { $0.contains("usernoted") }) == "/Users/x/Library/Group Containers/group.com.apple.usernoted/db2/db")
        #expect(IslNtfDBReader.candidatePaths.allSatisfy { $0.hasPrefix("Library/") })
    }
}

@Suite struct IslNtfCenterTests {
    private let s = IslNtfSettings()

    @Test func newItemsComeFirstAndBecomeTheLatest() {
        var c = IslNtfCenter()
        let added = c.ingest([item("a"), item("b", title: "Борис")], now: F.now, settings: s)
        #expect(added.count == 2 && c.items.first?.id == "b" && c.latest?.id == "b")
    }

    @Test func sameIdentifierIsNotAddedTwice() {
        var c = IslNtfCenter()
        _ = c.ingest([item("a")], now: F.now, settings: s)
        #expect(c.ingest([item("a")], now: F.at(100), settings: s).isEmpty && c.items.count == 1)
    }

    @Test func identicalTextWithinTheWindowIsDeduplicated() {
        var c = IslNtfCenter()
        _ = c.ingest([item("a")], now: F.now, settings: s)
        #expect(c.ingest([item("b")], now: F.at(5), settings: s).isEmpty)
        #expect(c.ingest([item("c")], now: F.at(11), settings: s).count == 1)
    }

    @Test func dedupeCanBeSwitchedOff() {
        var c = IslNtfCenter()
        var off = s
        off.dedupeSeconds = 0
        _ = c.ingest([item("a")], now: F.now, settings: off)
        #expect(c.ingest([item("b")], now: F.at(1), settings: off).count == 1)
    }

    @Test func differentAppsWithTheSameTextAreNotDuplicates() {
        var c = IslNtfCenter()
        let added = c.ingest([item("a", app: "x.one"), item("b", app: "x.two")], now: F.now, settings: s)
        #expect(added.count == 2)
    }

    @Test func dedupeIgnoresCaseAndSpacing() {
        var c = IslNtfCenter()
        _ = c.ingest([item("a", body: "Hello   World")], now: F.now, settings: s)
        #expect(c.ingest([item("b", body: "hello world")], now: F.at(2), settings: s).isEmpty)
    }

    @Test func hiddenAppsAreFiltered() {
        var c = IslNtfCenter()
        var h = s
        h.hiddenApps = ["x.noisy"]
        #expect(c.ingest([item("a", app: "x.noisy")], now: F.now, settings: h).isEmpty && c.items.isEmpty)
    }

    @Test func ownNotificationsAreFiltered() {
        var c = IslNtfCenter()
        #expect(c.ingest([item("a", app: "dev.multitool.app")], now: F.now, settings: s).isEmpty)
    }

    @Test func emptyNotificationsAreFiltered() {
        var c = IslNtfCenter()
        #expect(c.ingest([item("a", title: "", body: "")], now: F.now, settings: s).isEmpty)
    }

    @Test func capacityDropsTheOldest() {
        var c = IslNtfCenter()
        var cap = s
        cap.maxItems = 5
        for i in 0..<8 { _ = c.ingest([item("n\(i)", body: "text \(i)")], now: F.at(Double(i * 20)), settings: cap) }
        #expect(c.items.count == 5 && c.items.first?.id == "n7" && c.items.last?.id == "n3")
    }

    @Test func clearingEmptiesEverythingIncludingDedupeMemory() {
        var c = IslNtfCenter()
        _ = c.ingest([item("a")], now: F.now, settings: s)
        c.clear()
        #expect(c.items.isEmpty && c.latest == nil)
        #expect(c.ingest([item("b")], now: F.at(1), settings: s).count == 1)
    }

    @Test func removeDropsOneItemAndTheLatestMarker() {
        var c = IslNtfCenter()
        _ = c.ingest([item("a"), item("b", body: "other")], now: F.now, settings: s)
        c.remove("b")
        #expect(c.items.map(\.id) == ["a"] && c.latest == nil)
    }

    @Test func activityLivesForTheConfiguredSeconds() {
        var c = IslNtfCenter()
        _ = c.ingest([item("a")], now: F.now, settings: s)
        let a = c.activity(now: F.at(5), settings: s)
        #expect(a?.priority == IslPriority.notification && a?.peeks == true && a?.title == "Анна" && a?.token == "a")
        #expect(c.activity(now: F.at(6.1), settings: s) == nil)
        var long = s
        long.activityLifetime = 12
        #expect(c.activity(now: F.at(11), settings: long) != nil)
    }

    @Test func eachNewNotificationChangesTheToken() {
        var c = IslNtfCenter()
        _ = c.ingest([item("a")], now: F.now, settings: s)
        let t1 = c.activity(now: F.at(1), settings: s)?.token
        _ = c.ingest([item("b", body: "different")], now: F.at(2), settings: s)
        #expect(c.activity(now: F.at(3), settings: s)?.token != t1)
    }

    @Test func groupingKeepsAppOrderByRecency() {
        var c = IslNtfCenter()
        _ = c.ingest([item("a", app: "x.one", body: "1"), item("b", app: "x.two", body: "2"), item("c", app: "x.one", body: "3")], now: F.now, settings: s)
        let g = c.grouped()
        #expect(g.map(\.bundleID) == ["x.one", "x.two"] && g[0].items.map(\.id) == ["c", "a"])
    }

    @Test func notificationBeatsMusicButNotATimer() {
        var c = IslNtfCenter()
        _ = c.ingest([item("a")], now: IslFix.at(0), settings: s)
        let n = c.activity(now: IslFix.at(1), settings: s)!
        var one = IslArbiter()
        #expect(one.resolve([IslFix.activity("music", "music", priority: IslPriority.music), n], now: IslFix.at(1)).winner?.id == "notification")
        var two = IslArbiter()
        #expect(two.resolve([IslFix.activity("timer", "timer", priority: IslPriority.timer), n], now: IslFix.at(1)).winner?.id == "timer")
    }

    @Test func itemTextHelpers() {
        let i = item("a", title: "", body: "Тело", subtitle: "Подзаголовок")
        #expect(i.headline == "Сообщения" && i.detail == "Подзаголовок · Тело")
        #expect(item("b", app: "x", title: "T", body: "line1\nline2").detail == "line1 line2")
    }
}

@Suite struct IslNtfBannerTests {
    private func parse(_ t: [String], app: String = "Сообщения") -> IslNtfItem? {
        IslNtfBannerParser.item(texts: t, appName: app, bundleID: "com.apple.MobileSMS", now: F.now, counter: 1)
    }

    @Test func twoTextsAreTitleAndBody() {
        let i = parse(["Анна", "Привет"])
        #expect(i?.title == "Анна" && i?.body == "Привет" && i?.subtitle == "")
    }

    @Test func threeTextsAddASubtitle() {
        let i = parse(["Чат", "Анна", "Привет"])
        #expect(i?.title == "Чат" && i?.subtitle == "Анна" && i?.body == "Привет")
    }

    @Test func aSingleTextIsTheBody() {
        let i = parse(["Просто текст"])
        #expect(i?.title == "" && i?.body == "Просто текст")
    }

    @Test func extraTextsAreMergedIntoTheBody() {
        #expect(parse(["a", "b", "c", "d"])?.body == "c d")
    }

    @Test func blankTextsAreIgnoredAndEmptyInputGivesNothing() {
        #expect(parse(["", "  "]) == nil && parse([]) == nil)
        #expect(parse(["", "Тело"])?.body == "Тело")
    }

    @Test func appNameRepeatedAsTheTitleIsDropped() {
        let i = parse(["Сообщения", "Анна", "Привет"])
        #expect(i?.title == "Анна" && i?.subtitle == "" && i?.body == "Привет")
    }

    @Test func identifiersAreUniquePerCounter() {
        let a = IslNtfBannerParser.item(texts: ["x"], appName: "A", bundleID: "b", now: F.now, counter: 1)
        let b = IslNtfBannerParser.item(texts: ["x"], appName: "A", bundleID: "b", now: F.now, counter: 2)
        #expect(a?.id != b?.id)
    }
}

@Suite struct IslNtfSettingsTests {
    @Test func defaultsWriteNothing() {
        let kv = WndMemoryStore()
        IslNtfSettingsStore(kv).save(IslNtfSettings())
        #expect(kv.values.isEmpty)
    }

    @Test func roundTripAndPrefix() {
        let kv = WndMemoryStore()
        var s = IslNtfSettings()
        s.hideSystemBanner = true
        s.maxItems = 10
        s.activityLifetime = 9
        s.dedupeSeconds = 0
        s.showBody = false
        s.source = .banners
        s.hiddenApps = ["a.b", "c.d"]
        IslNtfSettingsStore(kv).save(s)
        #expect(IslNtfSettingsStore(kv).load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("notch.notifications.") })
    }

    @Test func unknownSourceFallsBackToAuto() {
        let kv = WndMemoryStore()
        kv.set("telepathy", forKey: "notch.notifications.source")
        #expect(IslNtfSettingsStore(kv).load().source == .auto)
        #expect(IslNtfSourceChoice.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func valuesAreClamped() {
        var s = IslNtfSettings()
        s.maxItems = 1
        s.activityLifetime = 99
        s.dedupeSeconds = 9999
        let c = s.sanitized
        #expect(c.maxItems == 5 && c.activityLifetime == 30 && c.dedupeSeconds == 120)
    }
}
