import Testing
import Foundation
@testable import MultitulCore

@Suite struct ShelfServiceTests {
    private func world() -> (ShelfService, ShfFS) {
        let fs = ShfFS()
        return (Shf.service(fs: fs), fs)
    }

    @Test func addingMixedContentReportsCounts() {
        let (svc, fs) = world()
        fs.addFile("/u/a.txt")
        let r = svc.add([.file(path: "/u/a.txt", owned: false), .text("заметка"), .url("https://e.com", title: nil), .file(path: "/u/missing", owned: false)])
        #expect(r.added.count == 3)
        #expect(r.skipped == 1)
        #expect(svc.count == 3)
        #expect(Set(svc.items.map(\.kind)) == [.file, .text, .url])
    }

    @Test func addingTheSameThingTwiceDedupes() {
        let (svc, _) = world()
        _ = svc.add([.text("same")])
        let r = svc.add([.text("same")])
        #expect(r.added.isEmpty)
        #expect(r.deduped.count == 1)
        #expect(svc.count == 1)
    }

    @Test func sameFileDroppedFromTwoPathsFormsDedupes() {
        let (svc, fs) = world()
        fs.addFile("/u/a.txt")
        _ = svc.add([.file(path: "/u/a.txt", owned: false)])
        let r = svc.add([.file(path: "/u/x/../a.txt", owned: false)])
        #expect(r.deduped.count == 1)
        #expect(svc.count == 1)
    }

    @Test func onChangeFiresOnAddRemoveClear() {
        let (svc, _) = world()
        var n = 0
        svc.onChange = { n += 1 }
        let r = svc.add([.text("a b")])
        svc.remove(r.ids)
        _ = svc.add([.text("c d")])
        svc.clear()
        #expect(n == 4)
    }

    @Test func nothingAddedMeansNoChangeCallback() {
        let (svc, _) = world()
        var n = 0
        svc.onChange = { n += 1 }
        _ = svc.add([.file(path: "/none", owned: false), .text("  ")])
        svc.remove([999])
        svc.clear()
        #expect(n == 0)
    }

    @Test func clearKeepsPinnedByDefault() {
        let (svc, _) = world()
        let r = svc.add([.text("keep me"), .text("drop me")])
        svc.setPinned([r.added[0]], true)
        svc.clear()
        #expect(svc.items.map(\.title) == ["keep me"])
        svc.clear(keepPinned: false)
        #expect(svc.isEmpty)
    }

    @Test func togglePinFlipsAndPersists() {
        let (svc, _) = world()
        let id = svc.add([.text("pin")]).added[0]
        svc.togglePin(id)
        #expect(svc.item(id: id)?.pinned == true)
        svc.togglePin(id)
        #expect(svc.item(id: id)?.pinned == false)
    }

    @Test func limitDropsOldestUnpinnedOnly() {
        let (svc, _) = world()
        let pinned = svc.add([.text("pinned one")]).added[0]
        svc.setPinned([pinned], true)
        for i in 0..<(ShelfLimits.maxItems + 5) { _ = svc.add([.text("note \(i)")]) }
        #expect(svc.count == ShelfLimits.maxItems + 1)
        #expect(svc.item(id: pinned) != nil)
        #expect(svc.items.first { $0.title == "note 0" } == nil)
        #expect(svc.items.first { $0.title == "note \(ShelfLimits.maxItems + 4)" } != nil)
    }

    @Test func resolveUsesBookmarkWhenFileMoved() {
        let (svc, fs) = world()
        fs.addFile("/u/a.txt")
        let id = svc.add([.file(path: "/u/a.txt", owned: false)]).added[0]
        fs.move("/u/a.txt", "/v/renamed.txt")
        let st = svc.resolve(svc.item(id: id)!)
        #expect(st == .relocated(path: "/v/renamed.txt"))
        #expect(svc.item(id: id)?.path == "/v/renamed.txt")
        #expect(svc.resolve(svc.item(id: id)!) == .ok(path: "/v/renamed.txt"))
    }

    @Test func resolveRefreshesStaleBookmark() throws {
        let (svc, fs) = world()
        fs.addFile("/u/a.txt")
        let id = svc.add([.file(path: "/u/a.txt", owned: false)]).added[0]
        let old = try #require(svc.payload(of: id)?.bookmark)
        fs.staleBookmarks.insert(old)
        #expect(svc.resolve(svc.item(id: id)!) == .ok(path: "/u/a.txt"))
        #expect(svc.payload(of: id)?.bookmark != old)
    }

