import Foundation
import CoreGraphics

public extension InputPriority {
    static let radial = 443
}

public final class RadialStage {
    public static let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                              .leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp]
    private let hub: EventTapHub
    private let controller: RadialController
    private var token: EventTapHub.Token?

    public init(hub: EventTapHub, controller: RadialController) {
        self.hub = hub
        self.controller = controller
    }

    public var isRunning: Bool { token != nil }

    public func start() {
        guard token == nil else { return }
        token = hub.subscribe(types: Self.types, priority: InputPriority.radial, seesDropped: false, onReset: { [weak self] in self?.controller.cancel() }) { [weak self] type, e in
            guard let self, let input = Self.input(type, e) else { return .pass }
            return self.controller.handle(input)
        }
    }

    public func stop() {
        if let t = token { hub.unsubscribe(t) }
        token = nil
        controller.cancel()
    }

    static func input(_ type: CGEventType, _ e: CGEvent) -> RadialInput? {
        switch type {
        case .keyDown:
            return .keyDown(code: UInt32(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode)), mods: KeyStroke.modifiers(from: e.flags),
                            repeating: e.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp: return .keyUp(code: UInt32(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode)))
        case .flagsChanged: return .modsChanged(KeyStroke.modifiers(from: e.flags))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return .moved(e.location)
        case .leftMouseDown: return .leftDown(e.location)
        case .leftMouseUp: return .leftUp(e.location)
        case .otherMouseDown: return .buttonDown(Int(e.getIntegerValueField(.mouseEventButtonNumber)), e.location)
        case .otherMouseUp: return .buttonUp(Int(e.getIntegerValueField(.mouseEventButtonNumber)), e.location)
        default: return nil
        }
    }
}
