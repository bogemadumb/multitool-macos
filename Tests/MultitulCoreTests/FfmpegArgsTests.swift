import Testing
import Foundation
@testable import MultitulCore

private let probeJSON = """
{"streams":[
 {"index":0,"codec_name":"h264","codec_type":"video","width":1920,"height":1080,"r_frame_rate":"30000/1001","avg_frame_rate":"30000/1001","duration":"120.500000"},
 {"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","duration":"120.500000"}],
 "format":{"filename":"in.mp4","duration":"120.521000","size":"52428800","bit_rate":"3480000"}}
"""

private func video(_ w: Int = 1920, _ h: Int = 1080, duration: Double = 120, audio: Bool = true, fps: Double = 30, rotation: Int = 0) -> MediaInfo {
    MediaInfo(duration: duration, width: w, height: h, fps: fps, videoCodec: "h264", audioCodec: audio ? "aac" : nil, bitrate: 3_000_000, sizeBytes: 50_000_000, rotation: rotation)
}

private func pair(_ args: [String], _ key: String) -> String? {
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
    return args[i + 1]
}

@Suite struct FfprobeParserTests {
    @Test func videoAndAudioStreams() throws {
        let i = try FfprobeParser.parse(probeJSON)
        #expect(i.width == 1920 && i.height == 1080 && i.videoCodec == "h264" && i.audioCodec == "aac")
        #expect(abs(i.fps - 29.97) < 0.01 && i.duration == 120.521 && i.bitrate == 3_480_000 && i.sizeBytes == 52_428_800)
        #expect(i.hasVideo && i.hasAudio && i.displayWidth == 1920)
    }