    @Test func missingFileFallsBackToMissingState() {
        let (svc, fs) = world()
        fs.addFile("/u/a.txt")
        let id = svc.add([.file(path: "/u/a.txt", owned: false)]).added[0]
        fs.files["/u/a.txt"] = nil
        let st = svc.resolve(svc.item(id: id)!)
        #expect(st == .missing(lastPath: "/u/a.txt"))
        #expect(st.isMissing)
        #expect(st.path == nil)
    }

    @Test func brokenBookmarkFallsBackToStoredPath() {
        let (svc, fs) = world()
        fs.addFile("/u/a.txt")
        let id = svc.add([.file(path: "/u/a.txt", owned: false)]).added[0]
        fs.bookmarkTargets = [:]
        #expect(svc.resolve(svc.item(id: id)!) == .ok(path: "/u/a.txt"))
        #expect(svc.payload(of: id)?.bookmark != nil)
    }

    @Test func itemWithoutBookmarkGetsOneOnFirstResolve() {
        let fs = ShfFS()
        fs.failBookmarks = true
        fs.addFile("/u/a.txt")
        let svc = Shf.service(fs: fs)
        let id = svc.add([.file(path: "/u/a.txt", owned: false)]).added[0]
        #expect(svc.payload(of: id)?.bookmark == nil)
        fs.failBookmarks = false
        #expect(svc.resolve(svc.item(id: id)!) == .ok(path: "/u/a.txt"))
        #expect(svc.payload(of: id)?.bookmark != nil)
    }

    @Test func bookmarkPointingToDeletedPlaceFallsThroughToMissing() {
        let (svc, fs) = world()
        fs.addFile("/u/a.txt")
        let id = svc.add([.file(path: "/u/a.txt", owned: false)]).added[0]
        _ = fs.remove("/u/a.txt")
        #expect(svc.resolve(svc.item(id: id)!).isMissing)
    }

    @Test func textItemsHaveNoFileState() {
        let (svc, _) = world()
        let id = svc.add([.text("hello there")]).added[0]
        #expect(svc.resolve(svc.item(id: id)!) == .missing(lastPath: nil))
        #expect(svc.states().isEmpty)
    }

    @Test func statesCoverEveryPathItem() {
        let (svc, fs) = world()
        fs.addFile("/u/a.txt")
        fs.addDir("/u/dir")
        let ids = svc.add([.file(path: "/u/a.txt", owned: false), .file(path: "/u/dir", owned: false), .text("x y")]).added
        fs.files["/u/a.txt"] = nil
        let st = svc.states()
        #expect(st.count == 2)
        #expect(st[ids[0]]?.isMissing == true)
        #expect(st[ids[1]] == .ok(path: "/u/dir"))
    }

    @Test func dragPlanGroupsFilesAndSkipsMissing() {
        let (svc, fs) = world()
        fs.addFile("/u/a.txt")
        fs.addFile("/u/b.txt")
        fs.addFile("/u/gone.txt")
        let ids = svc.add([.file(path: "/u/a.txt", owned: false), .text("middle text"), .file(path: "/u/b.txt", owned: false), .file(path: "/u/gone.txt", owned: false), .url("https://e.com", title: nil)]).added
        fs.files["/u/gone.txt"] = nil
        let plan = svc.dragPlan(ids)
        #expect(plan.missing.count == 1)
        #expect(plan.payloads.count == 3)
        var files: [String] = []
        for p in plan.payloads { if case .files(let f) = p { files = f } }
        #expect(Set(files) == ["/u/a.txt", "/u/b.txt"])
        #expect(plan.payloads.contains(.text("middle text")))
        #expect(plan.payloads.contains(.url("https://e.com")))
    }

    @Test func dragPlanForImageCarriesBytesAndName() {
        let (svc, _) = world()
        let data = Data([1, 2, 3, 4])
        let id = svc.add([.image(data, ext: "png", name: "снимок")]).added[0]
        #expect(svc.dragPlan([id]).payloads == [.image(data, ext: "png", name: "снимок")])
    }

    @Test func dropDeletesUnpinnedWhenAsked() {
        var s = ShelfSettings()
        s.deleteAfterDrop = true
        let svc = Shf.service(settings: s)
        let r = svc.add([.text("one one"), .text("two two")])
        svc.setPinned([r.added[0]], true)
        let out = svc.dragCompleted(ids: r.added, accepted: true)
        #expect(out.removed == [r.added[1]])
        #expect(svc.items.map(\.title) == ["one one"])
    }

