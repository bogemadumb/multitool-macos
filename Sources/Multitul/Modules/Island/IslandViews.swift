import SwiftUI
import AppKit
import MultitulCore
import MultitulUI

struct IslandRootView: View {
    @ObservedObject var model: IslandDisplayModel
    @ObservedObject private var ctl = IslandController.shared

    var body: some View {
        let local = CGRect(x: model.content.minX - model.window.minX, y: 0, width: model.content.width, height: model.content.height)
        ZStack(alignment: .topLeading) {
            island
                .frame(width: max(local.width, 1), height: max(local.height, 1), alignment: .top)
                .clipShape(shape)
                .overlay(shape.stroke(Color.white.opacity(glassOn ? 0.10 : 0), lineWidth: 0.5))
                .offset(x: local.minX)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private var glassOn: Bool { ctl.settings.glass && model.state == .open }

    private var shape: IslNotchShape {
        switch model.state {
        case .closed: IslNotchShape(topRadius: 0, bottomRadius: 9)
        case .peek: IslNotchShape(topRadius: 8, bottomRadius: 16)
        case .open: IslNotchShape(topRadius: 16, bottomRadius: 24)
        }
    }

    private var island: some View {
        ZStack(alignment: .top) {
            background
            Group {
                switch model.state {
                case .closed: closedRow(width: model.frames.closed.width, left: model.wings.left, right: model.wings.right)
                case .peek: peek
                case .open: IslandOpenView(model: model).frame(width: model.frames.open.width, height: model.frames.open.height, alignment: .top)
                }
            }
            .transition(.opacity)
        }
        .contentShape(Rectangle())
        .onTapGesture { if model.state != .open { model.host?.clicked() } }
    }

    private var background: some View {
        ZStack {
            VisualEffect(material: .hudWindow, blending: .behindWindow).opacity(glassOn ? 1 : 0)
            Color.black.opacity(glassOn ? 0 : 1)
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)).opacity(glassOn ? 1 : 0)
        }
    }

    private func closedRow(width: CGFloat, left: CGFloat, right: CGFloat) -> some View {
        let winner = model.state == .peek ? (model.peekActivity ?? ctl.arbitration.winner) : ctl.arbitration.winner
        let section = winner.flatMap { ctl.registry.section($0.section) }
        let accessoryWins = winner == nil || (winner?.priority ?? 0) <= IslPriority.music
        let leadingAcc = accessoryWins ? ctl.accessories.active(in: .wingLeading).first : nil
        let trailingAcc = accessoryWins ? ctl.accessories.active(in: .wingTrailing).first : nil
        return HStack(spacing: 0) {
            Group {
                if let a = leadingAcc { a.view() } else if let w = winner, let v = section?.compactLeading(w) { v } else { Color.clear }
            }
            .frame(width: max(left, 0), height: model.notch.rect.height)
            Color.clear.frame(width: model.notch.rect.width)
            Group {
                if let a = trailingAcc { a.view() } else if let w = winner, let v = section?.compactTrailing(w) { v } else { Color.clear }
            }
            .frame(width: max(right, 0), height: model.notch.rect.height)
        }
        .frame(width: width, height: model.notch.rect.height)
    }

    private var peek: some View {
        let f = model.frames.peek
        let wing = max((f.width - model.notch.rect.width) / 2, 0)
        let activity = model.peekActivity ?? ctl.arbitration.winner
        let section = activity.flatMap { ctl.registry.section($0.section) }
        return VStack(spacing: 0) {
            closedRow(width: f.width, left: wing, right: wing)
            Group {
                if let a = activity, let v = section?.peekView(a) {
                    v
                } else if let a = activity {
                    Text(a.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: f.width, height: f.height, alignment: .top)
    }
}

struct IslandOpenView: View {
    @ObservedObject var model: IslandDisplayModel
    @ObservedObject private var ctl = IslandController.shared
    @ObservedObject private var accessoryService = IslandAccessoriesService.shared

    var body: some View {
        let ids = ctl.visibleSectionIDs
        VStack(spacing: 0) {
            topRow(ids)
            content
        }
        .padding(.bottom, 6)
    }

    private func topRow(_ ids: [IslSectionID]) -> some View {
        let notchW = model.notch.rect.width
        let side = max((model.frames.open.width - notchW) / 2, 40)
        let selected = ids.firstIndex { $0 == model.currentSection }
        let split = IslTabLayout.split(count: ids.count, selected: selected, leftWidth: side - 28, rightWidth: side - 14, rightReserved: 66)
        return HStack(spacing: 0) {
            HStack(spacing: 0) { ForEach(split.left, id: \.self) { tab(ids[$0]) } }
                .padding(.leading, 18)
                .frame(width: side, alignment: .leading)
            Color.clear.frame(width: notchW)
            HStack(spacing: 0) {
                ForEach(split.right, id: \.self) { tab(ids[$0]) }
                if !split.overflow.isEmpty {
                    Menu {
                        ForEach(split.overflow, id: \.self) { i in
                            let d = ctl.registry.section(ids[i])?.descriptor
                            Button { model.host?.select(ids[i]) } label: { Label(d?.title ?? ids[i].rawValue, systemImage: d?.symbol ?? "circle") }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).frame(width: 26, height: 24)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Spacer(minLength: 0)
                ForEach(ctl.accessories.active(in: .headerTrailing)) { a in a.view().padding(.trailing, 6) }
                IslIconButton(symbol: model.pinned ? "pin.fill" : "pin", size: 12, tint: model.pinned ? Theme.accent : .white.opacity(0.75), help: model.pinned ? "Открепить" : "Не закрывать") { model.host?.togglePin() }
                IslIconButton(symbol: "gearshape", size: 12, tint: .white.opacity(0.75), help: "Настройки острова") { ctl.openSettings() }
            }
            .padding(.trailing, 12)
            .frame(width: side, alignment: .leading)
        }
        .frame(height: max(model.notch.rect.height, 28))
        .contentShape(Rectangle())
        .onTapGesture { model.host?.clicked() }
    }

    private func tab(_ id: IslSectionID) -> some View {
        let d = ctl.registry.section(id)?.descriptor
        let on = id == model.currentSection
        return Button { model.host?.select(id) } label: {
            Image(systemName: d?.symbol ?? "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? .white : .white.opacity(0.55))
                .frame(width: 28, height: 24)
                .background(Color.white.opacity(on ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(d?.title ?? "")
    }

    @ViewBuilder
    private var content: some View {
        if let id = model.currentSection, let section = ctl.registry.section(id), section.availability.isAvailable {
            let ctx = IslExpandContext(size: model.frames.open.size, topInset: max(model.notch.rect.height, 28), preset: ctl.settings.sizePreset,
                                       closeIsland: { model.host?.close() }, openSettings: { ctl.openSettings() })
            section.expandedView(ctx)
                .id(id)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            IslEmptyNote(symbol: "capsule.portrait", text: ctl.visibleSectionIDs.isEmpty ? "Нет доступных разделов. Включи модули или разделы в настройках острова" : "Раздел недоступен")
        }
    }
}
