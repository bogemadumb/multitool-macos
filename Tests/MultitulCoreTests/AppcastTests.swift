import Testing
import Foundation
@testable import MultitulCore

private let fullFeed = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
 <channel>
  <title>Example Changelog</title>
  <link>https://example.com</link>
  <description>Most recent changes</description>
  <item>
   <title>Version 2.1</title>
   <sparkle:releaseNotesLink>https://example.com/notes/2.1.html</sparkle:releaseNotesLink>
   <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
   <pubDate>Tue, 07 Oct 2025 10:30:00 +0000</pubDate>
   <description><![CDATA[<h2>What's new</h2><ul><li>Faster</li></ul>]]></description>
   <enclosure url="https://example.com/dl/App-2.1.zip" sparkle:version="2100" sparkle:shortVersionString="2.1" length="12345678" type="application/octet-stream" sparkle:edSignature="abc=="/>
   <sparkle:deltas>
     <enclosure url="https://example.com/dl/App2.1-2.0.delta" sparkle:version="2100" sparkle:deltaFrom="2000" length="1000" type="application/octet-stream"/>
   </sparkle:deltas>
  </item>
  <item>
   <title>Version 2.0</title>
   <pubDate>Mon, 01 Sep 2025 09:00:00 +0000</pubDate>
   <sparkle:version>2000</sparkle:version>
   <sparkle:shortVersionString>2.0</sparkle:shortVersionString>
   <enclosure url="https://example.com/dl/App-2.0.zip" length="11111111" type="application/octet-stream"/>
  </item>
  <item>
   <title>Version 2.2 beta</title>
   <sparkle:channel>beta</sparkle:channel>
   <enclosure url="https://example.com/dl/App-2.2b.zip" sparkle:version="2201" sparkle:shortVersionString="2.2b1" length="1" type="application/octet-stream"/>
  </item>
 </channel>
</rss>
"""

@Suite struct AppcastParserTests {
    @Test func parsesTheFullSparkleItem() throws {
        let items = try AppcastParser.parse(fullFeed)
        #expect(items.count == 3)
        let a = items[0]
        #expect(a.title == "Version 2.1" && a.version == "2100" && a.shortVersion == "2.1" && a.displayVersion == "2.1" && a.comparableVersion == "2100")
        #expect(a.downloadURL?.absoluteString == "https://example.com/dl/App-2.1.zip" && a.length == 12_345_678 && a.mimeType == "application/octet-stream")
        #expect(a.minimumSystemVersion == "13.0" && a.releaseNotesURL?.absoluteString == "https://example.com/notes/2.1.html")
        #expect(a.descriptionHTML == "<h2>What's new</h2><ul><li>Faster</li></ul>")
        #expect(!a.isCritical && a.channel == nil)
    }

    @Test func publicationDateIsRead() throws {
        let a = try #require(try AppcastParser.parse(fullFeed).first)
        let d = try #require(a.pubDate)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        #expect(c.year == 2025 && c.month == 10 && c.day == 7 && c.hour == 10 && c.minute == 30)
    }

    @Test func versionsAsElementsInsteadOfAttributes() throws {
        let b = try AppcastParser.parse(fullFeed)[1]
        #expect(b.version == "2000" && b.shortVersion == "2.0" && b.downloadURL?.lastPathComponent == "App-2.0.zip")
    }

    @Test func deltaEnclosuresNeverReplaceTheFullDownload() throws {
        let a = try AppcastParser.parse(fullFeed)[0]
        #expect(a.downloadURL?.pathExtension == "zip" && a.length == 12_345_678)
    }

    @Test func channelIsRecorded() throws {
        #expect(try AppcastParser.parse(fullFeed)[2].channel == "beta")
    }

    @Test func criticalUpdateMarker() throws {
        let feed = mgrAppcast(mgrItem(version: "5", extra: "<sparkle:tags><sparkle:criticalUpdate/></sparkle:tags>"))
        #expect(try AppcastParser.parse(feed).first?.isCritical == true)
    }

    @Test func osAndMaximumSystemVersion() throws {
        let feed = mgrAppcast(mgrItem(version: "5", extra: "<sparkle:maximumSystemVersion>12.7</sparkle:maximumSystemVersion>") + """
        <item><enclosure url="https://x/win.exe" sparkle:version="9" sparkle:os="windows" length="1" type="a/b"/></item>
        """)
        let items = try AppcastParser.parse(feed)
        #expect(items[0].maximumSystemVersion == "12.7" && items[1].os == "windows")
    }

    @Test func emptyFeedIsAnEmptyList() throws {
        #expect(try AppcastParser.parse(mgrAppcast("")).isEmpty)
    }

    @Test func malformedXmlThrows() {
        #expect(throws: AppcastError.self) { try AppcastParser.parse("<rss><channel><item><title>x</item>") }
        #expect(throws: AppcastError.self) { try AppcastParser.parse("") }
        #expect(throws: AppcastError.self) { try AppcastParser.parse("<html><body>404 Not Found") }
    }

    @Test func itemsKeepFeedOrder() throws {
        let feed = mgrAppcast(mgrItem(version: "3", short: "1.3") + mgrItem(version: "2", short: "1.2") + mgrItem(version: "1", short: "1.1"))
        #expect(try AppcastParser.parse(feed).map(\.version) == ["3", "2", "1"])
    }

    @Test func dateFormats() {
        #expect(AppcastParser.date("Tue, 07 Oct 2025 10:30:00 +0000") != nil)
        #expect(AppcastParser.date("Tue, 07 Oct 2025 10:30:00 GMT") != nil)
        #expect(AppcastParser.date("2025-10-07T10:30:00+03:00") != nil)
        #expect(AppcastParser.date("yesterday") == nil)
    }

    @Test func linkOnlyItemsAreKept() throws {
        let feed = mgrAppcast("<item><title>v7</title><link>https://example.com/dl</link><sparkle:version>7</sparkle:version></item>")
        let a = try #require(try AppcastParser.parse(feed).first)
        #expect(a.link?.absoluteString == "https://example.com/dl" && a.downloadURL == nil)
    }
}

@Suite struct AppcastSelectionTests {
    private func items() throws -> [AppcastItem] { try AppcastParser.parse(fullFeed) }

    @Test func picksTheHighestStableVersion() throws {
        #expect(AppcastSelector.latest(try items(), osVersion: "14.5")?.displayVersion == "2.1")
    }

    @Test func orderInTheFeedDoesNotMatter() throws {
        let rev = Array(try items().reversed())
        #expect(AppcastSelector.latest(rev, osVersion: "14.5")?.displayVersion == "2.1")
    }

    @Test func channelsAreOptIn() throws {
        #expect(AppcastSelector.latest(try items(), osVersion: "14.5", allowedChannels: ["beta"], includePrerelease: true)?.displayVersion == "2.2b1")
        #expect(AppcastSelector.latest(try items(), osVersion: "14.5", allowedChannels: ["beta"], includePrerelease: false)?.displayVersion == "2.1")
        #expect(AppcastSelector.latest(try items(), osVersion: "14.5", allowedChannels: ["nightly"])?.displayVersion == "2.1")
    }

    @Test func minimumSystemVersionFiltersOutNewerReleases() throws {
        #expect(AppcastSelector.latest(try items(), osVersion: "12.6")?.displayVersion == "2.0")
        #expect(AppcastSelector.latest(try items(), osVersion: "13.0")?.displayVersion == "2.1")
    }

    @Test func maximumSystemVersionFiltersOutOldReleases() {
        var a = AppcastItem()
        a.version = "9"
        a.downloadURL = URL(string: "https://x/y.zip")
        a.maximumSystemVersion = "12.7"
        #expect(AppcastSelector.latest([a], osVersion: "14.0") == nil && AppcastSelector.latest([a], osVersion: "12.3") != nil)
    }

    @Test func foreignPlatformsAndBrokenItemsAreSkipped() {
        var win = AppcastItem(), none = AppcastItem(), mac = AppcastItem()
        win.version = "9"; win.os = "windows"; win.downloadURL = URL(string: "https://x/a.exe")
        none.version = "8"
        mac.version = "7"; mac.os = "macos"; mac.downloadURL = URL(string: "https://x/a.zip")
        #expect(AppcastSelector.latest([win, none, mac], osVersion: "14.0")?.version == "7")
        #expect(AppcastSelector.latest([], osVersion: "14.0") == nil)
    }

    @Test func prereleaseVersionsNeedTheSwitch() {
        var rc = AppcastItem(), ok = AppcastItem()
        rc.version = "300"; rc.shortVersion = "3.0rc1"; rc.downloadURL = URL(string: "https://x/rc.zip")
        ok.version = "200"; ok.shortVersion = "2.9"; ok.downloadURL = URL(string: "https://x/ok.zip")
        #expect(AppcastSelector.latest([rc, ok], osVersion: "14.0")?.shortVersion == "2.9")
        #expect(AppcastSelector.latest([rc, ok], osVersion: "14.0", includePrerelease: true)?.shortVersion == "3.0rc1")
    }
}

@Suite struct UpdateDecisionTests {
    private func item(_ build: String?, _ short: String?) -> AppcastItem {
        var i = AppcastItem()
        i.version = build
        i.shortVersion = short
        return i
    }

    @Test func newerBuildWins() {
        #expect(UpdateDecision.isNewer(item("2100", "2.1"), installedBuild: "2000", installedShort: "2.0"))
    }

    @Test func sameBuildIsNotAnUpdate() {
        #expect(!UpdateDecision.isNewer(item("2000", "2.0"), installedBuild: "2000", installedShort: "2.0"))
    }

    @Test func olderFeedIsNotAnUpdate() {
        #expect(!UpdateDecision.isNewer(item("1900", "1.9"), installedBuild: "2000", installedShort: "2.0"))
    }

    @Test func marketingVersionInTheVersionAttribute() {
        #expect(UpdateDecision.isNewer(item("1.5.0", nil), installedBuild: "150", installedShort: "1.4.0"))
        #expect(!UpdateDecision.isNewer(item("1.5.0", nil), installedBuild: "150", installedShort: "1.5.0"))
    }

    @Test func feedWithOnlyAShortVersion() {
        #expect(UpdateDecision.isNewer(item(nil, "3.2"), installedBuild: "9", installedShort: "3.1"))
        #expect(!UpdateDecision.isNewer(item(nil, "3.1"), installedBuild: "9", installedShort: "3.1"))
    }

    @Test func betaToStableOfTheSameNumber() {
        #expect(UpdateDecision.isNewer(item("1.5", "1.5"), installedBuild: "1.5b3", installedShort: "1.5b3"))
        #expect(!UpdateDecision.isNewer(item("1.5b3", "1.5b3"), installedBuild: "1.5", installedShort: "1.5"))
    }

    @Test func missingInstalledVersionsNeverReportUpdates() {
        #expect(!UpdateDecision.isNewer(item("5", "5.0"), installedBuild: "", installedShort: ""))
    }
}
