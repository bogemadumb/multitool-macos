import Testing
import Foundation
import AppKit
@testable import MultitulCore

final class FndFakeFinder: FinderScripting {
    var selection: [String] = []
    var folder: String? = "/Users/me/Dest"
    var movedBatches: [(paths: [String], to: String)] = []
    var results: [Bool]?

    func selectedPaths() -> [String] { selection }
    func currentFolderPath() -> String? { folder }
    func move(_ paths: [String], to folder: String) -> [Bool] {
        movedBatches.append((paths, folder))
        return results ?? paths.map { _ in true }
    }
}

final class FndFakeFiles: FinderFiles {
    var present: Set<String> = []
    var dirs: Set<String> = []
    var written: [(path: String, size: Int)] = []
    var writeError: Error?

    func exists(_ path: String) -> Bool { present.contains(path) }
    func isDirectory(_ path: String) -> Bool { dirs.contains(path) }
    func write(_ data: Data, to path: String) throws {
        if let writeError { throw writeError }
        written.append((path, data.count))
        present.insert(path)
    }
}

@Suite struct FinderRouterTests {
    private let finder = "com.apple.finder"
    private func cmd(_ code: UInt32, rep: Bool = false) -> KeyStroke { KeyStroke(keyCode: code, modifiers: KeyCombo.cmd, isRepeat: rep) }

    @Test func commandXInFinderCuts() {
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyX), ctx: FinderContext(frontmostBundleID: finder), pasteImage: true) == .cut)
    }

    @Test func otherAppsAndTextFieldsAreNeverIntercepted() {
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyX), ctx: FinderContext(frontmostBundleID: "com.apple.Safari"), pasteImage: true) == .pass)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyX), ctx: FinderContext(frontmostBundleID: finder, focusIsText: true), pasteImage: true) == .pass)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyV), ctx: FinderContext(frontmostBundleID: finder, focusIsText: true, hasCut: true), pasteImage: true) == .pass)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyX), ctx: FinderContext(frontmostBundleID: nil), pasteImage: true) == .pass)
    }

    @Test func commandVMovesOnlyWhenSomethingIsCut() {
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyV), ctx: FinderContext(frontmostBundleID: finder), pasteImage: true) == .pass)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyV), ctx: FinderContext(frontmostBundleID: finder, hasCut: true), pasteImage: true) == .pasteMove)
    }

    @Test func imageOnClipboardSavesPngUnlessFilesArePresentOrOptionIsOff() {
        let img = FinderContext(frontmostBundleID: finder, clipboardHasImage: true)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyV), ctx: img, pasteImage: true) == .pasteImage)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyV), ctx: img, pasteImage: false) == .pass)
        let both = FinderContext(frontmostBundleID: finder, clipboardHasImage: true, clipboardHasFiles: true)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyV), ctx: both, pasteImage: true) == .pass)
    }

    @Test func cutBeatsImageWhenBothApply() {
        let ctx = FinderContext(frontmostBundleID: finder, hasCut: true, clipboardHasImage: true)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyV), ctx: ctx, pasteImage: true) == .pasteMove)
    }

    @Test func autoRepeatIsSwallowedSoFinderDoesNotCopyTheFiles() {
        let ctx = FinderContext(frontmostBundleID: finder, hasCut: true)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyV, rep: true), ctx: ctx, pasteImage: true) == .swallow)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyX, rep: true), ctx: FinderContext(frontmostBundleID: finder), pasteImage: true) == .swallow)
        #expect(FinderCutRouter.route(cmd(FinderKeys.keyV, rep: true), ctx: FinderContext(frontmostBundleID: finder), pasteImage: true) == .pass)
    }

    @Test func extraModifiersAndOtherKeysPass() {
        let ctx = FinderContext(frontmostBundleID: finder, hasCut: true)
        #expect(FinderCutRouter.route(KeyStroke(keyCode: FinderKeys.keyV, modifiers: KeyCombo.cmd | KeyCombo.opt), ctx: ctx, pasteImage: true) == .pass)
        #expect(FinderCutRouter.route(KeyStroke(keyCode: FinderKeys.keyV, modifiers: KeyCombo.cmd | KeyCombo.shift), ctx: ctx, pasteImage: true) == .pass)
        #expect(FinderCutRouter.route(KeyStroke(keyCode: 8, modifiers: KeyCombo.cmd), ctx: ctx, pasteImage: true) == .pass)
        #expect(FinderCutRouter.route(KeyStroke(keyCode: FinderKeys.keyV, modifiers: 0), ctx: ctx, pasteImage: true) == .pass)
    }

    @Test func renameFiresOnlyOnTheConfiguredComboInFinder() {
        let f2 = KeyCombo(keyCode: FinderKeys.keyF2, modifiers: 0)
        let ctx = FinderContext(frontmostBundleID: finder)
        #expect(FinderRenameRouter.shouldRename(KeyStroke(keyCode: 120, modifiers: 0), ctx: ctx, combo: f2))
        #expect(!FinderRenameRouter.shouldRename(KeyStroke(keyCode: 120, modifiers: KeyCombo.cmd), ctx: ctx, combo: f2))
        #expect(!FinderRenameRouter.shouldRename(KeyStroke(keyCode: 99, modifiers: 0), ctx: ctx, combo: f2))
        #expect(!FinderRenameRouter.shouldRename(KeyStroke(keyCode: 120, modifiers: 0), ctx: FinderContext(frontmostBundleID: "com.apple.TextEdit"), combo: f2))
        #expect(!FinderRenameRouter.shouldRename(KeyStroke(keyCode: 120, modifiers: 0), ctx: FinderContext(frontmostBundleID: finder, focusIsText: true), combo: f2))
    }

    @Test func unassignedRenameNeverFires() {
        #expect(!FinderRenameRouter.shouldRename(KeyStroke(keyCode: 0xFFFF, modifiers: 0), ctx: FinderContext(frontmostBundleID: finder), combo: .none))
    }

    @Test func renameWithCustomComboAndAutoRepeat() {
        let combo = KeyCombo(keyCode: 15, modifiers: KeyCombo.ctrl)
        let ctx = FinderContext(frontmostBundleID: finder)
        #expect(FinderRenameRouter.shouldRename(KeyStroke(keyCode: 15, modifiers: KeyCombo.ctrl), ctx: ctx, combo: combo))
        let rep = KeyStroke(keyCode: 15, modifiers: KeyCombo.ctrl, isRepeat: true)
        #expect(!FinderRenameRouter.shouldRename(rep, ctx: ctx, combo: combo))
        #expect(FinderRenameRouter.shouldSwallow(rep, ctx: ctx, combo: combo))
    }

    @Test func focusRolesThatMeanTyping() {
        #expect(FocusRole.isTextInput(role: "AXTextField", subrole: nil))
        #expect(FocusRole.isTextInput(role: "AXTextArea", subrole: nil))
        #expect(FocusRole.isTextInput(role: "AXComboBox", subrole: nil))
        #expect(FocusRole.isTextInput(role: "AXGroup", subrole: "AXSearchField"))
        #expect(!FocusRole.isTextInput(role: "AXOutline", subrole: nil))
        #expect(!FocusRole.isTextInput(role: "AXList", subrole: "AXSortButton"))
        #expect(!FocusRole.isTextInput(role: nil, subrole: nil))
    }

    @Test func modifierFlagsMapToCarbonBits() {
        #expect(KeyStroke.modifiers(from: [.maskCommand]) == KeyCombo.cmd)
        #expect(KeyStroke.modifiers(from: [.maskCommand, .maskShift, .maskAlternate, .maskControl]) == KeyCombo.cmd | KeyCombo.shift | KeyCombo.opt | KeyCombo.ctrl)
        #expect(KeyStroke.modifiers(from: [.maskSecondaryFn, .maskNonCoalesced]) == 0)
    }
}

