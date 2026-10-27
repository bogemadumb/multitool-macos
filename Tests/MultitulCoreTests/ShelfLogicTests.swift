import Testing
import Foundation
import MultitulCtlCore
@testable import MultitulCore

@Suite struct ShelfPlacementTests {
    private let main = ShelfScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
    private let side = ShelfScreen(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
    private var both: [ShelfScreen] { [main, side] }
    private let size = CGSize(width: 340, height: 200)

    @Test func nearCursorSitsToTheRightAndCentersVertically() {
        let o = ShelfPlacement.origin(mode: .nearCursor, cursor: CGPoint(x: 400, y: 450), size: size, screens: both)
        #expect(o.x == 400 + ShelfPlacement.cursorOffset)
        #expect(o.y == 350)
    }

    @Test func nearCursorFlipsLeftAtTheScreenEdge() {
        let cursor = CGPoint(x: 1400, y: 450)
        let o = ShelfPlacement.origin(mode: .nearCursor, cursor: cursor, size: size, screens: [main])
        #expect(o.x + size.width <= cursor.x - ShelfPlacement.cursorOffset + 0.5)
        #expect(!CGRect(origin: o, size: size).contains(cursor))
    }

    @Test func nearCursorNeverLeavesTheVisibleArea() {
        for cursor in [CGPoint(x: 5, y: 5), CGPoint(x: 1435, y: 895), CGPoint(x: 720, y: 880), CGPoint(x: 1000, y: 0)] {
            let o = ShelfPlacement.origin(mode: .nearCursor, cursor: cursor, size: size, screens: [main])
            let r = CGRect(origin: o, size: size)
            #expect(main.visible.contains(r), "cursor \(cursor)")
        }
    }

    @Test func cursorOnTheSecondScreenUsesItsVisibleFrame() {
        let o = ShelfPlacement.origin(mode: .nearCursor, cursor: CGPoint(x: 3300, y: 1070), size: size, screens: both)
        let r = CGRect(origin: o, size: size)
        #expect(side.visible.contains(r))
        #expect(!main.visible.intersects(r))
    }

    @Test func cursorInTheMenuBarStripStillGetsAScreen() {
        let o = ShelfPlacement.origin(mode: .nearCursor, cursor: CGPoint(x: 700, y: 890), size: size, screens: both)
        #expect(main.visible.contains(CGRect(origin: o, size: size)))
    }

    @Test func edgeModesHugTheSideAndFollowTheCursorVertically() {
        let l = ShelfPlacement.origin(mode: .leftEdge, cursor: CGPoint(x: 700, y: 600), size: size, screens: [main])
        let r = ShelfPlacement.origin(mode: .rightEdge, cursor: CGPoint(x: 700, y: 600), size: size, screens: [main])
        #expect(l.x == ShelfPlacement.margin)
        #expect(r.x == 1440 - ShelfPlacement.margin - size.width)
        #expect(l.y == 500 && r.y == 500)
    }

    @Test func edgeModesOnTheSecondScreen() {
        let r = ShelfPlacement.origin(mode: .rightEdge, cursor: CGPoint(x: 2000, y: 500), size: size, screens: both)
        #expect(r.x == 1440 + 1920 - ShelfPlacement.margin - size.width)
    }

    @Test func belowStatusItemCentersUnderTheIconAndTouchesTheMenuBar() {
        let icon = CGRect(x: 1000, y: 875, width: 30, height: 25)
        let o = ShelfPlacement.belowStatusItem(icon: icon, size: size, screens: [main])
        #expect(o.x == icon.midX - size.width / 2)
        #expect(o.y == icon.minY - 4 - size.height)
    }

    @Test func belowStatusItemClampsAtTheRightEdge() {
        let icon = CGRect(x: 1420, y: 875, width: 30, height: 25)
        let o = ShelfPlacement.belowStatusItem(icon: icon, size: size, screens: [main])
        #expect(o.x + size.width <= main.visible.maxX)
    }

    @Test func screenLookupFallsBackToTheNearest() {
        #expect(ShelfPlacement.screen(containing: CGPoint(x: 100, y: 100), in: both) == main)
        #expect(ShelfPlacement.screen(containing: CGPoint(x: 5000, y: 100), in: both) == side)
        #expect(ShelfPlacement.screen(containing: CGPoint(x: -300, y: 100), in: both) == main)
        #expect(ShelfPlacement.screen(containing: .zero, in: []) == nil)
    }

    @Test func clampKeepsOversizedPanelsAtTheOrigin() {
        let p = ShelfPlacement.clamp(CGPoint(x: 50, y: 50), size: CGSize(width: 5000, height: 5000), in: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(p == .zero)
    }

    @Test func panelSizeGrowsWithItemsAndStopsAtSixRows() {
        let empty = ShelfPlacement.size(itemCount: 0)
        let one = ShelfPlacement.size(itemCount: 1)
        let six = ShelfPlacement.size(itemCount: 6)
        let twenty = ShelfPlacement.size(itemCount: 20)
        #expect(one.height > 0 && six.height > one.height)
        #expect(twenty == six)
        #expect(empty.width == one.width)
        #expect(ShelfPlacement.size(itemCount: 0, compact: true).height < empty.height)
    }
}

@Suite struct ShelfAutoHideTests {
    @Test func emptyShelfOpenedByHotkeyHidesWhenEmptied() {
        #expect(ShelfAutoHide.decide(.itemsChanged, isEmpty: true, autoHideEmpty: true, openedBy: .hotkey, hovering: true) == .hide(after: 0.35))
        #expect(ShelfAutoHide.decide(.dragOutCompleted, isEmpty: true, autoHideEmpty: true, openedBy: .shake, hovering: false) == .hide(after: 0.35))
    }

    @Test func settingOffKeepsTheShelf() {
        #expect(ShelfAutoHide.decide(.itemsChanged, isEmpty: true, autoHideEmpty: false, openedBy: .hotkey, hovering: false) == .keep)
    }

    @Test func nonEmptyShelfStays() {
        #expect(ShelfAutoHide.decide(.itemsChanged, isEmpty: false, autoHideEmpty: true, openedBy: .shake, hovering: false) == .keep)
    }

    @Test func shakeOpenedShelfThatReceivedNothingHides() {
        #expect(ShelfAutoHide.decide(.dragEnded(droppedOnShelf: false), isEmpty: true, autoHideEmpty: true, openedBy: .shake, hovering: false) == .hide(after: 1.0))
    }

    @Test func shakeOpenedShelfWithItemsStaysAfterAMissedDrop() {
        #expect(ShelfAutoHide.decide(.dragEnded(droppedOnShelf: false), isEmpty: false, autoHideEmpty: true, openedBy: .shake, hovering: false) == .keep)
    }

    @Test func menuBarDropZoneAlwaysFoldsAfterAMissedDrop() {
        #expect(ShelfAutoHide.decide(.dragEnded(droppedOnShelf: false), isEmpty: false, autoHideEmpty: true, openedBy: .menuBarDrag, hovering: false) == .hide(after: 1.0))
    }

    @Test func droppedOrHoveredShelfStays() {
        #expect(ShelfAutoHide.decide(.dragEnded(droppedOnShelf: true), isEmpty: false, autoHideEmpty: true, openedBy: .menuBarDrag, hovering: false) == .keep)
        #expect(ShelfAutoHide.decide(.dragEnded(droppedOnShelf: false), isEmpty: true, autoHideEmpty: true, openedBy: .shake, hovering: true) == .keep)
    }

    @Test func manuallyOpenedShelfIgnoresDragEnd() {
        #expect(ShelfAutoHide.decide(.dragEnded(droppedOnShelf: false), isEmpty: true, autoHideEmpty: true, openedBy: .hotkey, hovering: false) == .keep)
        #expect(ShelfAutoHide.decide(.dragEnded(droppedOnShelf: false), isEmpty: true, autoHideEmpty: true, openedBy: .menuBarClick, hovering: false) == .keep)
    }

    @Test func hiddenShelfNeedsNoDecision() {
        #expect(ShelfAutoHide.decide(.itemsChanged, isEmpty: true, autoHideEmpty: true, openedBy: nil, hovering: false) == .keep)
    }
}

@Suite struct ShelfArchiveTests {
    @Test func uniqueNameAddsCounter() {
        #expect(ShelfZip.uniqueName("a", ext: "zip", existing: []) == "a.zip")
        #expect(ShelfZip.uniqueName("a", ext: "zip", existing: ["a.zip"]) == "a 2.zip")
        #expect(ShelfZip.uniqueName("a", ext: "zip", existing: ["a.zip", "a 2.zip"]) == "a 3.zip")
        #expect(ShelfZip.uniqueName("a", ext: "", existing: ["a"]) == "a 2")
    }

    @Test func singleItemUsesItsOwnNameAndParent() throws {
        let p = try #require(ShelfZip.plan(paths: ["/u/Док/report.pdf"], outputDir: "/out", existing: [], stageName: ".s"))
        #expect(p.outputPath == "/out/report.pdf.zip")
        #expect(p.workDir == "/u/Док")
        #expect(p.names == ["report.pdf"])
        #expect(p.stageDir == nil)
    }

    @Test func siblingsShareTheParentWithoutStaging() throws {
        let p = try #require(ShelfZip.plan(paths: ["/u/a.txt", "/u/b.txt"], outputDir: "/out", existing: [], stageName: ".s"))
        #expect(p.outputPath == "/out/\(ShelfZip.multiName).zip")
        #expect(p.workDir == "/u")
        #expect(p.names == ["a.txt", "b.txt"])
        #expect(p.stageDir == nil)
    }

    @Test func differentParentsAreStagedThroughLinks() throws {
        let p = try #require(ShelfZip.plan(paths: ["/u/a.txt", "/v/a.txt", "/v/b.txt"], outputDir: "/out", existing: [], stageName: ".s"))
        #expect(p.stageDir == "/out/.s")
        #expect(p.workDir == "/out/.s")
        #expect(p.names == ["a.txt", "a 2.txt", "b.txt"])
        #expect(p.links.map(\.target) == ["/u/a.txt", "/v/a.txt", "/v/b.txt"])
    }

    @Test func sameNameInOneParentIsStaged() throws {
        let p = try #require(ShelfZip.plan(paths: ["/u/a.txt", "/u/a.txt"], outputDir: "/out", existing: [], stageName: ".s"))
        #expect(p.stageDir != nil)
    }

    @Test func existingArchivesAreNotOverwritten() throws {
        let p = try #require(ShelfZip.plan(paths: ["/u/a.txt"], outputDir: "/out", existing: ["a.txt.zip"], stageName: ".s"))
        #expect(p.outputPath == "/out/a.txt 2.zip")
    }

    @Test func nothingToArchive() {
        #expect(ShelfZip.plan(paths: [], outputDir: "/out", existing: [], stageName: ".s") == nil)
    }

    @Test func archiverRunsZipThroughShAndReturnsThePath() throws {
        let fs = ShfFS(), runner = ShfRunner()
        fs.addFile("/u/a.txt")
        fs.addFile("/u/b.txt")
        let a = ShelfArchiver(runner: runner, fs: fs, outputDir: "/out", stageName: { ".s" })
        let r = a.compress(["/u/a.txt", "/u/b.txt"])
        #expect(try r.get() == "/out/\(ShelfZip.multiName).zip")
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].0 == "/bin/sh")
        let args = runner.calls[0].1
        #expect(args.suffix(4) == ["/u", "/out/\(ShelfZip.multiName).zip", "a.txt", "b.txt"])
        #expect(args[2] == "sh")
        #expect(fs.madeDirs.contains("/out"))
    }

