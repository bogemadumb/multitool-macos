import Testing
import Foundation
@testable import MultitulCore

@Suite struct UrlCleanerTests {
    private func url(_ s: String, _ rules: UrlCleanRules = UrlCleanRules()) -> String? { UrlCleaner.clean(s, rules: rules)?.url }

    @Test func utmParametersAreRemoved() {
        #expect(url("https://example.com/page?utm_source=tw&utm_medium=cpc&utm_campaign=x&id=7") == "https://example.com/page?id=7")
    }

    @Test func utmPrefixCatchesUnlistedNames() {
        #expect(url("https://example.com/?utm_brand_new=1&a=b") == "https://example.com/?a=b")
    }

    @Test(arguments: ["fbclid", "gclid", "dclid", "msclkid", "yclid", "ysclid", "twclid", "ttclid", "igshid", "mc_cid", "mc_eid", "_openstat", "mkt_tok", "_hsenc", "wbraid", "gbraid", "li_fat_id", "mibextid"])
    func globalTrackersAreRemoved(_ name: String) {
        #expect(url("https://site.org/a?keep=1&\(name)=ABC123") == "https://site.org/a?keep=1")
    }

    @Test func allParametersTrackingMeansNoQuestionMark() {
        #expect(url("https://example.com/path?utm_source=a&fbclid=b") == "https://example.com/path")
    }

    @Test func fragmentAndOtherPartsSurviveByteForByte() {
        #expect(url("https://example.com/a/b/?x=1%202&utm_source=q#section-2") == "https://example.com/a/b/?x=1%202#section-2")
        #expect(url("HTTPS://User:pw@Example.com:8443/Path?utm_term=1") == "HTTPS://User:pw@Example.com:8443/Path")
    }

    @Test func untouchedLinkIsReturnedExactly() {
        let u = "https://example.com/search?q=привет+мир&page=2&sort=asc"
        let r = UrlCleaner.clean(u)
        #expect(r?.url == u)
        #expect(r?.changed == false)
        #expect(r?.removed == [])
    }

    @Test func parameterOrderAndRepeatedKeysAreKept() {
        #expect(url("https://example.com/?b=2&utm_source=x&a=1&b=3&a=0") == "https://example.com/?b=2&a=1&b=3&a=0")
    }

    @Test func valuelessAndEncodedNamesAreHandled() {
        #expect(url("https://example.com/?flag&utm_source&other=1") == "https://example.com/?flag&other=1")
        #expect(url("https://example.com/?utm%5Fsource=1&x=2") == "https://example.com/?x=2")
    }

    @Test func nameMatchingIsCaseInsensitive() {
        #expect(url("https://example.com/?UTM_Source=a&FBCLID=b&Id=5") == "https://example.com/?Id=5")
    }

    @Test func valuesThatMerelyContainTrackerNamesAreKept() {
        #expect(url("https://example.com/?next=utm_source%3Dx&ref=fbclid") == "https://example.com/?next=utm_source%3Dx&ref=fbclid")
    }

    @Test func removedNamesAreReportedOnce() {
        let r = UrlCleaner.clean("https://example.com/?utm_source=a&fbclid=b&utm_source=c")
        #expect(r?.removed == ["utm_source", "fbclid"])
    }

    @Test func youtubeSiGoesButTimestampStays() {
        #expect(url("https://youtu.be/dQw4w9WgXcQ?si=abc123&t=42") == "https://youtu.be/dQw4w9WgXcQ?t=42")
        #expect(url("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=zzz&feature=share&t=10") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10")
    }

    @Test func siIsNotRemovedOnUnrelatedSites() {
        #expect(url("https://shop.example.com/item?si=large") == "https://shop.example.com/item?si=large")
    }

    @Test func twitterTrackersGoOnlyOnTwitterHosts() {
        #expect(url("https://x.com/user/status/1?s=20&t=abcDEF") == "https://x.com/user/status/1")
        #expect(url("https://mobile.twitter.com/u/status/1?s=09") == "https://mobile.twitter.com/u/status/1")
        #expect(url("https://example.com/?t=5&s=6") == "https://example.com/?t=5&s=6")
    }

    @Test func spotifyAndInstagram() {
        #expect(url("https://open.spotify.com/track/1?si=abc") == "https://open.spotify.com/track/1")
        #expect(url("https://www.instagram.com/p/xyz/?igsh=MTIz&utm_source=ig_web_copy_link") == "https://www.instagram.com/p/xyz/")
    }

    @Test func amazonKeepsProductSelectionButDropsTracking() {
        #expect(url("https://www.amazon.de/dp/B0?th=1&psc=1&tag=aff-21&pd_rd_r=x&ref_=nav") == "https://www.amazon.de/dp/B0?th=1&psc=1")
        #expect(url("https://www.amazon.co.uk/dp/B0?qid=12&sr=1-2") == "https://www.amazon.co.uk/dp/B0")
    }