@Suite struct FinderMovePlannerTests {
    private func files(_ present: [String]) -> FndFakeFiles {
        let f = FndFakeFiles()
        f.present = Set(present)
        return f
    }

    @Test func plainMovesAreAccepted() {
        let p = FinderMovePlanner.plan(sources: ["/a/x.txt", "/a/y.txt"], destination: "/b", files: files(["/a/x.txt", "/a/y.txt", "/b"]))
        #expect(p.moves == ["/a/x.txt", "/a/y.txt"])
        #expect(p.skipped.isEmpty)
    }

    @Test func sameFolderMissingAndCollidingAreSkippedWithReasons() {
        let f = files(["/b/x.txt", "/a/y.txt", "/a/z.txt", "/a/exists.txt", "/b/exists.txt"])
        let p = FinderMovePlanner.plan(sources: ["/b/x.txt", "/a/gone.txt", "/a/exists.txt", "/a/y.txt"], destination: "/b", files: f)
        #expect(p.moves == ["/a/y.txt"])
        #expect(p.skipped.map(\.reason) == [.sameFolder, .missing, .nameExists])
    }

    @Test func folderCannotMoveIntoItselfOrItsChild() {
        let f = files(["/a/dir", "/a/dir/sub"])
        #expect(FinderMovePlanner.plan(sources: ["/a/dir"], destination: "/a/dir", files: f).skipped.map(\.reason) == [.intoItself])
        #expect(FinderMovePlanner.plan(sources: ["/a/dir"], destination: "/a/dir/sub", files: f).skipped.map(\.reason) == [.intoItself])
    }