    @Test func archiverStagesAndCleansUpLinks() throws {
        let fs = ShfFS(), runner = ShfRunner()
        fs.addFile("/u/a.txt")
        fs.addFile("/v/b.txt")
        let a = ShelfArchiver(runner: runner, fs: fs, outputDir: "/out", stageName: { ".s" })
        _ = try a.compress(["/u/a.txt", "/v/b.txt"]).get()
        #expect(fs.links.count == 2)
        #expect(fs.removed.contains("/out/.s"))
    }

    @Test func archiverSkipsVanishedFiles() throws {
        let fs = ShfFS(), runner = ShfRunner()
        fs.addFile("/u/a.txt")
        let a = ShelfArchiver(runner: runner, fs: fs, outputDir: "/out", stageName: { ".s" })
        _ = try a.compress(["/u/a.txt", "/u/gone.txt"]).get()
        #expect(runner.calls[0].1.suffix(1) == ["a.txt"])
    }

    @Test func archiverReportsNothingToArchive() {
        let a = ShelfArchiver(runner: ShfRunner(), fs: ShfFS(), outputDir: "/out", stageName: { ".s" })
        #expect(a.compress(["/u/none"]) == .failure(.nothingToArchive))
    }

    @Test func archiverFailureRemovesHalfWrittenZip() {
        let fs = ShfFS(), runner = ShfRunner()
        fs.addFile("/u/a.txt")
        runner.result = ProcessOutput(status: 12, stderr: "zip error: boom")
        let a = ShelfArchiver(runner: runner, fs: fs, outputDir: "/out", stageName: { ".s" })
        let r = a.compress(["/u/a.txt"])
        #expect(r == .failure(.failed("zip error: boom")))
        #expect(fs.removed.contains("/out/a.txt.zip"))
    }

