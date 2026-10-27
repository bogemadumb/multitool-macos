import Foundation

public struct AutoPipTab: Equatable, Sendable {
    public let win: Int
    public let tab: Int
    public let url: String

    public init(win: Int, tab: Int, url: String) {
        self.win = win
        self.tab = tab
        self.url = url
    }

    public static func == (a: AutoPipTab, b: AutoPipTab) -> Bool { a.win == b.win && a.tab == b.tab }
}

public struct AutoPipSettings: Equatable, Sendable {
    public var safariEnabled = true
    public var pollInterval = 0.7
    public var verifyDelay = 0.7
    public var minWidth = 160
    public var minHeight = 90
    public var exitOnReturn = true

    public init() {}

    public static let pollChoices: [Double] = [0.4, 0.7, 1.0, 1.5, 2.0]

    public var sanitized: AutoPipSettings {
        var s = self
        s.pollInterval = max(0.2, min(s.pollInterval, 5))
        s.verifyDelay = max(0.1, min(s.verifyDelay, 5))
        s.minWidth = max(1, min(s.minWidth, 4000))
        s.minHeight = max(1, min(s.minHeight, 4000))
        return s
    }
}

public final class AutoPipStore {
    static let prefix = "autoPip."
    private let defaults: KeyValueStoring

    public init(defaults: KeyValueStoring = UserDefaults.standard) { self.defaults = defaults }

    public func load() -> AutoPipSettings {
        var s = AutoPipSettings()
        if let v = defaults.object(forKey: Self.prefix + "safari") as? Bool { s.safariEnabled = v }
        if let v = defaults.object(forKey: Self.prefix + "pollInterval") as? Double { s.pollInterval = v }
        if let v = defaults.object(forKey: Self.prefix + "verifyDelay") as? Double { s.verifyDelay = v }
        if let v = defaults.object(forKey: Self.prefix + "minWidth") as? Int { s.minWidth = v }
        if let v = defaults.object(forKey: Self.prefix + "minHeight") as? Int { s.minHeight = v }
        if let v = defaults.object(forKey: Self.prefix + "exitOnReturn") as? Bool { s.exitOnReturn = v }
        return s.sanitized
    }

    public func save(_ settings: AutoPipSettings) {
        let s = settings.sanitized
        let base = AutoPipSettings()
        func put<T: Equatable>(_ key: String, _ v: T, _ d: T) {
            if v == d { defaults.removeObject(forKey: Self.prefix + key) } else { defaults.set(v, forKey: Self.prefix + key) }
        }
        put("safari", s.safariEnabled, base.safariEnabled)
        put("pollInterval", s.pollInterval, base.pollInterval)
        put("verifyDelay", s.verifyDelay, base.verifyDelay)
        put("minWidth", s.minWidth, base.minWidth)
        put("minHeight", s.minHeight, base.minHeight)
        put("exitOnReturn", s.exitOnReturn, base.exitOnReturn)
    }
}

public enum AutoPipScripts {
    public static let safariBundleID = "com.apple.Safari"

    public static func enterJS(minWidth: Int, minHeight: Int) -> String {
        """
        (function(){
        var vs=[].slice.call(document.querySelectorAll('video'));var best=null,ba=0;
        vs.forEach(function(v){var r=v.getBoundingClientRect();var a=r.width*r.height;
        if(!v.paused&&!v.ended&&v.readyState>2&&v.currentTime>0&&r.width>=\(minWidth)&&r.height>=\(minHeight)&&a>ba){best=v;ba=a;}});
        if(!best)return 'no-playing-video:'+vs.length;
        if(best.webkitPresentationMode==='picture-in-picture'||document.pictureInPictureElement===best)return 'already-pip';
        function mark(){best.setAttribute('data-autopip','1');window.__autopipVideo=best;}
        try{
        if(best.webkitSupportsPresentationMode&&!best.webkitSupportsPresentationMode('picture-in-picture'))throw 'unsupported';
        best.webkitSetPresentationMode('picture-in-picture');mark();return 'entered:webkit';
        }catch(e){
        if(best.requestPictureInPicture){best.requestPictureInPicture().catch(function(){});mark();return 'entered:request ('+e+')';}
        return 'fail:'+e;}
        })()
        """
    }

    public static let exitJS = """
    (function(){
    var v=window.__autopipVideo;if(!v)return 'no-flag';
    var m=v.webkitPresentationMode;delete window.__autopipVideo;v.removeAttribute('data-autopip');
    if(m==='picture-in-picture'){v.webkitSetPresentationMode('inline');return 'exited';}
    return 'not-in-pip:'+m;
    })()
    """

