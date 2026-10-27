import Testing
import Foundation
@testable import MultitulCore

private let safari = AutoPipScripts.safariBundleID
private let tabA = AutoPipTab(win: 10, tab: 1, url: "https://a.example/v")
private let tabB = AutoPipTab(win: 10, tab: 2, url: "https://b.example/")

private func frontMachine(_ s: AutoPipSettings = AutoPipSettings()) -> AutoPipMachine {
    var m = AutoPipMachine(settings: s)
    _ = m.start(frontmost: safari)
    return m
}

@Suite struct AutoPipScriptTests {
    @Test func parseTab() {
        #expect(AutoPipScripts.parseTab("123|2|https://x.y/?a=1|b") == AutoPipTab(win: 123, tab: 2, url: "https://x.y/?a=1|b"))
        #expect(AutoPipScripts.parseTab("5|1|")?.url == "")
        #expect(AutoPipScripts.parseTab("none") == nil)
        #expect(AutoPipScripts.parseTab("a|b|c") == nil)
        #expect(AutoPipScripts.parseTab("ERR -1743: nope") == nil)
    }

    @Test func tabEqualityIgnoresUrl() {
        #expect(AutoPipTab(win: 1, tab: 2, url: "a") == AutoPipTab(win: 1, tab: 2, url: "b"))
        #expect(AutoPipTab(win: 1, tab: 2, url: "a") != AutoPipTab(win: 1, tab: 3, url: "a"))
    }

    @Test func doJavaScriptEscapesAndTargetsTab() {
        let s = AutoPipScripts.doJavaScript("var a=\"x\\y\";\nreturn a", in: tabA)
        #expect(s.hasPrefix("tell application \"Safari\" to return (do JavaScript \""))
        #expect(s.hasSuffix("\" in tab 1 of window id 10)"))
        #expect(s.contains("var a=\\\"x\\\\y\\\";"))
        #expect(!s.contains("\n"))
    }

    @Test func enterScriptCarriesSizeThresholds() {
        let js = AutoPipScripts.enterJS(minWidth: 320, minHeight: 180)
        #expect(js.contains("r.width>=320&&r.height>=180"))
        #expect(js.contains("webkitSetPresentationMode('picture-in-picture')"))
        #expect(AutoPipScripts.exitJS.contains("webkitSetPresentationMode('inline')"))
    }
}

@Suite struct AutoPipMachineTests {
    @Test func startsPollingOnlyWhenSafariIsFront() {
        var m = AutoPipMachine()
        #expect(m.start(frontmost: safari) == [.startPolling, .poll])
        var n = AutoPipMachine()
        #expect(n.start(frontmost: "com.apple.finder").isEmpty)
        #expect(n.timerFired().isEmpty)
    }

    @Test func leavingSafariPollsFreshTabThenEnters() {
        var m = frontMachine()
        _ = m.pollResult("10|1|https://a.example/v")
        let e = m.appActivated("com.apple.finder")
        #expect(e == [.stopPolling, .pollThenEnter(reason: "app-switch to com.apple.finder", cached: tabA)])
        #expect(m.leaveResolved(fresh: tabB, cached: tabA, reason: "r") == [.enter(tabB, reason: "r")])
        #expect(m.leaveResolved(fresh: nil, cached: tabA, reason: "r") == [.enter(tabA, reason: "r")])
        #expect(m.leaveResolved(fresh: nil, cached: nil, reason: "r").isEmpty)
    }

    @Test func pausedSettingStopsPollingButNeverEntersPip() {
        var s = AutoPipSettings()
        s.safariEnabled = false
        var m = frontMachine(s)
        #expect(m.timerFired().isEmpty)
        #expect(m.appActivated("com.apple.finder") == [.stopPolling])
    }

    @Test func tabChangeSendsOldTabToPip() {
        var m = frontMachine()
        #expect(m.pollResult("10|1|u").isEmpty)
        #expect(m.pollResult("10|1|u2").isEmpty)
        #expect(m.pollResult("10|2|v") == [.enter(AutoPipTab(win: 10, tab: 1, url: "u2"), reason: "tab-change")])
    }

    @Test func returningToAutoTabExitsPip() {
        var m = frontMachine()
        _ = m.pollResult("10|1|u")
        _ = m.appActivated("com.apple.finder")
        #expect(m.enterResult(tabA, result: "entered:webkit") == [.verify(tabA)])
        #expect(m.auto == [tabA])
        #expect(m.appActivated(safari) == [.startPolling, .poll])
        #expect(m.pollResult("10|1|u") == [.exit(tabA)])
        #expect(m.auto.isEmpty)
        #expect(m.pollResult("10|1|u").isEmpty)
    }