    @Test func archiverTimeoutIsAFailure() {
        let fs = ShfFS(), runner = ShfRunner()
        fs.addFile("/u/a.txt")
        runner.result = ProcessOutput(status: 0, timedOut: true)
        let a = ShelfArchiver(runner: runner, fs: fs, outputDir: "/out", stageName: { ".s" })
        if case .success = a.compress(["/u/a.txt"]) { Issue.record("must fail") }
    }
}

@Suite struct ShelfSettingsTests {
    private func fresh() -> (InMemoryKeyValueStore, String) {
        let suite = "shelf-test-\(UUID().uuidString)"
        return (InMemoryKeyValueStore(), suite)
    }

    @Test func defaultsMatchTheCatalog() {
        let s = ShelfSettings()
        #expect(s.shakeEnabled && s.menuBarIcon && s.menuBarDrop && s.autoHideEmpty)
        #expect(!s.closeAfterDrop && !s.deleteAfterDrop)
        #expect(s.excludedApps.isEmpty)
        #expect(s.placement == .nearCursor && s.shakeSensitivity == .medium)
    }

    @Test func roundTripThroughDefaults() {
        let (d, suite) = fresh()
        let st = ShelfSettingsStore(defaults: d)
        var s = ShelfSettings()
        s.closeAfterDrop = true
        s.deleteAfterDrop = true
        s.shakeEnabled = false
        s.shakeSensitivity = .high
        s.excludedApps = ["com.adobe.photoshop", "com.figma.Desktop"]
        s.menuBarIcon = false
        s.menuBarDrop = false
        s.placement = .rightEdge
        s.autoHideEmpty = false
        st.save(s)
        #expect(st.load() == s)
    }