    public static let statusJS = """
    (function(){var v=window.__autopipVideo;return v?('mode='+v.webkitPresentationMode):'no-flag';})()
    """

    public static let pollScript = """
    tell application "Safari"
      if (count of windows) is 0 then return "none"
      set w to front window
      set u to ""
      try
        set u to URL of current tab of w
        if u is missing value then set u to ""
      end try
      return ((id of w) as string) & "|" & ((index of current tab of w) as string) & "|" & u
    end tell
    """

    public static func doJavaScript(_ code: String, in t: AutoPipTab) -> String {
        let esc = code.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "tell application \"Safari\" to return (do JavaScript \"\(esc)\" in tab \(t.tab) of window id \(t.win))"
    }

    public static func parseTab(_ s: String) -> AutoPipTab? {
        let p = s.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard p.count == 3, let w = Int(p[0]), let t = Int(p[1]) else { return nil }
        return AutoPipTab(win: w, tab: t, url: String(p[2]))
    }
}

public enum AutoPipEffect: Equatable, Sendable {
    case startPolling
    case stopPolling
    case poll
    case pollThenEnter(reason: String, cached: AutoPipTab?)
    case enter(AutoPipTab, reason: String)
    case exit(AutoPipTab)
    case verify(AutoPipTab)
    case settleCheck(after: TimeInterval)
}

public struct AutoPipMachine: Sendable {
    public var settings: AutoPipSettings
    public private(set) var frontID: String?
    public private(set) var safariFront = false
    public private(set) var current: AutoPipTab?
    public private(set) var auto: [AutoPipTab] = []

    public static let settleDelay = 0.4

    public init(settings: AutoPipSettings = AutoPipSettings()) { self.settings = settings.sanitized }

    public mutating func start(frontmost: String?) -> [AutoPipEffect] {
        frontID = frontmost
        return frontmost == AutoPipScripts.safariBundleID ? becomeFront() : []
    }

    public mutating func stop() -> [AutoPipEffect] {
        safariFront = false
        current = nil
        return [.stopPolling]
    }

    // Regular apps only: the caller filters out agents and background apps.
    public mutating func appActivated(_ bundleID: String?) -> [AutoPipEffect] {
        guard bundleID != frontID else { return [] }
        let old = frontID
        frontID = bundleID
        var out: [AutoPipEffect] = []
        if old == AutoPipScripts.safariBundleID { out += leaveFront(reason: "app-switch to \(bundleID ?? "?")") }
        if bundleID == AutoPipScripts.safariBundleID { out += becomeFront() }
        return out
    }

    public mutating func spaceChanged() -> [AutoPipEffect] {
        guard frontID == AutoPipScripts.safariBundleID else { return [] }
        let out = leaveFront(reason: "space-change")
        frontID = nil
        return out + [.settleCheck(after: Self.settleDelay)]
    }

    public mutating func spaceSettled(frontmost: String?) -> [AutoPipEffect] {
        guard frontID == nil else { return [] }
        frontID = frontmost
        return frontmost == AutoPipScripts.safariBundleID ? becomeFront() : []
    }

    public func timerFired() -> [AutoPipEffect] { settings.safariEnabled && safariFront ? [.poll] : [] }

    public mutating func pollResult(_ raw: String) -> [AutoPipEffect] {
        guard safariFront else { return [] }
        let new = AutoPipScripts.parseTab(raw)
        let old = current
        current = new
        var out: [AutoPipEffect] = []
        if let o = old, let n = new, o != n { out.append(.enter(o, reason: "tab-change")) }
        if settings.exitOnReturn, let n = new, auto.contains(n) {
            auto.removeAll { $0 == n }
            out.append(.exit(n))
        }
        return out
    }

    public mutating func leaveResolved(fresh: AutoPipTab?, cached: AutoPipTab?, reason: String) -> [AutoPipEffect] {
        guard let t = fresh ?? cached else { return [] }
        return [.enter(t, reason: reason)]
    }

    public mutating func enterResult(_ tab: AutoPipTab, result: String) -> [AutoPipEffect] {
        guard result.hasPrefix("entered") else { return [] }
        if !auto.contains(tab) { auto.append(tab) }
        return [.verify(tab)]
    }

    private mutating func becomeFront() -> [AutoPipEffect] {
        safariFront = true
        return [.startPolling, .poll]
    }

    private mutating func leaveFront(reason: String) -> [AutoPipEffect] {
        guard safariFront else { return [] }
        safariFront = false
        let cached = current
        current = nil
        guard settings.safariEnabled else { return [.stopPolling] }
        return [.stopPolling, .pollThenEnter(reason: reason, cached: cached)]
    }
}
