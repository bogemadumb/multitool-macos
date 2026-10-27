import Testing
import Foundation
@testable import MultitulCore

private let block1 = """
frame=120
fps=59.80
stream_0_0_q=28.0
bitrate=1523.4kbits/s
total_size=1048576
out_time_us=4000000
out_time_ms=4000000
out_time=00:00:04.000000
dup_frames=0
drop_frames=2
speed=2.00x
progress=continue
"""

private func samples(_ text: String) -> [FfmpegProgressSample] {
    var p = FfmpegProgressParser()
    return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { p.feed(String($0)) }
}

@Suite struct FfmpegProgressTests {
    @Test func oneBlockProducesOneSample() {
        let s = samples(block1)
        #expect(s.count == 1)
        let x = s[0]
        #expect(x.frame == 120 && x.fps == 59.8 && x.bitrateKbps == 1523.4 && x.totalSize == 1_048_576)
        #expect(x.outTime == 4 && x.speed == 2 && x.dropped == 2 && !x.isEnd)
    }

    @Test func fractionAndRemainingTime() {
        let x = samples(block1)[0]
        #expect(x.fraction(duration: 40) == 0.1)
        #expect(x.remaining(duration: 40) == 18)
        #expect(x.fraction(duration: nil) == nil && x.fraction(duration: 0) == nil)
        #expect(x.fraction(duration: 2) == 1)
    }

    @Test func endBlockCompletes() {
        let s = samples(block1 + "\nframe=300\nout_time_us=10000000\nspeed=1.9x\nprogress=end\n")
        #expect(s.count == 2 && s[1].isEnd && s[1].fraction(duration: 10) == 1 && s[1].fraction(duration: nil) == 1)
        #expect(s[1].remaining(duration: 10) == nil)
    }

    @Test func blocksDoNotLeakIntoEachOther() {
        let s = samples("frame=10\nspeed=3.0x\nprogress=continue\nframe=20\nprogress=continue\n")
        #expect(s.count == 2 && s[0].speed == 3 && s[1].speed == nil && s[1].frame == 20)
    }

    @Test func notAvailableValuesAreIgnored() {
        let s = samples("bitrate=N/A\ntotal_size=N/A\nout_time_us=N/A\nout_time=N/A\nspeed=N/A\nprogress=continue\n")
        #expect(s.count == 1 && s[0].bitrateKbps == nil && s[0].totalSize == 0 && s[0].outTime == 0 && s[0].speed == nil)
    }

    @Test func outTimeFallsBackToTheClockText() {
        let s = samples("out_time=00:01:02.500000\nprogress=continue\n")
        #expect(s[0].outTime == 62.5)
    }

    @Test func negativeStartTimesAreIgnored() {
        let s = samples("out_time_us=-1000\nout_time=-00:00:00.001000\nprogress=continue\n")
        #expect(s[0].outTime == 0)
    }

    @Test func garbageLinesAreSkipped() {
        let s = samples("hello\n\n=\nframe=abc\nspeed=fast\nprogress=continue\n")
        #expect(s.count == 1 && s[0].frame == 0 && s[0].speed == nil)
    }

    @Test func clockParsing() {
        #expect(FfmpegProgressParser.clock("01:02:03.5") == 3723.5)
        #expect(FfmpegProgressParser.clock("00:00:00.000000") == 0)
        #expect(FfmpegProgressParser.clock("N/A") == nil && FfmpegProgressParser.clock("12") == nil)
    }

    @Test func fractionNeverLeavesZeroToOne() {
        var s = FfmpegProgressSample()
        s.outTime = 500
        #expect(s.fraction(duration: 10) == 1)
        s.outTime = 0
        #expect(s.fraction(duration: 10) == 0)
    }

    @Test func realisticStreamThroughTheLineBuffer() {
        var buf = LineBuffer()
        var p = FfmpegProgressParser()
        var out: [FfmpegProgressSample] = []
        let data = Data((block1 + "\n").utf8)
        for chunk in stride(from: 0, to: data.count, by: 7) {
            for line in buf.feed(data.subdata(in: chunk..<min(chunk + 7, data.count))) { if let s = p.feed(line) { out.append(s) } }
        }
        #expect(out.count == 1 && out[0].frame == 120)
    }
}