    @Test func googleSearchKeepsTheQuery() {
        #expect(url("https://www.google.com/search?q=swift&sxsrf=AB&ved=0x&ei=zz&sclient=gws") == "https://www.google.com/search?q=swift")
        #expect(url("https://www.google.ru/search?q=a&ved=1") == "https://www.google.ru/search?q=a")
    }

    @Test func wildcardHostDoesNotMatchLookalikes() {
        #expect(UrlCleaner.hostMatches("www.amazon.com", key: "amazon.*"))
        #expect(!UrlCleaner.hostMatches("notamazon.com", key: "amazon.*"))
        #expect(!UrlCleaner.hostMatches("amazon.evil.example.org", key: "amazon.*"))
        #expect(UrlCleaner.hostMatches("m.youtube.com", key: "youtube.com"))
        #expect(!UrlCleaner.hostMatches("myyoutube.com", key: "youtube.com"))
    }

    @Test func russianShops() {
        #expect(url("https://www.ozon.ru/product/x-123/?at=abc&_bctx=zz&sh=q&keys=1") == "https://www.ozon.ru/product/x-123/?keys=1")
        #expect(url("https://www.wildberries.ru/catalog/1/detail.aspx?targetUrl=GP&size=5") == "https://www.wildberries.ru/catalog/1/detail.aspx?size=5")
    }

    @Test func nonUrlInputIsRejected() {
        #expect(UrlCleaner.clean("") == nil)
        #expect(UrlCleaner.clean("просто текст") == nil)
        #expect(UrlCleaner.clean("https://example.com/a b") == nil)
        #expect(UrlCleaner.clean("ftp://example.com/?utm_source=1") == nil)
        #expect(UrlCleaner.clean("https://localhost/?utm_source=1") == nil)
        #expect(UrlCleaner.clean("mailto:a@b.c?utm_source=1") == nil)
        #expect(UrlCleaner.outcome(for: UrlCleaner.clean("hello")) == .notAUrl)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(url("  https://example.com/?utm_source=a \n") == "https://example.com/")
    }

    @Test func outcomeDistinguishesUnchangedAndCleaned() {
        #expect(UrlCleaner.outcome(for: UrlCleaner.clean("https://example.com/")) == .unchanged)
        #expect(UrlCleaner.outcome(for: UrlCleaner.clean("https://example.com/?fbclid=1")) == .cleaned(removed: ["fbclid"], unwrapped: false))
    }

    @Test func userAddedGlobalAndSiteRules() {
        var r = UrlCleanRules()
        r.added["", default: []].insert("ref_code")
        r.added["shop.example", default: []].insert("src")
        r.added["pre.example", default: []].insert("trk*")
        #expect(url("https://a.org/?ref_code=1&x=2", r) == "https://a.org/?x=2")
        #expect(url("https://www.shop.example/p?src=mail&id=3", r) == "https://www.shop.example/p?id=3")
        #expect(url("https://other.org/p?src=mail", r) == "https://other.org/p?src=mail")
        #expect(url("https://pre.example/?trk_a=1&trkb=2&k=3", r) == "https://pre.example/?k=3")
    }

    @Test func disablingBuiltInNamesAndSites() {
        var r = UrlCleanRules()
        r.disabled["", default: []].insert("fbclid")
        #expect(url("https://example.com/?fbclid=1&gclid=2", r) == "https://example.com/?fbclid=1")
        r.disabled["", default: []].insert("utm_*")
        #expect(url("https://example.com/?utm_source=1&gclid=2", r) == "https://example.com/?utm_source=1")
        var y = UrlCleanRules()
        y.disabledSites.insert("youtube.com")
        #expect(url("https://www.youtube.com/watch?v=1&si=2", y) == "https://www.youtube.com/watch?v=1&si=2")
        var s = UrlCleanRules()
        s.disabled["youtube.com", default: []].insert("si")
        #expect(url("https://www.youtube.com/watch?v=1&si=2&feature=x", s) == "https://www.youtube.com/watch?v=1&si=2")
    }

    @Test func redirectsAreUnwrappedOnlyWhenEnabled() {
        let wrapped = "https://www.google.com/url?q=https%3A%2F%2Fexample.org%2Fpage%3Futm_source%3Dx%26id%3D5&sa=D&usg=AOv"
        #expect(url(wrapped)?.hasPrefix("https://www.google.com/url") == true)
        var r = UrlCleanRules()
        r.unwrapRedirects = true
        let out = UrlCleaner.clean(wrapped, rules: r)
        #expect(out?.url == "https://example.org/page?id=5")
        #expect(out?.unwrapped == true)
        #expect(out?.removed == ["utm_source"])
    }

