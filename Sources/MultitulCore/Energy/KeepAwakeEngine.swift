import Foundation

public struct KeepAwakeEngine: Sendable {
    public var settings: KeepAwakeSettings
    public private(set) var session: KeepAwakeSession?
    public private(set) var automationOn = false
    public private(set) var batterySuppressed = false
    public private(set) var assertionHeld = false
    public private(set) var assertionDisplay = false
    public private(set) var lidHeld = false
    public private(set) var dimmed = false
    private var lastJiggle: Date?

    public init(settings: KeepAwakeSettings = KeepAwakeSettings()) { self.settings = settings.sanitized }

    public var isActive: Bool { session != nil || automationOn }

    public static func batteryBelowLimit(_ b: BatteryReading?, limit: Int) -> Bool {
        guard limit > 0, let b, b.hasBattery, !b.onAC, let p = b.percent else { return false }
        return p < limit
    }

    public mutating func start(_ new: KeepAwakeSession, inputs: KeepAwakeInputs) -> [KeepAwakeAction] {
        if Self.batteryBelowLimit(inputs.battery, limit: settings.batteryLimitPercent), let p = inputs.battery?.percent {
            return [.notify(.batteryTooLow(percent: p, limit: settings.batteryLimitPercent))]
        }
        if !isActive { lastJiggle = inputs.now }
        session = new
        return reconcile(inputs)
    }

    public mutating func stop(inputs: KeepAwakeInputs) -> [KeepAwakeAction] {
        session = nil
        return reconcile(inputs)
    }

    public mutating func shutdown(inputs: KeepAwakeInputs) -> [KeepAwakeAction] {
        session = nil
        automationOn = false
        return reconcile(inputs)
    }

    public mutating func apply(settings new: KeepAwakeSettings, inputs: KeepAwakeInputs) -> [KeepAwakeAction] {
        settings = new.sanitized
        if !settings.automationEnabled { automationOn = false }
        return reconcile(inputs)
    }

    // The root call for the closed lid failed: keep the session, drop the lid part.
    public mutating func lidFailed(_ message: String, inputs: KeepAwakeInputs) -> [KeepAwakeAction] {
        lidHeld = false
        if session?.closedLid == true { session?.closedLid = false }
        var out = reconcile(inputs)
        out.append(.notify(.lidUnavailable(message)))
        return out
    }

    public mutating func tick(_ inputs: KeepAwakeInputs) -> [KeepAwakeAction] {
        var notices: [KeepAwakeAction] = []
        let wasActive = isActive
        let low = Self.batteryBelowLimit(inputs.battery, limit: settings.batteryLimitPercent)
        if low && !batterySuppressed {
            batterySuppressed = true
            if wasActive { notices.append(.notify(.ended(.batteryLow))) }
            session = nil
        } else if !low && batterySuppressed {
            batterySuppressed = false
        }

        if let s = session {
            switch s.end {
            case .never: break
            case .at(let d): if inputs.now >= d { end(.timerExpired, &notices) }
            case .appQuits(let id): if !inputs.runningApps.contains(id) { end(.appQuit, &notices) }
            }
        }
        if let s = session, s.closedLid, settings.lidMaxHours > 0, inputs.now.timeIntervalSince(s.start) >= Double(settings.lidMaxHours) * 3600 {
            end(.lidLimit, &notices)
        }

        automationOn = !batterySuppressed && Self.automationSatisfied(settings, inputs)
        if !wasActive && isActive { lastJiggle = inputs.now }

        var out = reconcile(inputs)
        if isActive, settings.jiggleEnabled, let last = lastJiggle, inputs.now.timeIntervalSince(last) >= Double(settings.jiggleMinutes) * 60 {
            lastJiggle = inputs.now
            out.append(.jiggle)
        }
        return notices + out
    }

    private mutating func end(_ reason: KeepAwakeEndReason, _ notices: inout [KeepAwakeAction]) {
        session = nil
        if settings.notifyOnEnd { notices.append(.notify(.ended(reason))) }
    }

    public static func automationSatisfied(_ s: KeepAwakeSettings, _ i: KeepAwakeInputs) -> Bool {
        var results: [Bool] = []
        if s.autoExternalDisplay { results.append(i.externalDisplays > 0) }
        if s.autoOnPower { results.append(i.battery.map { $0.hasBattery ? $0.onAC : true } ?? false) }
        if s.autoApps, !s.autoAppBundleIDs.isEmpty { results.append(s.autoAppBundleIDs.contains { i.runningApps.contains($0) }) }
        if results.isEmpty { return false }
        return s.match == .any ? results.contains(true) : !results.contains(false)
    }

    // Order: undim, lid off, release | hold, lid on, dim.
    private mutating func reconcile(_ inputs: KeepAwakeInputs) -> [KeepAwakeAction] {
        let active = isActive
        let wantDisplay = !settings.allowDisplaySleep
        let wantLid = session?.closedLid ?? false
        let wantDim = wantLid && inputs.lidClosed && settings.dimOnLidClosed
        var out: [KeepAwakeAction] = []

        if dimmed && !wantDim { dimmed = false; out.append(.dimBuiltin(false)) }
        if lidHeld && !wantLid { lidHeld = false; out.append(.setClosedLid(false)) }
        if assertionHeld && !active {
            assertionHeld = false
            assertionDisplay = false
            out.append(.releaseAssertion)
        }
        if active && (!assertionHeld || assertionDisplay != wantDisplay) {
            assertionHeld = true
            assertionDisplay = wantDisplay
            out.append(.holdAssertion(displayToo: wantDisplay))
        }
        if wantLid && !lidHeld { lidHeld = true; out.append(.setClosedLid(true)) }
        if wantDim && !dimmed { dimmed = true; out.append(.dimBuiltin(true)) }
        if !active { lastJiggle = nil }
        return out
    }
}
