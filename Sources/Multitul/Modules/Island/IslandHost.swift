import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class IslandHostingView: NSHostingView<IslandRootView> {
    var onScroll: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if onScroll?(event) == true { return }
        super.scrollWheel(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandDisplayModel: ObservableObject {
    let screenID: UInt32
    @Published var state = IslState.closed
    @Published var frames: IslFrames
    @Published var notch: IslNotch
    @Published var window: CGRect
    @Published var content: CGRect
    @Published var wings = IslWings.zero
    @Published var currentSection: IslSectionID?
    @Published var pinned = false
    @Published var peekActivity: IslActivity?
    weak var host: IslandDisplayHost?

    init(screenID: UInt32, frames: IslFrames, notch: IslNotch) {
        self.screenID = screenID
        self.frames = frames
        self.notch = notch
        window = frames.closed
        content = frames.closed
    }
}

@MainActor
final class IslandDisplayHost {
    let model: IslandDisplayModel
    let machine: IslStateMachine
    private(set) var screen: IslScreenInfo
    private unowned let ctl: IslandController
    private var tracker = IslPointerTracker()
    private var gestures = IslGestureClassifier()
    private let panel: IslandPanel
    private let hosting: IslandHostingView
    private let container: ShelfDropContainer
    private var timer: Timer?
    private var shrinkWork: DispatchWorkItem?
    private(set) var hidden = true

    init(screen: IslScreenInfo, ctl: IslandController) {
        self.screen = screen
        self.ctl = ctl
        let notch = IslNotchDetector.notch(for: screen)
        let frames = IslLayoutMath.frames(screen: screen, notch: notch, preset: ctl.settings.sizePreset)
        model = IslandDisplayModel(screenID: screen.id, frames: frames, notch: notch)
        machine = IslStateMachine(config: IslMachineConfig(ctl.settings))

        panel = IslandPanel(contentRect: frames.closed, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        hosting = IslandHostingView(rootView: IslandRootView(model: model))
        container = ShelfDropContainer(content: hosting)
        panel.contentView = container
        model.host = self
        hosting.onScroll = { [weak self] e in self?.scroll(e) ?? false }
        container.onTarget = { [weak self] on in if on { self?.send(.dragEntered) } }
        container.intake = ShelfController.shared.intake
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            shrinkWork?.cancel()
        }
    }

    var state: IslState { machine.state }

    func teardown() {
        timer?.invalidate()
        shrinkWork?.cancel()
        panel.orderOut(nil)
        panel.contentView = nil
        model.host = nil
    }

    func refreshIntake() { container.intake = ShelfController.shared.intake }

    // MARK: geometry

    func update(screen: IslScreenInfo, wings: IslWings) {
        self.screen = screen
        let notch = IslNotchDetector.notch(for: screen)
        let frames = IslLayoutMath.frames(screen: screen, notch: notch, preset: ctl.settings.sizePreset, wings: wings)
        model.notch = notch
        model.frames = frames
        model.wings = wings
        move(to: frames.frame(for: machine.state), animation: .spring(response: 0.38, dampingFraction: 0.86), immediate: hidden)
    }

    private func move(to target: CGRect, animation: Animation?, immediate: Bool = false) {
        shrinkWork?.cancel()
        let union = panel.frame.union(target).union(model.content)
        if union != panel.frame { panel.setFrame(union, display: false) }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { model.window = union }
        if immediate || animation == nil {
            withTransaction(quiet) { model.content = target }
        } else {
            withAnimation(animation) { model.content = target }
        }
        guard union != target else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.setFrame(target, display: false)
                var q = Transaction()
                q.disablesAnimations = true
                withTransaction(q) { self.model.window = target }
            }
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0.01 : 0.5), execute: work)
    }

    func setHidden(_ h: Bool) {
        guard h != hidden else { return }
        hidden = h
        if h { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    // MARK: events

    func configChanged() {
        machine.config = IslMachineConfig(ctl.settings)
        schedule()
    }

    func send(_ e: IslEvent) {
        let ts = machine.handle(e, now: Date())
        applyTransitions(ts)
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let d = machine.nextDeadline else { return }
        let t = Timer(fire: d, interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.fired() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fired() {
        timer = nil
        if machine.pointerInside { ctl.refreshSuppression() }
        applyTransitions(machine.tick(now: Date()))
        schedule()
    }

    func pointerMoved(_ p: CGPoint) {
        guard !hidden else { return }
        if let e = tracker.update(p, state: machine.state, frames: model.frames) {
            if e == .pointerEntered { ctl.refreshSuppression() }
            send(e)
        }
    }

    func outsideClick(_ p: CGPoint) {
        guard machine.state != .closed, !hidden else { return }
        if model.frames.frame(for: machine.state).insetBy(dx: -IslHoverZone.leaveSlop, dy: -IslHoverZone.leaveSlop).contains(p) { return }
        send(.outsideClick)
    }

    func setSuppression(_ s: Set<IslSuppression>) {
        guard s != machine.suppression else { return }
        send(.suppressed(s))
    }

    private func applyTransitions(_ ts: [IslTransition]) {
        guard let last = ts.last else { return }
        let before = ts.first?.from ?? last.from
        switch last.to {
        case .closed:
            ctl.hostClosed(self, from: before)
            model.pinned = false
            model.state = .closed
            model.peekActivity = nil
            tracker.sync(NSEvent.mouseLocation, state: .closed, frames: model.frames)
            if machine.pointerInside && !tracker.inside { _ = machine.handle(.pointerLeft, now: Date()) }
            move(to: model.frames.closed, animation: .spring(response: 0.34, dampingFraction: 0.9))
        case .peek:
            model.peekActivity = ctl.arbitration.winner
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.state = .peek }
            move(to: model.frames.peek, animation: .spring(response: 0.38, dampingFraction: 0.8))
        case .open:
            ctl.hostWillOpen(self, trigger: last.trigger)
            refreshIntake()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { model.state = .open }
            move(to: model.frames.open, animation: .spring(response: 0.42, dampingFraction: 0.78))
        }
        Log.write("island display=\(screen.id) \(last.from.rawValue)->\(last.to.rawValue) by=\(last.trigger.rawValue)")
    }

    // MARK: user actions

    func clicked() { send(.clicked) }

    func togglePin() {
        send(.setPinned(!machine.pinned))
        model.pinned = machine.pinned
    }

    func close() { send(.forceClose) }

    func select(_ id: IslSectionID) { ctl.select(id, on: self) }

    // MARK: scroll

    private func scroll(_ e: NSEvent) -> Bool {
        let phase: IslScrollPhase
        if !e.momentumPhase.isEmpty { phase = .momentum }
        else if e.phase.contains(.began) || e.phase.contains(.mayBegin) { phase = .began }
        else if e.phase.contains(.ended) || e.phase.contains(.cancelled) { phase = .ended }
        else if e.phase.contains(.changed) { phase = .changed }
        else { phase = .none }
        let sample = IslScrollSample(dx: Double(e.scrollingDeltaX), dy: Double(e.scrollingDeltaY), precise: e.hasPreciseScrollingDeltas, phase: phase,
                                     time: e.timestamp, invertedFromDevice: e.isDirectionInvertedFromDevice)
        let p = NSEvent.mouseLocation
        let s = ctl.settings
        let winner = ctl.arbitration.winner
        let ctx = IslGestureContext(state: machine.state, zone: IslGestureZone.zone(for: p, state: machine.state, frames: model.frames),
                                    musicActive: winner?.section == IslSectionIDs.music, musicIsCurrent: model.currentSection == IslSectionIDs.music,
                                    swipe: s.musicSwipe, openOnScroll: s.openOnScroll, closeOnScrollUp: s.closeOnScrollUp)
        let out = gestures.feed(sample, context: ctx)
        if let intent = out.intent { perform(intent) }
        return out.consumed
    }

    private func perform(_ intent: IslGestureIntent) {
        switch intent {
        case .open: send(.scrollOpen)
        case .close: send(.scrollClose)
        case .nextTrack: ctl.music.next()
        case .previousTrack: ctl.music.previous()
        case .nextSection: ctl.swipe(on: self, forward: true)
        case .previousSection: ctl.swipe(on: self, forward: false)
        }
    }
}