    @Test func otherRedirectWrappers() {
        var r = UrlCleanRules()
        r.unwrapRedirects = true
        #expect(url("https://vk.com/away.php?to=https%3A%2F%2Fexample.org%2F&cc_key=", r) == "https://example.org/")
        #expect(url("https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.org%2Fa%3Ffbclid%3D1&h=AT", r) == "https://example.org/a")
        #expect(url("https://www.youtube.com/redirect?q=https%3A%2F%2Fexample.org%2F&event=video", r) == "https://example.org/")
        #expect(url("https://steamcommunity.com/linkfilter/?url=https%3A%2F%2Fexample.org%2Fx", r) == "https://example.org/x")
    }

    @Test func redirectWithoutHttpTargetIsLeftAlone() {
        var r = UrlCleanRules()
        r.unwrapRedirects = true
        let u = "https://www.google.com/url?q=javascript%3Aalert(1)&x=D"
        #expect(url(u, r) == u)
    }

    @Test func nestedWrappersAreBoundedByDepth() {
        var r = UrlCleanRules()
        r.unwrapRedirects = true
        var u = "https://example.org/final"
        for _ in 0..<6 { u = "https://vk.com/away.php?to=" + (u.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? u) }
        let out = UrlCleaner.clean(u, rules: r)
        #expect(out != nil)
        #expect(out?.unwrapped == true)
    }

    @Test func rulesSerializationRoundTrips() {
        var r = UrlCleanRules()
        r.added["", default: []] = ["b", "a"]
        r.added["x.org", default: []] = ["q"]
        let text = UrlCleanRules.serialize(r.added)
        #expect(text == "|a,|b,x.org|q")
        #expect(UrlCleanRules.parse(text) == r.added)
        #expect(UrlCleanRules.parse("garbage,|,  | x ,Site.ORG|Name") == ["": ["x"], "site.org": ["name"]])
        #expect(UrlCleanRules.parse(nil).isEmpty)
    }

    @Test func builtInListIsAdvertised() {
        #expect(UrlCleaner.builtInGlobalList.first == "utm_*")
        #expect(UrlCleaner.builtInGlobalList.contains("yclid"))
    }
}

@Suite struct UrlCleanOnCopyTests {
    private func make(_ s: UrlCleanerSettings = UrlCleanerSettings()) -> (ClpFakePasteboard, UrlCleanOnCopy, PasteboardWatcher) {
        let pb = ClpFakePasteboard()
        let oc = UrlCleanOnCopy(pasteboard: pb, settings: s)
        let w = PasteboardWatcher(pasteboard: pb, frontmost: ClpFakeFront())
        _ = w.subscribe(priority: 0) { oc.handle($0) }
        return (pb, oc, w)
    }

    @Test func dirtyLinkIsRewrittenOnCopyAndNotReprocessed() {
        let (pb, oc, w) = make()
        pb.externalText("https://example.com/a?utm_source=x&id=1")
        w.tick()
        #expect(pb.items.first?.string == "https://example.com/a?id=1")
        #expect(pb.items.first?.reps[PBType.url] != nil)
        w.tick()
        #expect(oc.cleanedCount == 1)
    }

    @Test func cleanLinkAndPlainTextAreLeftAlone() {
        let (pb, oc, w) = make()
        pb.externalText("https://example.com/a?id=1")
        w.tick()
        pb.externalText("привет https://example.com/?utm_source=1")
        w.tick()
        #expect(oc.cleanedCount == 0)
        #expect(pb.writes == 0)
    }

    @Test func imagesAndFilesAreNeverTouched() {
        let (pb, oc, _) = make()
        pb.external([PasteboardItemData(reps: [PBType.utf8: Data("https://example.com/?fbclid=1".utf8), PBType.png: Clp.png()])])
        #expect(oc.cleanClipboard() == nil)
        pb.external([PasteboardItemData(reps: [PBType.utf8: Data("https://example.com/?fbclid=1".utf8), PBType.fileURL: Data("file:///tmp/x".utf8)])])
        #expect(oc.cleanClipboard() == nil)
    }

    @Test func autoCleaningCanBeSwitchedOffButManualStillWorks() {
        var s = UrlCleanerSettings()
        s.cleanOnCopy = false
        let (pb, oc, w) = make(s)
        pb.externalText("https://example.com/?gclid=1")
        w.tick()
        #expect(pb.items.first?.string == "https://example.com/?gclid=1")
        #expect(oc.cleanClipboard()?.url == "https://example.com/")
        #expect(pb.items.first?.string == "https://example.com/")
    }

    @Test func callbackReceivesWhatWasRemoved() {
        let (pb, oc, w) = make()
        var seen: [String] = []
        oc.onCleaned = { seen = $0.removed }
        pb.externalText("https://example.com/?fbclid=1&utm_medium=2")
        w.tick()
        #expect(seen == ["fbclid", "utm_medium"])
    }
}