    @Test func exitOnReturnCanBeDisabled() {
        var s = AutoPipSettings()
        s.exitOnReturn = false
        var m = frontMachine(s)
        _ = m.enterResult(tabA, result: "entered:request (x)")
        _ = m.pollResult("10|1|u")
        #expect(m.auto == [tabA])
    }

    @Test func failedEntryIsNotRemembered() {
        var m = frontMachine()
        for r in ["no-playing-video:2", "already-pip", "fail:x", "ERR -1743: no", ""] {
            #expect(m.enterResult(tabA, result: r).isEmpty)
        }
        #expect(m.auto.isEmpty)
    }

    @Test func sameTabIsRememberedOnce() {
        var m = frontMachine()
        _ = m.enterResult(tabA, result: "entered:webkit")
        _ = m.enterResult(AutoPipTab(win: 10, tab: 1, url: "other"), result: "entered:webkit")
        #expect(m.auto.count == 1)
    }

    @Test func spaceChangeLeavesThenResettlesOnSafari() {
        var m = frontMachine()
        let e = m.spaceChanged()
        #expect(e == [.stopPolling, .pollThenEnter(reason: "space-change", cached: nil), .settleCheck(after: 0.4)])
        #expect(m.frontID == nil)
        #expect(m.spaceSettled(frontmost: safari) == [.startPolling, .poll])
        #expect(m.frontID == safari)
    }

    @Test func spaceChangeSettlesOnOtherAppQuietly() {
        var m = frontMachine()
        _ = m.spaceChanged()
        #expect(m.spaceSettled(frontmost: "com.apple.finder").isEmpty)
        #expect(m.frontID == "com.apple.finder")
    }

    @Test func spaceChangeIgnoredWhenSafariNotFront() {
        var m = AutoPipMachine()
        _ = m.start(frontmost: "com.apple.finder")
        #expect(m.spaceChanged().isEmpty)
        #expect(m.spaceSettled(frontmost: safari).isEmpty)
        #expect(m.frontID == "com.apple.finder")
    }

    @Test func settleDoesNotOverrideAnActivationThatCameFirst() {
        var m = frontMachine()
        _ = m.spaceChanged()
        _ = m.appActivated("com.apple.finder")
        #expect(m.spaceSettled(frontmost: safari).isEmpty)
        #expect(m.frontID == "com.apple.finder")
    }

    @Test func repeatedActivationOfSameAppIsIgnored() {
        var m = frontMachine()
        #expect(m.appActivated(safari).isEmpty)
    }

    @Test func pollResultsIgnoredWhenSafariIsNotFront() {
        var m = AutoPipMachine()
        _ = m.start(frontmost: "com.apple.finder")
        #expect(m.pollResult("10|1|u").isEmpty)
        #expect(m.current == nil)
    }

    @Test func noWindowsMeansNoTab() {
        var m = frontMachine()
        _ = m.pollResult("10|1|u")
        #expect(m.pollResult("none").isEmpty)
        #expect(m.current == nil)
    }

    @Test func stopHaltsPolling() {
        var m = frontMachine()
        #expect(m.stop() == [.stopPolling])
        #expect(m.timerFired().isEmpty)
    }
}

@Suite struct AutoPipSettingsTests {
    @Test func storeRoundtripAndDefaults() {
        let suite = "multitul-pip-\(UUID().uuidString)"
        let d = InMemoryKeyValueStore()
        let store = AutoPipStore(defaults: d)
        #expect(store.load() == AutoPipSettings())
        var s = AutoPipSettings()
        s.safariEnabled = false
        s.pollInterval = 1.5
        s.minWidth = 400
        s.minHeight = 250
        s.exitOnReturn = false
        store.save(s)
        #expect(store.load() == s)
        store.save(AutoPipSettings())
        #expect(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("autoPip.") }.isEmpty)
    }

    @Test func sanitizeClamps() {
        var s = AutoPipSettings()
        s.pollInterval = 0
        s.verifyDelay = 99
        s.minWidth = -4
        s.minHeight = 99_999
        let c = s.sanitized
        #expect(c.pollInterval == 0.2 && c.verifyDelay == 5 && c.minWidth == 1 && c.minHeight == 4000)
    }

    @Test func defaultsMatchOldProgram() {
        let s = AutoPipSettings()
        #expect(s.pollInterval == 0.7 && s.verifyDelay == 0.7 && s.minWidth == 160 && s.minHeight == 90 && s.safariEnabled)
    }
}
