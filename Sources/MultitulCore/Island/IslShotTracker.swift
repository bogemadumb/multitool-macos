import Foundation

public struct IslShotTracker: Equatable, Sendable {
    public static let captureLifetime: TimeInterval = 3.5
    public static let noteLifetime: TimeInterval = 2.5

    public private(set) var recording = false
    public private(set) var paused = false
    public private(set) var recordingStart: Date?
    public private(set) var accumulated: TimeInterval = 0
    public private(set) var pausedAt: Date?
    public private(set) var lastCaptureID: Int64?
    public private(set) var lastCaptureAt: Date?
    public private(set) var note: String?
    public private(set) var noteAt: Date?

    public init() {}

    public mutating func apply(_ e: ShotEvent, now: Date) {
        switch e {
        case .captured(let id, _):
            lastCaptureID = id
            lastCaptureAt = now
        case .copied:
            setNote("Скопировано", now)
        case .linked:
            setNote("Ссылка скопирована", now)
        case .saved:
            setNote("Сохранено", now)
        case .deleted:
            break
        case .recordingStarted:
            recording = true
            paused = false
            recordingStart = now
            accumulated = 0
            pausedAt = nil
        case .recordingPaused:
            guard recording, !paused else { return }
            paused = true
            pausedAt = now
        case .recordingResumed:
            guard recording, paused else { return }
            paused = false
            if let p = pausedAt, let s = recordingStart { recordingStart = s.addingTimeInterval(now.timeIntervalSince(p)) }
            pausedAt = nil
        case .recordingStopped:
            endRecording()
            setNote("Запись сохранена", now)
        case .recordingFailed:
            endRecording()
            setNote("Запись не удалась", now)
        }
    }

    private mutating func endRecording() {
        recording = false
        paused = false
        recordingStart = nil
        pausedAt = nil
    }

    private mutating func setNote(_ text: String, _ now: Date) {
        note = text
        noteAt = now
    }

    public func elapsed(at now: Date) -> TimeInterval {
        guard recording, let s = recordingStart else { return 0 }
        return max((paused ? (pausedAt ?? now) : now).timeIntervalSince(s), 0)
    }

    public func activities(now: Date) -> [IslActivity] {
        var out: [IslActivity] = []
        if recording, let s = recordingStart {
            out.append(IslActivity(id: "recording", section: IslSectionIDs.shots, priority: IslPriority.recording, startedAt: s, urgent: true, peeks: true,
                                   token: paused ? "paused" : "rec", title: paused ? "Пауза" : "Запись"))
        }
        if let id = lastCaptureID, let at = lastCaptureAt, now.timeIntervalSince(at) >= 0, now.timeIntervalSince(at) < Self.captureLifetime {
            out.append(IslActivity(id: "shot", section: IslSectionIDs.shots, priority: IslPriority.transient, startedAt: at, expiresAt: at.addingTimeInterval(Self.captureLifetime),
                                   peeks: true, token: String(id), title: "Снимок сохранён"))
        }
        if let n = note, let at = noteAt, now.timeIntervalSince(at) >= 0, now.timeIntervalSince(at) < Self.noteLifetime {
            out.append(IslActivity(id: "shot.note", section: IslSectionIDs.shots, priority: IslPriority.transient, startedAt: at, expiresAt: at.addingTimeInterval(Self.noteLifetime),
                                   peeks: true, token: n + String(at.timeIntervalSince1970), title: n))
        }
        return out
    }
}