    @Test func siblingWithSharedPrefixIsNotMistakenForAChild() {
        let f = files(["/a/dir"])
        let p = FinderMovePlanner.plan(sources: ["/a/dir"], destination: "/a/directory", files: f)
        #expect(p.moves == ["/a/dir"])
    }

    @Test func duplicatesAndNestedSelectionsAreCollapsed() {
        let f = files(["/a/dir", "/a/dir/inner.txt"])
        let p = FinderMovePlanner.plan(sources: ["/a/dir/", "/a/dir", "/a/dir/inner.txt"], destination: "/b", files: f)
        #expect(p.moves == ["/a/dir"])
        #expect(p.skipped.isEmpty)
    }

    @Test func sameNamesFromDifferentFoldersDoNotBothMove() {
        let f = files(["/a/x.txt", "/c/x.txt"])
        let p = FinderMovePlanner.plan(sources: ["/a/x.txt", "/c/x.txt"], destination: "/b", files: f)
        #expect(p.moves == ["/a/x.txt"])
        #expect(p.skipped.map(\.reason) == [.nameExists])
    }

    @Test func rootDestinationAndTrailingSlashesNormalise() {
        #expect(FinderPaths.normalized("/a/b///") == "/a/b")
        #expect(FinderPaths.normalized("/") == "/")
        #expect(FinderPaths.parent("/a") == "/")
        #expect(FinderPaths.parent("/a/b/") == "/a")
        #expect(FinderPaths.parsePaths("/a/b/\n/c d/\nnot a path\n\n") == ["/a/b", "/c d"])
    }
}

@Suite struct FinderScriptsTests {
    @Test func quotingEscapesBackslashAndQuotes() {
        #expect(FinderScripts.quote("a\"b\\c") == "\"a\\\"b\\\\c\"")
        #expect(FinderScripts.quote("Файл №1") == "\"Файл №1\"")
    }

    @Test func moveScriptListsEveryPathAndTheDestination() {
        let s = FinderScripts.move(["/a/x \"1\".txt", "/a/y.txt"], to: "/b/папка")
        #expect(s.contains("{\"/a/x \\\"1\\\".txt\", \"/a/y.txt\"}"))
        #expect(s.contains("POSIX file \"/b/папка\""))
        #expect(s.contains("tell application \"Finder\""))
    }

    @Test func moveResultsParseLineByLine() {
        #expect(FinderScripts.parseMoveResults("ok\nerr\nok", count: 3) == [true, false, true])
        #expect(FinderScripts.parseMoveResults("ok", count: 3) == [true, false, false])
        #expect(FinderScripts.parseMoveResults("", count: 2) == [false, false])
    }

    @Test func staticScriptsTargetFinderOnly() {
        #expect(FinderScripts.selection.hasPrefix("tell application \"Finder\""))
        #expect(FinderScripts.currentFolder.contains("target of front Finder window"))
    }
}