    @Test func rotationSwapsDisplaySize() throws {
        let i = try FfprobeParser.parse(#"{"streams":[{"codec_type":"video","codec_name":"hevc","width":1920,"height":1080,"avg_frame_rate":"30/1","side_data_list":[{"side_data_type":"Display Matrix","rotation":-90}]}],"format":{"duration":"10"}}"#)
        #expect(i.rotation == -90 && i.isQuarterTurned && i.displayWidth == 1080 && i.displayHeight == 1920)
        let old = try FfprobeParser.parse(#"{"streams":[{"codec_type":"video","codec_name":"h264","width":640,"height":360,"tags":{"rotate":"90"}}],"format":{}}"#)
        #expect(old.isQuarterTurned)
    }

    @Test func audioOnlyFile() throws {
        let i = try FfprobeParser.parse(#"{"streams":[{"codec_type":"audio","codec_name":"mp3","duration":"215.3"}],"format":{"duration":"215.3","bit_rate":"320000"}}"#)
        #expect(!i.hasVideo && i.hasAudio && i.duration == 215.3)
    }

    @Test func imageHasNoDuration() throws {
        let i = try FfprobeParser.parse(#"{"streams":[{"codec_type":"video","codec_name":"png","width":800,"height":600,"r_frame_rate":"25/1"}],"format":{"format_name":"png_pipe"}}"#)
        #expect(i.hasVideo && i.duration == 0 && i.width == 800)
    }

    @Test func coverArtIsNotTheVideoStream() throws {
        let i = try FfprobeParser.parse(#"{"streams":[{"codec_type":"video","codec_name":"mjpeg","width":500,"height":500,"disposition":{"attached_pic":1}},{"codec_type":"video","codec_name":"h264","width":1280,"height":720}],"format":{"duration":"5"}}"#)
        #expect(i.width == 1280)
    }

    @Test func garbageAndEmptyAnswersThrow() {
        #expect(throws: MediaError.self) { try FfprobeParser.parse("not json") }
        #expect(throws: MediaError.self) { try FfprobeParser.parse("{}") }
        #expect(throws: MediaError.self) { try FfprobeParser.parse("") }
    }

    @Test func probeArgumentsAreAnArray() {
        let a = FfprobeParser.arguments(for: "/tmp/my file's.mp4")
        #expect(a.last == "/tmp/my file's.mp4" && a.contains("-show_streams") && a.contains("json"))
    }

    @Test func formatsByExtension() {
        #expect(MediaFormats.kind(of: "/a/b.MP4") == .video && MediaFormats.kind(of: "x.flac") == .audio && MediaFormats.kind(of: "x.HEIC") == .image)
        #expect(MediaFormats.kind(of: "x.pdf") == .unknown && MediaFormats.kind(of: "noext") == .unknown)
    }
}

@Suite struct FfmpegCompressTests {
    @Test func standardPrefixAsksForMachineReadableProgress() {
        let p = FfmpegArgs.prefix
        #expect(p.contains("-nostdin") && p.contains("-y"))
        #expect(pair(p, "-progress") == "pipe:1" && p.contains("-nostats") && pair(p, "-loglevel") == "error")
    }

    @Test func qualityModeH264() throws {
        let inv = try FfmpegArgs.compress(input: "/in/a b.mov", output: "/out/a.mp4", info: video(), options: VideoCompressOptions())
        let a = inv.arguments
        #expect(Array(a.prefix(FfmpegArgs.prefix.count)) == FfmpegArgs.prefix)
        #expect(pair(a, "-i") == "/in/a b.mov" && a.last == "/out/a.mp4")
        #expect(pair(a, "-c:v") == "libx264" && pair(a, "-crf") == "25" && pair(a, "-preset") == "medium" && pair(a, "-pix_fmt") == "yuv420p")
        #expect(pair(a, "-c:a") == "aac" && pair(a, "-b:a") == "128k" && pair(a, "-movflags") == "+faststart")
        #expect(a.contains("0:v:0") && a.contains("0:a:0?") && pair(a, "-map_metadata") == "-1")
        #expect(pair(a, "-vf") == "scale=trunc(iw/2)*2:trunc(ih/2)*2" && inv.duration == 120)
    }

    @Test func crfMapping() {
        #expect(FfmpegArgs.crf(forQuality: 100, codec: .h264) == 18)
        #expect(FfmpegArgs.crf(forQuality: 1, codec: .h264) == 36)
        #expect(FfmpegArgs.crf(forQuality: 60, codec: .h264) == 25)
        #expect(FfmpegArgs.crf(forQuality: 60, codec: .hevc) == 29)
        #expect(FfmpegArgs.crf(forQuality: 999, codec: .h264) == 18 && FfmpegArgs.crf(forQuality: -5, codec: .h264) == 36)
    }

    @Test func hevcGetsTheAppleCompatibleTag() throws {
        var o = VideoCompressOptions()
        o.codec = .hevc
        let a = try FfmpegArgs.compress(input: "i.mp4", output: "o.mp4", info: video(), options: o).arguments
        #expect(pair(a, "-c:v") == "libx265" && pair(a, "-tag:v") == "hvc1" && pair(a, "-crf") == "29")
    }

    @Test func hardwareEncoderUsesQualityScale() throws {
        var o = VideoCompressOptions()
        o.hardware = true
        o.mode = .quality(70)
        let a = try FfmpegArgs.compress(input: "i.mp4", output: "o.mp4", info: video(), options: o).arguments
        #expect(pair(a, "-c:v") == "h264_videotoolbox" && pair(a, "-q:v") == "70" && !a.contains("-crf") && !a.contains("-preset"))
    }

    @Test func heightCapOnlyShrinks() throws {
        var o = VideoCompressOptions()
        o.maxHeight = 720
        #expect(pair(try FfmpegArgs.compress(input: "i", output: "o.mp4", info: video(), options: o).arguments, "-vf") == "scale=-2:720")
        #expect(pair(try FfmpegArgs.compress(input: "i", output: "o.mp4", info: video(1280, 540), options: o).arguments, "-vf") == "scale=trunc(iw/2)*2:trunc(ih/2)*2")
    }

    @Test func rotatedPhoneVideoUsesDisplayHeight() throws {
        var o = VideoCompressOptions()
        o.maxHeight = 1280
        let a = try FfmpegArgs.compress(input: "i", output: "o.mp4", info: video(1920, 1080, rotation: 90), options: o).arguments
        #expect(pair(a, "-vf") == "scale=-2:1280")
    }

    @Test func silentVideoGetsNoAudioStream() throws {
        let a = try FfmpegArgs.compress(input: "i", output: "o.mp4", info: video(audio: false), options: VideoCompressOptions()).arguments
        #expect(a.contains("-an") && !a.contains("-c:a"))
    }

    @Test func metadataAndContainerSwitches() throws {
        var o = VideoCompressOptions()
        o.stripMetadata = false
        o.container = .mkv
        let a = try FfmpegArgs.compress(input: "i", output: "o.mkv", info: video(), options: o).arguments
        #expect(!a.contains("-map_metadata") && !a.contains("-movflags"))
    }

    @Test func webmAndAudioOnlyAreRejected() {
        var o = VideoCompressOptions()
        o.container = .webm
        #expect(throws: MediaError.self) { try FfmpegArgs.compress(input: "i", output: "o.webm", info: video(), options: o) }
        #expect(throws: MediaError.noVideoStream) { try FfmpegArgs.compress(input: "i", output: "o.mp4", info: MediaInfo(duration: 5, audioCodec: "mp3"), options: VideoCompressOptions()) }
    }

    @Test func nothingIsShellQuotedInsideArguments() throws {
        let weird = "/tmp/it's a \"test\"; rm -rf $HOME.mp4"
        let a = try FfmpegArgs.compress(input: weird, output: "/tmp/o ut.mp4", info: video(), options: VideoCompressOptions()).arguments
        #expect(pair(a, "-i") == weird && a.last == "/tmp/o ut.mp4")
        #expect(a.filter { $0.contains("rm -rf") }.count == 1)
    }
}

@Suite struct TargetSizeTests {
    @Test func bitrateFollowsTheTarget() throws {
        let inv = try FfmpegArgs.compress(input: "i", output: "o.mp4", info: video(duration: 100), options: {
            var o = VideoCompressOptions(); o.mode = .targetSize(50_000_000); return o
        }())
        let b = Int(pair(inv.arguments, "-b:v")!)!
        let expected = Int(Double(50_000_000) * 8 * TargetSizePlanner.overheadFactor / 100) - 128_000
        #expect(b == expected)
        #expect(pair(inv.arguments, "-maxrate") == String(Int(Double(b) * 1.3)) && pair(inv.arguments, "-bufsize") == String(b * 2))
        #expect(!inv.arguments.contains("-crf"))
    }

    @Test func generousTargetKeepsFullResolution() throws {
        let p = try TargetSizePlanner.plan(info: video(duration: 60), targetBytes: 200_000_000, audioKbps: 128, codec: .h264, maxHeight: 0)
        #expect(p.height == nil && p.width == nil)
    }

    @Test func tightTargetShrinksResolution() throws {
        let p = try TargetSizePlanner.plan(info: video(duration: 600), targetBytes: 30_000_000, audioKbps: 128, codec: .h264, maxHeight: 0)
        #expect(p.height != nil && p.height! < 1080)
        #expect(p.width! % 2 == 0)
    }

    @Test func tighterTargetShrinksMore() throws {
        let a = try TargetSizePlanner.plan(info: video(duration: 600), targetBytes: 60_000_000, audioKbps: 128, codec: .h264, maxHeight: 0)
        let b = try TargetSizePlanner.plan(info: video(duration: 600), targetBytes: 20_000_000, audioKbps: 128, codec: .h264, maxHeight: 0)
        #expect((b.height ?? 1080) <= (a.height ?? 1080))
    }

    @Test func hevcNeedsFewerBitsPerPixel() throws {
        let h264 = try TargetSizePlanner.plan(info: video(duration: 300), targetBytes: 40_000_000, audioKbps: 128, codec: .h264, maxHeight: 0)
        let hevc = try TargetSizePlanner.plan(info: video(duration: 300), targetBytes: 40_000_000, audioKbps: 128, codec: .hevc, maxHeight: 0)
        #expect((hevc.height ?? 1080) >= (h264.height ?? 1080))
    }

    @Test func heightCapAppliesToTheTargetPlan() throws {
        let p = try TargetSizePlanner.plan(info: video(duration: 10), targetBytes: 500_000_000, audioKbps: 128, codec: .h264, maxHeight: 480)
        #expect(p.height == 480)
    }

    @Test func impossibleTargetReportsTheMinimum() {
        do {
            _ = try TargetSizePlanner.plan(info: video(duration: 3600), targetBytes: 1_000_000, audioKbps: 128, codec: .h264, maxHeight: 0)
            Issue.record("must throw")
        } catch MediaError.targetTooSmall(let min) {
            #expect(min > 1_000_000)
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func silentVideoSpendsEverythingOnPictures() throws {
        let with = try TargetSizePlanner.plan(info: video(duration: 100), targetBytes: 20_000_000, audioKbps: 128, codec: .h264, maxHeight: 0)
        let without = try TargetSizePlanner.plan(info: video(duration: 100, audio: false), targetBytes: 20_000_000, audioKbps: 128, codec: .h264, maxHeight: 0)
        #expect(without.videoBitrate - with.videoBitrate == 128_000)
    }

    @Test func invalidInputsThrow() {
        #expect(throws: MediaError.self) { try TargetSizePlanner.plan(info: video(duration: 0), targetBytes: 1_000_000, audioKbps: 128, codec: .h264, maxHeight: 0) }
        #expect(throws: MediaError.self) { try TargetSizePlanner.plan(info: video(), targetBytes: 0, audioKbps: 128, codec: .h264, maxHeight: 0) }
        #expect(throws: MediaError.noVideoStream) { try TargetSizePlanner.plan(info: MediaInfo(duration: 5), targetBytes: 1_000_000, audioKbps: 128, codec: .h264, maxHeight: 0) }
    }
}

@Suite struct FfmpegOtherOpsTests {
    @Test func trimWithoutReencodeSeeksBeforeInput() throws {
        let a = try FfmpegArgs.trim(input: "in.mp4", output: "out.mp4", info: video(), options: TrimOptions(start: 10, end: 25.5)).arguments
        let ss = a.firstIndex(of: "-ss")!, i = a.firstIndex(of: "-i")!
        #expect(ss < i && a[ss + 1] == "10" && pair(a, "-t") == "15.5")
        #expect(pair(a, "-c") == "copy" && pair(a, "-avoid_negative_ts") == "make_zero")
    }

    @Test func trimFromTheStartHasNoSeek() throws {
        let a = try FfmpegArgs.trim(input: "i", output: "o", info: video(duration: 100), options: TrimOptions(start: 0, end: 30)).arguments
        #expect(!a.contains("-ss") && pair(a, "-t") == "30")
    }

    @Test func openEndedTrimUsesTheRemainingDuration() throws {
        let inv = try FfmpegArgs.trim(input: "i", output: "o", info: video(duration: 100), options: TrimOptions(start: 40))
        #expect(pair(inv.arguments, "-t") == "60" && inv.duration == 60)
    }

    @Test func endBeyondTheFileIsClamped() throws {
        let inv = try FfmpegArgs.trim(input: "i", output: "o", info: video(duration: 100), options: TrimOptions(start: 90, end: 500))
        #expect(pair(inv.arguments, "-t") == "10")
    }

    @Test func reencodedTrim() throws {
        let a = try FfmpegArgs.trim(input: "i", output: "o", info: video(), options: TrimOptions(start: 1, end: 5, reencode: true)).arguments
        #expect(pair(a, "-c:v") == "libx264" && pair(a, "-c:a") == "aac" && pair(a, "-crf") == "20" && !a.contains("copy"))
    }

    @Test func reencodedAudioTrimLeavesCodecsToFfmpeg() throws {
        let a = try FfmpegArgs.trim(input: "i.mp3", output: "o.mp3", info: MediaInfo(duration: 60, audioCodec: "mp3"), options: TrimOptions(start: 1, end: 5, reencode: true)).arguments
        #expect(!a.contains("-c:v") && !a.contains("copy"))
    }

    @Test func badTrimBoundsThrow() {
        #expect(throws: MediaError.self) { try FfmpegArgs.trim(input: "i", output: "o", info: video(), options: TrimOptions(start: -1)) }
        #expect(throws: MediaError.self) { try FfmpegArgs.trim(input: "i", output: "o", info: video(), options: TrimOptions(start: 10, end: 10)) }
        #expect(throws: MediaError.self) { try FfmpegArgs.trim(input: "i", output: "o", info: video(), options: TrimOptions(start: 10, end: 5)) }
        #expect(throws: MediaError.self) { try FfmpegArgs.trim(input: "i", output: "o", info: video(duration: 30), options: TrimOptions(start: 30)) }
    }

    @Test func gifUsesAPaletteAndRespectsLimits() throws {
        var g = GifOptions()
        g.fps = 15
        g.width = 640
        g.start = 5
        g.duration = 4
        let inv = try FfmpegArgs.gif(input: "i.mp4", output: "o.gif", info: video(), options: g)
        let graph = pair(inv.arguments, "-filter_complex")!
        #expect(graph.contains("fps=15") && graph.contains("scale=640:-1") && graph.contains("palettegen") && graph.contains("paletteuse"))
        #expect(pair(inv.arguments, "-ss") == "5" && pair(inv.arguments, "-t") == "4" && pair(inv.arguments, "-loop") == "0" && inv.arguments.contains("-an"))
        #expect(inv.duration == 4)
    }

    @Test func gifIsClampedToTheSourceAndLimits() throws {
        var g = GifOptions()
        g.fps = 99
        g.width = 5000
        g.duration = 500
        let inv = try FfmpegArgs.gif(input: "i", output: "o.gif", info: video(640, 360, duration: 12), options: g)
        let graph = pair(inv.arguments, "-filter_complex")!
        #expect(graph.contains("fps=30") && graph.contains("scale=640:-1") && pair(inv.arguments, "-t") == "12")
        g.loop = false
        #expect(pair(try FfmpegArgs.gif(input: "i", output: "o.gif", info: video(), options: g).arguments, "-loop") == "-1")
    }

    @Test func gifRejectsBadStart() {
        var g = GifOptions()
        g.start = 500
        #expect(throws: MediaError.self) { try FfmpegArgs.gif(input: "i", output: "o.gif", info: video(duration: 10), options: g) }
        #expect(throws: MediaError.noVideoStream) { try FfmpegArgs.gif(input: "i", output: "o.gif", info: MediaInfo(duration: 3, audioCodec: "mp3"), options: GifOptions()) }
    }

    @Test func imageWatermarkOverlay() throws {
        var w = WatermarkOptions(source: .image("/tmp/logo.png"))
        w.corner = .topRight
        w.margin = 10
        w.scalePercent = 25
        w.opacityPercent = 50
        let a = try FfmpegArgs.watermark(input: "in.mp4", output: "out.mp4", info: video(), options: w).arguments
        let graph = pair(a, "-filter_complex")!
        #expect(graph == "[1:v]scale=480:-1,format=rgba,colorchannelmixer=aa=0.5[wm];[0:v][wm]overlay=main_w-overlay_w-10:10[out]")
        #expect(a.filter { $0 == "-i" }.count == 2 && a.contains("/tmp/logo.png") && pair(a, "-map") == "[out]")
        #expect(pair(a, "-c:a") == "copy")
    }

    @Test func everyCornerHasAnExpression() {
        let exprs = WatermarkCorner.allCases.map { FfmpegArgs.overlayPosition($0, margin: 8) }
        #expect(Set(exprs.map { $0.x + "|" + $0.y }).count == 5)
        #expect(FfmpegArgs.overlayPosition(.center, margin: 8).x == "(main_w-overlay_w)/2")
        #expect(FfmpegArgs.textPosition(.bottomLeft, margin: 8) == ("8", "h-text_h-8"))
    }

    @Test func watermarkOnAPhotoWritesOneFrame() throws {
        let photo = MediaInfo(duration: 0, width: 4000, height: 3000, videoCodec: "mjpeg")
        let a = try FfmpegArgs.watermark(input: "p.jpg", output: "p-watermark.jpg", info: photo, options: WatermarkOptions(source: .text("© Max"))).arguments
        #expect(pair(a, "-frames:v") == "1" && pair(a, "-q:v") == "2" && !a.contains("-movflags") && !a.contains("-c:a"))
        #expect(pair(a, "-vf")!.hasPrefix("drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:expansion=none:text=© Max:"))
    }

    @Test func textWatermarkIsEscapedForTheFiltergraph() throws {
        let a = try FfmpegArgs.watermark(input: "i.mp4", output: "o.mp4", info: video(), options: WatermarkOptions(source: .text("a:b'c,d\\e"))).arguments
        #expect(pair(a, "-vf")!.contains("text=a\\\\:b\\\\\\'c\\,d\\\\\\\\e:"))
        #expect(FfmpegEscape.drawtext("x\ny") == "x y")
    }

    @Test func emptyWatermarkSourcesThrow() {
        #expect(throws: MediaError.self) { try FfmpegArgs.watermark(input: "i", output: "o.mp4", info: video(), options: WatermarkOptions(source: .text("   "))) }
        #expect(throws: MediaError.self) { try FfmpegArgs.watermark(input: "i", output: "o.mp4", info: video(), options: WatermarkOptions(source: .image(""))) }
    }

    @Test func audioExtraction() throws {
        let mp3 = try FfmpegArgs.audio(input: "v.mp4", output: "v.mp3", info: video(), format: .mp3, kbps: 192).arguments
        #expect(mp3.contains("-vn") && pair(mp3, "-c:a") == "libmp3lame" && pair(mp3, "-b:a") == "192k" && pair(mp3, "-map") == "0:a:0")
        let flac = try FfmpegArgs.audio(input: "v.mp4", output: "v.flac", info: video(), format: .flac, kbps: 192).arguments
        #expect(pair(flac, "-c:a") == "flac" && !flac.contains("-b:a"))
        #expect(pair(FfmpegArgs.audioCodecArgs(.opus, kbps: 96), "-c:a") == "libopus")
        #expect(pair(FfmpegArgs.audioCodecArgs(.m4a, kbps: 5000), "-b:a") == "320k")
    }

    @Test func silentVideoHasNoAudioToExtract() {
        #expect(throws: MediaError.self) { try FfmpegArgs.audio(input: "v.mp4", output: "v.mp3", info: video(audio: false), format: .mp3, kbps: 128) }
    }

    @Test func videoContainerConversion() throws {
        let mp4 = try FfmpegArgs.convertVideo(input: "i.mkv", output: "o.mp4", info: video(), container: .mp4).arguments
        #expect(pair(mp4, "-c:v") == "libx264" && pair(mp4, "-movflags") == "+faststart")
        let webm = try FfmpegArgs.convertVideo(input: "i.mp4", output: "o.webm", info: video(), container: .webm).arguments
        #expect(pair(webm, "-c:v") == "libvpx-vp9" && pair(webm, "-c:a") == "libopus")
        let mkv = try FfmpegArgs.convertVideo(input: "i.mp4", output: "o.mkv", info: video(), container: .mkv).arguments
        #expect(pair(mkv, "-c") == "copy")
    }

    @Test func imageConversionThroughFfmpeg() {
        var o = ImageConvertOptions()
        o.format = .webp
        o.quality = 80
        o.maxSide = 1000
        let a = FfmpegArgs.convertImage(input: "i.png", output: "o.webp", info: MediaInfo(width: 4000, height: 2000, videoCodec: "png"), options: o).arguments
        #expect(pair(a, "-c:v") == "libwebp" && pair(a, "-quality") == "80" && pair(a, "-vf") == "scale=1000:500:flags=lanczos" && pair(a, "-frames:v") == "1")
        let small = FfmpegArgs.convertImage(input: "i.png", output: "o.webp", info: MediaInfo(width: 800, height: 600, videoCodec: "png"), options: o).arguments
        #expect(!small.contains("-vf"))
        o.format = .jpeg
        o.quality = 100
        #expect(pair(FfmpegArgs.convertImage(input: "i.png", output: "o.jpg", info: nil, options: o).arguments, "-q:v") == "2")
    }

    @Test func frameGrab() {
        let a = FfmpegArgs.frame(input: "v.mp4", at: 12.5, output: "/tmp/f.png").arguments
        #expect(pair(a, "-ss") == "12.5" && pair(a, "-frames:v") == "1" && a.last == "/tmp/f.png")
        #expect(!FfmpegArgs.frame(input: "v.mp4", at: 0, output: "f.png").arguments.contains("-ss"))
    }

    @Test func numberFormatting() {
        #expect(FfmpegArgs.number(10) == "10" && FfmpegArgs.number(15.5) == "15.5" && FfmpegArgs.number(0.125) == "0.125" && FfmpegArgs.number(0) == "0")
    }
}
