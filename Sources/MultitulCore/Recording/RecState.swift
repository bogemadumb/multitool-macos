import Foundation

public enum RecState: Equatable, Sendable {
    case idle
    case countdown(remaining: Int)
    case recording
    case paused
    case stopping
    case finished
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .countdown, .recording, .paused, .stopping: true
        default: false
        }
    }

    public var isCapturing: Bool { self == .recording || self == .paused }

    public var title: String {
        switch self {
        case .idle: "Не пишет"
        case .countdown(let r): "Старт через \(r)"
        case .recording: "Идёт запись"
        case .paused: "Пауза"
        case .stopping: "Сохраняю"
        case .finished: "Готово"
        case .failed: "Ошибка"
        }
    }
}

public enum RecAction: Equatable, Sendable {
    case start(countdown: Int)
    case tick
    case pause
    case resume
    case stop
    case cancel
    case finalized
    case fail(String)
    case reset
}

public enum RecEffect: Equatable, Sendable {
    case showCountdown(Int)
    case updateCountdown(Int)
    case hideCountdown
    case beginCapture
    case pauseCapture
    case resumeCapture
    case endCapture(discard: Bool)
    case deliverResult
    case discardResult
    case reportFailure(String)
}

public struct RecTransition: Equatable, Sendable {
    public var from: RecState
    public var to: RecState
    public var effects: [RecEffect]
    public var accepted: Bool
}

public struct RecStateMachine: Sendable {
    public private(set) var state = RecState.idle
    public private(set) var discarding = false
    public private(set) var transitions = 0

    public init() {}

    @discardableResult
    public mutating func send(_ action: RecAction) -> RecTransition {
        let from = state
        var effects: [RecEffect] = []
        var next: RecState?
        switch (state, action) {
        case (.idle, .start(let n)), (.finished, .start(let n)), (.failed, .start(let n)):
            discarding = false
            if n > 0 {
                next = .countdown(remaining: n)
                effects = [.showCountdown(n)]
            } else {
                next = .recording
                effects = [.beginCapture]
            }
        case (.countdown(let r), .tick):
            if r > 1 {
                next = .countdown(remaining: r - 1)
                effects = [.updateCountdown(r - 1)]
            } else {
                next = .recording
                effects = [.hideCountdown, .beginCapture]
            }
        case (.countdown, .cancel), (.countdown, .stop):
            next = .idle
            effects = [.hideCountdown]
        case (.recording, .pause):
            next = .paused
            effects = [.pauseCapture]
        case (.paused, .resume):
            next = .recording
            effects = [.resumeCapture]
        case (.recording, .stop), (.paused, .stop):
            next = .stopping
            effects = [.endCapture(discard: false)]
        case (.recording, .cancel), (.paused, .cancel):
            discarding = true
            next = .stopping
            effects = [.endCapture(discard: true)]
        case (.stopping, .finalized):
            if discarding {
                next = .idle
                effects = [.discardResult]
            } else {
                next = .finished
                effects = [.deliverResult]
            }
        case (.recording, .fail(let m)), (.paused, .fail(let m)), (.stopping, .fail(let m)), (.countdown, .fail(let m)):
            let wasCapturing = from == .recording || from == .paused
            next = .failed(m)
            effects = (from.isCountdown ? [.hideCountdown] : []) + (wasCapturing ? [.endCapture(discard: false)] : []) + [.reportFailure(m)]
        case (.finished, .reset), (.failed, .reset), (.idle, .reset):
            discarding = false
            next = .idle
        default:
            break
        }
        guard let to = next else { return RecTransition(from: from, to: from, effects: [], accepted: false) }
        state = to
        transitions += 1
        return RecTransition(from: from, to: to, effects: effects, accepted: true)
    }
}

private extension RecState {
    var isCountdown: Bool {
        if case .countdown = self { return true }
        return false
    }
}