@Suite struct FinderCutPasteEngineTests {
    private func make(selection: [String] = ["/src/a.txt", "/src/b.txt"], present: [String] = ["/src/a.txt", "/src/b.txt", "/Users/me/Dest"]) -> (ClpFakePasteboard, FndFakeFinder, FndFakeFiles, FinderCutPasteEngine, () -> [String]) {
        let pb = ClpFakePasteboard()
        let fin = FndFakeFinder()
        fin.selection = selection
        let files = FndFakeFiles()
        files.present = Set(present)
        var messages: [String] = []
        let e = FinderCutPasteEngine(pasteboard: pb, finder: fin, files: files, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        e.onMessage = { messages.append($0) }
        return (pb, fin, files, e, { messages })
    }

    @Test func cutPutsFileUrlsOnTheClipboardAndRemembersThem() {
        let (pb, _, _, e, msgs) = make()
        e.cutSelection()
        #expect(e.hasCut)
        #expect(e.cut?.paths == ["/src/a.txt", "/src/b.txt"])
        #expect(pb.items.count == 2)
        #expect(pb.items.allSatisfy { $0.reps[PBType.fileURL] != nil })
        #expect(msgs() == ["Вырезано: 2"])
    }

    @Test func cutWithEmptySelectionSaysSo() {
        let (pb, _, _, e, msgs) = make(selection: [])
        e.cutSelection()
        #expect(!e.hasCut)
        #expect(pb.writes == 0)
        #expect(msgs().first?.hasPrefix("Нечего вырезать") == true)
    }

    @Test func pasteMovesIntoTheCurrentFolderAndClearsEverything() {
        let (pb, fin, _, e, msgs) = make()
        var changes: [Bool] = []
        e.onChange = { changes.append($0 != nil) }
        e.cutSelection()
        e.pasteMove()
        #expect(fin.movedBatches.count == 1)
        #expect(fin.movedBatches[0].paths == ["/src/a.txt", "/src/b.txt"])
        #expect(fin.movedBatches[0].to == "/Users/me/Dest")
        #expect(!e.hasCut)
        #expect(pb.items.isEmpty)
        #expect(changes == [true, false])
        #expect(msgs().last == "Перемещено: 2")
    }

    @Test func copyingSomethingElseCancelsTheCut() {
        let (pb, fin, _, e, _) = make()
        var changes: [Bool] = []
        e.onChange = { changes.append($0 != nil) }
        e.cutSelection()
        pb.externalText("другое копирование")
        #expect(!e.hasCut)
        e.pasteMove()
        #expect(fin.movedBatches.isEmpty)
        #expect(changes == [true, false])
    }

    @Test func pasteIntoTheSameFolderMovesNothing() {
        let (_, fin, _, e, msgs) = make()
        fin.folder = "/src"
        e.cutSelection()
        e.pasteMove()
        #expect(fin.movedBatches.isEmpty)
        #expect(msgs().last == "Файлы уже в этой папке")
        #expect(!e.hasCut)
    }

    @Test func collisionsAreSkippedAndReported() {
        let (_, fin, _, e, msgs) = make(present: ["/src/a.txt", "/src/b.txt", "/Users/me/Dest/a.txt"])
        e.cutSelection()
        e.pasteMove()
        #expect(fin.movedBatches[0].paths == ["/src/b.txt"])
        #expect(msgs().last == "Перемещено: 1 · пропущено 1: такое имя уже есть")
    }

    @Test func finderFailuresAreCounted() {
        let (_, fin, _, e, msgs) = make()
        fin.results = [true, false]
        e.cutSelection()
        e.pasteMove()
        #expect(msgs().last == "Перемещено: 1 · ошибок Finder: 1")
    }

    @Test func noOpenFolderKeepsTheCutAlive() {
        let (_, fin, _, e, msgs) = make()
        e.cutSelection()
        fin.folder = nil
        e.pasteMove()
        #expect(e.hasCut)
        #expect(msgs().last == "Сюда вставить нельзя: нет открытой папки")
    }

    @Test func cancelDropsTheCut() {
        let (_, _, _, e, msgs) = make()
        e.cutSelection()
        e.cancel()
        #expect(!e.hasCut)
        #expect(msgs().last == "Вырезание отменено")
        e.cancel()
        #expect(msgs().count == 2)
    }

    @Test func pastingAnImageWritesAPngWithAUniqueName() {
        let (pb, _, files, e, msgs) = make()
        pb.external([PasteboardItemData(reps: [PBType.png: Clp.png()])])
        e.pasteImage()
        e.pasteImage()
        #expect(files.written.count == 2)
        #expect(files.written[0].path.hasPrefix("/Users/me/Dest/Изображение "))
        #expect(files.written[0].path.hasSuffix(".png"))
        #expect(files.written[1].path.hasSuffix(" 2.png"))
        #expect(msgs().count == 2)
        #expect(!pb.items.isEmpty)
    }

    @Test func tiffClipboardIsConvertedToPng() {
        let (pb, _, files, e, _) = make()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 5, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let tiff = rep.tiffRepresentation!
        pb.external([PasteboardItemData(reps: [PBType.tiff: tiff])])
        e.pasteImage()
        #expect(files.written.count == 1)
    }

    @Test func imageWriteFailureIsReported() {
        let (pb, _, files, e, msgs) = make()
        files.writeError = CocoaError(.fileWriteNoPermission)
        pb.external([PasteboardItemData(reps: [PBType.png: Clp.png()])])
        e.pasteImage()
        #expect(msgs().last?.hasPrefix("Не удалось сохранить картинку") == true)
    }

    @Test func imageNamerFormatsTheDateAndAvoidsCollisions() {
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        let tz = TimeZone(identifier: "Europe/Moscow")!
        let name = ImageFileNamer.name(date: d, exists: { _ in false }, timeZone: tz)
        #expect(name == "Изображение 2027-01-15 в 11.00.00.png")
        var taken: Set<String> = [name, "Изображение 2027-01-15 в 11.00.00 2.png"]
        #expect(ImageFileNamer.name(date: d, exists: { taken.contains($0) }, timeZone: tz) == "Изображение 2027-01-15 в 11.00.00 3.png")
        taken = []
        #expect(ImageFileNamer.pngData(png: nil, tiff: Data([1, 2, 3])) == nil)
    }
}
