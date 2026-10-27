import Testing
import Foundation
@testable import MultitulCore

@Suite struct LineBufferTests {
    @Test func splitsOnNewlines() {
        var b = LineBuffer()
        #expect(b.feed(Data("a\nb\nc".utf8)) == ["a", "b"])
        #expect(b.flush() == "c")
        #expect(b.flush() == nil)
    }

    @Test func carriageReturnsActAsLineBreaks() {
        var b = LineBuffer()
        #expect(b.feed(Data("10%\r20%\r30%\n".utf8)) == ["10%", "20%", "30%"])
    }

    @Test func crlfIsOneBreakEvenAcrossChunks() {
        var b = LineBuffer()
        #expect(b.feed(Data("a\r".utf8)) == ["a"])
        #expect(b.feed(Data("\nb\r\n".utf8)) == ["b"])
    }

    @Test func multibyteCharactersSurviveChunkBorders() {
        var b = LineBuffer()
        let bytes = Array("Привет\n".utf8)
        #expect(b.feed(Data(bytes[0..<3])).isEmpty)
        #expect(b.feed(Data(bytes[3...])) == ["Привет"])
    }

    @Test func emptyLinesAreKept() {
        var b = LineBuffer()
        #expect(b.feed(Data("a\n\nb\n".utf8)) == ["a", "", "b"])
    }
}

@Suite struct ManagerSupportTests {
    @Test func shellQuoteLeavesSafeWordsAlone() {
        #expect(ShellQuote.quote("openssl@3") == "openssl@3")
        #expect(ShellQuote.quote("a b") == "'a b'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("$(rm -rf)") == "'$(rm -rf)'")
        #expect(ShellQuote.line(["brew", "install", "a;b"]) == "brew install 'a;b'")
    }

    @Test func terminalScriptEscapesQuotesAndBackslashes() {
        let s = TerminalScript.appleScript(running: #"echo "hi" \n"#)
        #expect(s.contains(#"do script "echo \"hi\" \\n""#))
        #expect(s.hasPrefix("tell application \"Terminal\"") && s.hasSuffix("end tell"))
    }

    @Test func locatorFindsExecutablesInOrder() {
        let files = mgrFiles(executables: ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/brew"])
        let l = ToolLocator(files: files)
        #expect(l.find("brew") == "/opt/homebrew/bin/brew")
        #expect(l.find("ffmpeg") == "/usr/local/bin/ffmpeg")
        #expect(l.find("yt-dlp") == nil)
    }

    @Test func locatorPrefersAppleSiliconPrefix() {
        let l = ToolLocator(files: mgrFiles(executables: ["/usr/local/bin/brew", "/opt/homebrew/bin/brew"]))
        #expect(l.find("brew") == "/opt/homebrew/bin/brew")
    }

    @Test func locatorRejectsPathsAndEmptyNames() {
        let l = ToolLocator(files: mgrFiles(executables: ["/opt/homebrew/bin/brew"]))
        #expect(l.find("../bin/brew") == nil && l.find("") == nil && l.find("/opt/homebrew/bin/brew") == nil)
    }

    @Test func resultFlags() {
        #expect(ManagerResult(status: 0).ok)
        #expect(!ManagerResult(status: 0, cancelled: true).ok && !ManagerResult(status: 0, timedOut: true).ok && !ManagerResult(status: 1).ok)
        #expect(ManagerResult(status: 1, stdout: "a", stderr: "b").combined == "a\nb")
    }

    @Test func realRunnerRefusesSudoWithoutLaunching() async {
        let r = await SystemManagerRunner().run(ManagerCommand("/usr/bin/sudo", ["true"]))
        #expect(r.status == 126 && r.stderr.contains("not allowed"))
    }

    @Test func byteFormatting() {
        #expect(ManagerBytes.format(0) == "0 Б" && ManagerBytes.format(512) == "512 Б")
        #expect(ManagerBytes.format(1536) == "1.5 КБ")
        #expect(ManagerBytes.format(5 * 1_048_576) == "5.0 МБ")
        #expect(ManagerBytes.format(3 * 1_073_741_824) == "3.0 ГБ")
    }
}