    @Test func defaultsAreNotWrittenToTheStore() {
        let (d, suite) = fresh()
        let st = ShelfSettingsStore(defaults: d)
        st.save(ShelfSettings())
        #expect(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("shelf.") }.isEmpty)
    }

    @Test func excludedAppsAreTrimmedAndDeduped() {
        var s = ShelfSettings()
        s.excludedApps = [" a.b ", "a.b", "", "  ", "c.d"]
        #expect(s.sanitized.excludedApps == ["a.b", "c.d"])
    }

    @Test func garbageInDefaultsFallsBackToDefaults() {
        let (d, suite) = fresh()
        d.set("loud", forKey: "shelf.shakeSensitivity")
        d.set("middle", forKey: "shelf.placement")
        d.set("yes", forKey: "shelf.shakeEnabled")
        let s = ShelfSettingsStore(defaults: d).load()
        #expect(s.shakeSensitivity == .medium && s.placement == .nearCursor && s.shakeEnabled)
    }

    @Test func settingKeysAreAscii() {
        let (d, suite) = fresh()
        var s = ShelfSettings()
        s.closeAfterDrop = true; s.deleteAfterDrop = true; s.shakeEnabled = false; s.shakeSensitivity = .low
        s.excludedApps = ["x"]; s.menuBarIcon = false; s.menuBarDrop = false; s.placement = .leftEdge; s.autoHideEmpty = false
        ShelfSettingsStore(defaults: d).save(s)
        let keys = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("shelf.") }
        #expect(keys.count == 9)
        #expect(keys.allSatisfy { $0.unicodeScalars.allSatisfy { $0.isASCII } })
    }

    @Test func moduleLivesInTheClipGroupWithoutPermissions() {
        let info = ModuleID.shelf.info
        #expect(info.group == .clip)
        #expect(info.permissions.isEmpty)
        #expect(!info.enabledByDefault)
        #expect(info.hotkeys == [ShelfHotkeys.toggle])
        #expect(ShelfHotkeys.toggle.defaultCombo.isNone)
        #expect(ModuleID.shelf.rawValue.allSatisfy { $0.isASCII } && ModuleID.shelf.enabledKey.allSatisfy { $0.isASCII })
        #expect(ShelfHotkeys.toggle.id.allSatisfy { $0.isASCII })
    }

    @Test func hotkeyIdsStayUniqueAcrossModules() {
        let all = ModuleID.allCases.flatMap { $0.info.hotkeys.map(\.id) }
        #expect(Set(all).count == all.count)
    }

    @Test func pathsAreAsciiAndSeparate() {
        let dirs = [MultitulPaths.shelfFilesDir, MultitulPaths.shelfOutDir, MultitulPaths.shelfArchivesDir]
        #expect(Set(dirs).count == 3)
        #expect(dirs.allSatisfy { ($0 as NSString).lastPathComponent.unicodeScalars.allSatisfy { $0.isASCII } })
    }

    @Test func openReasonsThatPopUpOnTheirOwn() {
        #expect(ShelfOpenReason.shake.isAutomatic && ShelfOpenReason.menuBarDrag.isAutomatic)
        #expect(!ShelfOpenReason.hotkey.isAutomatic && !ShelfOpenReason.menuBarClick.isAutomatic && !ShelfOpenReason.tile.isAutomatic)
    }
}