@Suite struct MediaTimeTests {
    @Test func parsesCommonForms() {
        #expect(MediaTime.parse("90") == 90 && MediaTime.parse("1:30") == 90 && MediaTime.parse("01:02:03.5") == 3723.5)
        #expect(MediaTime.parse("1m30s") == 90 && MediaTime.parse("2h") == 7200 && MediaTime.parse("45s") == 45)
        #expect(MediaTime.parse("1,5") == 1.5 && MediaTime.parse(" 0 ") == 0)
    }

    @Test func rejectsNonsense() {
        for bad in ["", "abc", "1:2:3:4", "-5", "1::2", "5x", "m30"] { #expect(MediaTime.parse(bad) == nil, "\(bad)") }
    }

    @Test func formatting() {
        #expect(MediaTime.format(90) == "1:30" && MediaTime.format(5) == "0:05" && MediaTime.format(3723) == "1:02:03" && MediaTime.format(-4) == "0:00")
        #expect(MediaTime.format(62.5) == "1:02.5")
    }
}

@Suite struct YtDlpTests {
    @Test func progressTemplateLines() {
        let p = YtDlpArgs.parseProgress("download:  45.3%|1.20MiB/s|00:05")
        #expect(p == YtDlpProgress(percent: 45.3, speed: "1.20MiB/s", eta: "00:05"))
        #expect(YtDlpArgs.parseProgress("download:100%|NA|NA")?.percent == 100)
        #expect(YtDlpArgs.parseProgress("download:abc|1|2") == nil)
        #expect(YtDlpArgs.parseProgress("[download] 10% of 5MiB") == nil)
        #expect(YtDlpArgs.parseProgress("download:5%|x") == nil)
    }

    @Test func destinationLines() {
        #expect(YtDlpArgs.destination(in: "[download] Destination: /Users/x/Downloads/a [id].mp4") == "/Users/x/Downloads/a [id].mp4")
        #expect(YtDlpArgs.destination(in: "[Merger] Merging formats into \"/Users/x/a.mp4\"") == "/Users/x/a.mp4")
        #expect(YtDlpArgs.destination(in: "[ExtractAudio] Destination: /x/a.m4a") == "/x/a.m4a")
        #expect(YtDlpArgs.destination(in: "[info] hello") == nil)
    }

    @Test func urlValidation() {
        #expect(YtDlpArgs.validURL("https://www.youtube.com/watch?v=abc") != nil)
        #expect(YtDlpArgs.validURL("  http://example.com/x  ") != nil)
        for bad in ["", "file:///etc/passwd", "--exec rm", "javascript:alert(1)", "ftp://x.y/z", "https://", "not a url"] { #expect(YtDlpArgs.validURL(bad) == nil, "\(bad)") }
    }

    @Test func downloadArguments() throws {
        let a = try YtDlpArgs.download(url: "https://example.com/v", folder: "/Users/x/Downloads", mode: .maxHeight(720), ffmpegDirectory: "/opt/homebrew/bin")
        #expect(a.last == "https://example.com/v" && a[a.count - 2] == "--")
        #expect(a.contains("--no-playlist") && a.contains("--newline") && a.contains(YtDlpArgs.progressTemplate))
        #expect(a[a.firstIndex(of: "-P")! + 1] == "/Users/x/Downloads" && a[a.firstIndex(of: "--ffmpeg-location")! + 1] == "/opt/homebrew/bin")
        #expect(a[a.firstIndex(of: "-f")! + 1] == "bv*[height<=720]+ba/b[height<=720]")
    }

    @Test func audioModeAndBadInput() throws {
        let a = try YtDlpArgs.download(url: "https://example.com/v", folder: "/x", mode: .audio(.m4a), ffmpegDirectory: nil)
        #expect(a.contains("-x") && a[a.firstIndex(of: "--audio-format")! + 1] == "m4a" && !a.contains("--ffmpeg-location"))
        #expect(throws: MediaError.self) { try YtDlpArgs.download(url: "--version", folder: "/x", mode: .bestVideo, ffmpegDirectory: nil) }
        #expect(throws: MediaError.self) { try YtDlpArgs.download(url: "https://a.b/c", folder: "", mode: .bestVideo, ffmpegDirectory: nil) }
    }
}
