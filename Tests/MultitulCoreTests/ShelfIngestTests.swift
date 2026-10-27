import Testing
import Foundation
@testable import MultitulCore

@Suite struct ShelfIngestTests {
    @Test func fileUrlBecomesFile() {
        let r = ShelfIngest.parse([Shf.fileItem("/Users/x/Док/отчёт.pdf")])
        #expect(r == [.file(path: "/Users/x/Док/отчёт.pdf", owned: false)])
    }

    @Test func severalFilesKeepOrderAndDropRepeats() {
        let r = ShelfIngest.parse([Shf.fileItem("/a/1.txt"), Shf.fileItem("/a/2.txt"), Shf.fileItem("/a//1.txt")])
        #expect(r == [.file(path: "/a/1.txt", owned: false), .file(path: "/a/2.txt", owned: false)])
    }

    @Test func unresolvedFileReferenceIsSkipped() {
        let it = PasteboardItemData(reps: [PBType.fileURL: Data("file:///.file/id=6571367.123".utf8)])
        #expect(ShelfIngest.parse([it]).isEmpty)
    }

    @Test func httpTextBecomesUrl() {
        #expect(ShelfIngest.parse([Shf.text("https://example.com/a?b=1")]) == [.url("https://example.com/a?b=1", title: nil)])
    }

    @Test func textWithSpacesStaysText() {
        #expect(ShelfIngest.parse([Shf.text("see https://example.com now")]) == [.text("see https://example.com now")])
    }

    @Test func urlRepresentationKeepsTitle() {
        let it = PasteboardItemData(reps: [PBType.url: Data("https://example.com/x".utf8), "public.url-name": Data("Пример".utf8)])
        #expect(ShelfIngest.parse([it]) == [.url("https://example.com/x", title: "Пример")])
    }

    @Test func fileSchemeInsideUrlRepIsAFile() {
        let it = PasteboardItemData(reps: [PBType.url: Data("file:///tmp/a.txt".utf8)])
        #expect(ShelfIngest.parse([it]) == [.file(path: "/tmp/a.txt", owned: false)])
    }

    @Test func pngWinsOverUrlAndText() {
        let png = Data([1, 2, 3])
        let it = PasteboardItemData(reps: [PBType.png: png, PBType.url: Data("https://e.com/i.png".utf8), PBType.utf8: Data("https://e.com/i.png".utf8)])
        #expect(ShelfIngest.parse([it]) == [.image(png, ext: "png", name: nil)])
    }

    @Test func tiffIsAnImageToo() {
        let t = Data([9, 9])
        #expect(ShelfIngest.parse([PasteboardItemData(reps: [PBType.tiff: t])]) == [.image(t, ext: "tiff", name: nil)])
    }

    @Test func blankTextIsIgnored() {
        #expect(ShelfIngest.parse([Shf.text("  \n ")]).isEmpty)
    }

    @Test func fileCandidateCarriesPathBookmarkAndSize() throws {
        let fs = ShfFS()
        fs.addFile("/Users/x/a.txt", size: 321)
        let c = try #require(ShelfIngest.candidate(.file(path: "/Users/x/a.txt", owned: false), fs: fs))
        #expect(c.kind == .file)
        #expect(c.title == "a.txt")
        #expect(c.size == 321)
        #expect(c.path == "/Users/x/a.txt")
        #expect(c.ext == "txt")
        #expect(c.payload.bookmark != nil)
    }

    @Test func folderCandidateIsAFolder() throws {
        let fs = ShfFS()
        fs.addDir("/Users/x/Папка")
        let c = try #require(ShelfIngest.candidate(.file(path: "/Users/x/Папка", owned: false), fs: fs))
        #expect(c.kind == .folder)
        #expect(c.size == 0)
    }

    @Test func missingFileIsRejected() {
        #expect(ShelfIngest.candidate(.file(path: "/nope", owned: false), fs: ShfFS()) == nil)
    }

    @Test func fileWithoutBookmarkStillWorks() throws {
        let fs = ShfFS()
        fs.failBookmarks = true
        fs.addFile("/a/b")
        let c = try #require(ShelfIngest.candidate(.file(path: "/a/b", owned: false), fs: fs))
        #expect(c.payload.bookmark == nil)
    }

    @Test func samePathAnyWrittenFormGivesTheSameHash() throws {
        let fs = ShfFS()
        fs.addFile("/a/b.txt")
        let h1 = try #require(ShelfIngest.candidate(.file(path: "/a/b.txt", owned: false), fs: fs)).hash
        let h2 = try #require(ShelfIngest.candidate(.file(path: "/a/./c/../b.txt", owned: false), fs: fs)).hash
        #expect(h1 == h2)
    }

    @Test func textTitleIsTheFirstNonEmptyLine() throws {
        let c = try #require(ShelfIngest.candidate(.text("\n\n  первая строка  \nвторая"), fs: ShfFS()))
        #expect(c.title == "первая строка")
        #expect(c.payload.body == "\n\n  первая строка  \nвторая")
    }

    @Test func longTitleIsCut() throws {
        let c = try #require(ShelfIngest.candidate(.text(String(repeating: "я", count: 300)), fs: ShfFS()))
        #expect(c.title.count == ShelfLimits.titleLength + 1)
        #expect(c.title.hasSuffix("…"))
    }

    @Test func oversizedTextAndImageAreRejected() {
        #expect(ShelfIngest.candidate(.text(String(repeating: "a", count: ShelfLimits.maxTextBytes + 1)), fs: ShfFS()) == nil)
        #expect(ShelfIngest.candidate(.image(Data(count: ShelfLimits.maxImageBytes + 1), ext: "png", name: nil), fs: ShfFS()) == nil)
        #expect(ShelfIngest.candidate(.image(Data(), ext: "png", name: nil), fs: ShfFS()) == nil)
    }

    @Test func urlTitlePrefersGivenThenHostAndPath() {
        #expect(ShelfIngest.urlTitle("https://www.example.com/a/b", given: nil) == "example.com/a/b")
        #expect(ShelfIngest.urlTitle("https://example.com/", given: nil) == "example.com")
        #expect(ShelfIngest.urlTitle("https://example.com/", given: " Заголовок ") == "Заголовок")
    }

    @Test func urlKeyIgnoresCaseOfHostAndTrailingSlash() {
        #expect(ShelfIngest.normalizedURLKey("HTTPS://Example.COM/path/") == ShelfIngest.normalizedURLKey("https://example.com/path"))
        #expect(ShelfIngest.normalizedURLKey("https://example.com/") == ShelfIngest.normalizedURLKey("https://example.com"))
        #expect(ShelfIngest.normalizedURLKey("https://example.com/a?x=1") != ShelfIngest.normalizedURLKey("https://example.com/a?x=2"))
    }

    @Test func pathHelpers() {
        #expect(ShelfPaths.normalize("/a/b/") == "/a/b")
        #expect(ShelfPaths.normalize("/") == "/")
        #expect(ShelfPaths.isInside("/shelf/files/u1/a.png", dir: "/shelf/files"))
        #expect(!ShelfPaths.isInside("/shelf/files", dir: "/shelf/files"))
        #expect(!ShelfPaths.isInside("/shelf/filesX/a", dir: "/shelf/files"))
        #expect(ShelfPaths.displayDirectory("/Users/me/Docs/a.txt", home: "/Users/me") == "~/Docs")
        #expect(ShelfPaths.displayDirectory("/Users/me/a.txt", home: "/Users/me") == "~")
        #expect(ShelfPaths.displayDirectory("/opt/a.txt", home: "/Users/me") == "/opt")
    }
}