    @Test func cancelledDragChangesNothing() {
        var s = ShelfSettings()
        s.deleteAfterDrop = true
        s.closeAfterDrop = true
        let svc = Shf.service(settings: s)
        let r = svc.add([.text("one one")])
        let out = svc.dragCompleted(ids: r.added, accepted: false)
        #expect(out == ShelfAfterDrop())
        #expect(svc.count == 1)
    }

    @Test func dropKeepsItemsByDefaultAndClosesOnRequest() {
        let svc = Shf.service()
        let r = svc.add([.text("stay here")])
        #expect(svc.dragCompleted(ids: r.added, accepted: true) == ShelfAfterDrop())
        svc.settings.closeAfterDrop = true
        #expect(svc.dragCompleted(ids: r.added, accepted: true).closeShelf)
    }

    @Test func emptyShelfAfterDropClosesWhenAutoHide() {
        var s = ShelfSettings()
        s.deleteAfterDrop = true
        s.autoHideEmpty = true
        let svc = Shf.service(settings: s)
        let r = svc.add([.text("only one")])
        let out = svc.dragCompleted(ids: r.added, accepted: true)
        #expect(out.closeShelf)
        s.autoHideEmpty = false
        let svc2 = Shf.service(settings: s)
        let r2 = svc2.add([.text("only one")])
        #expect(!svc2.dragCompleted(ids: r2.added, accepted: true).closeShelf)
    }

    @Test func removingAnOwnedFileDeletesItsContainer() {
        let (svc, fs) = world()
        fs.addFile("/shelf/files/u1/photo.png")
        fs.addFile("/Users/x/real.png")
        let ids = svc.add([.file(path: "/shelf/files/u1/photo.png", owned: true), .file(path: "/Users/x/real.png", owned: false)]).added
        svc.remove(ids)
        #expect(fs.removed == ["/shelf/files/u1"])
        #expect(fs.files["/Users/x/real.png"] != nil)
    }

    @Test func ownedContainerOnlyInsideOwnedDirs() {
        let dirs = [Shf.owned, Shf.archives]
        #expect(ShelfService.ownedContainer(of: "/shelf/files/u1/a.png", dirs: dirs) == "/shelf/files/u1")
        #expect(ShelfService.ownedContainer(of: "/shelf/archives/Архив.zip", dirs: dirs) == "/shelf/archives/Архив.zip")
        #expect(ShelfService.ownedContainer(of: "/shelf/files", dirs: dirs) == nil)
        #expect(ShelfService.ownedContainer(of: "/Users/x/a.png", dirs: dirs) == nil)
        #expect(ShelfService.ownedContainer(of: "/shelf/filesX/a.png", dirs: dirs) == nil)
    }

    @Test func orphanCleanupKeepsReferencedAndClearsTheRest() {
        let (svc, fs) = world()
        fs.addFile("/shelf/files/keep/a.png")
        fs.addFile("/shelf/files/stale/b.png")
        fs.addFile("/shelf/archives/old.zip")
        fs.addFile("/shelf/out/x1/t.txt")
        fs.addFile("/Users/x/free.png")
        _ = svc.add([.file(path: "/shelf/files/keep/a.png", owned: true)])
        let removed = svc.cleanupOrphans()
        #expect(Set(removed) == ["/shelf/files/stale", "/shelf/archives/old.zip", "/shelf/out/x1"])
        #expect(fs.files["/shelf/files/keep/a.png"] != nil)
        #expect(fs.files["/Users/x/free.png"] != nil)
    }

    @Test func orphansPureFunction() {
        let o = ShelfMaintenance.orphans(listing: ["a", "b", "c"], dir: "/d", referenced: ["/d/b"])
        #expect(o == ["/d/a", "/d/c"])
    }

    @Test func resolvedPathsSkipMissingAndNonPathItems() {
        let (svc, fs) = world()
        fs.addFile("/u/a.txt")
        fs.addFile("/u/b.txt")
        let ids = svc.add([.file(path: "/u/a.txt", owned: false), .file(path: "/u/b.txt", owned: false), .text("t t")]).added
        fs.files["/u/b.txt"] = nil
        #expect(svc.resolvedPaths(ids) == ["/u/a.txt"])
    }

    @Test func serviceReloadsPersistedItemsOnInit() {
        let path = tempDBPath()
        let fs = ShfFS()
        let a = Shf.service(fs: fs, path: path)
        _ = a.add([.text("persisted note")])
        let b = Shf.service(fs: fs, path: path)
        #expect(b.items.map(\.title) == ["persisted note"])
    }
}
