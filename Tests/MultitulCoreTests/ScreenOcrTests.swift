import Testing
import Foundation
import CoreGraphics
@testable import MultitulCore

private func line(_ t: String, x: Double, y: Double, w: Double = 0.3, h: Double = 0.05, conf: Double = 1) -> OcrLine {
    OcrLine(t, confidence: conf, box: CGRect(x: x, y: y, width: w, height: h))
}

@Suite struct OcrConfigTests {
    @Test func defaultConfigIsAccurateRussianAndEnglish() {
        let c = OcrRequestConfig()
        #expect(c.level == .accurate && c.languages == ["ru-RU", "en-US"] && c.usesLanguageCorrection)
    }

    @Test func sanitizeDedupesTrimsAndRestoresDefaults() {
        var c = OcrRequestConfig()
        c.languages = [" en-US ", "en-US", "", "de-DE"]
        c.minimumTextHeight = 4
        let s = c.sanitized
        #expect(s.languages == ["en-US", "de-DE"] && s.minimumTextHeight == 1)
        c.languages = ["", "  "]
        #expect(c.sanitized.languages == OcrRequestConfig.defaultLanguages)
    }

    @Test func settingsStoreRoundTrip() {
        let kv = WndMemoryStore()
        let store = OcrSettingsStore(kv)
        store.save(OcrSettings())
        #expect(kv.values.isEmpty)
        var s = OcrSettings()
        s.removeLineBreaks = true
        s.detectQr = false
        s.request.level = .fast
        s.request.languages = ["de-DE"]
        s.request.usesLanguageCorrection = false
        s.minConfidence = 0.4
        store.save(s)
        #expect(store.load() == s)
        #expect(kv.values.keys.allSatisfy { $0.hasPrefix("screenOcr.") })
    }

    @Test func confidenceIsClamped() {
        var s = OcrSettings()
        s.minConfidence = 7
        #expect(s.sanitized.minConfidence == 1)
    }
}

@Suite struct OcrPostProcessTests {
    @Test func readingOrderIsTopToBottomLeftToRight() {
        let lines = [line("вторая", x: 0.1, y: 0.73), line("первая", x: 0.1, y: 0.8), line("третья", x: 0.1, y: 0.66)]
        #expect(OcrPostProcessor.assemble(lines, removeLineBreaks: false) == "первая\nвторая\nтретья")
    }

    @Test func fragmentsOnOneRowAreJoinedLeftToRight() {
        let lines = [line("мир", x: 0.5, y: 0.8), line("Привет", x: 0.1, y: 0.8)]
        #expect(OcrPostProcessor.assemble(lines, removeLineBreaks: false) == "Привет мир")
    }

    @Test func largeVerticalGapMakesAParagraph() {
        let lines = [line("a", x: 0, y: 0.9), line("b", x: 0, y: 0.84), line("c", x: 0, y: 0.5)]
        #expect(OcrPostProcessor.assemble(lines, removeLineBreaks: false) == "a\nb\n\nc")
    }

    @Test func removeLineBreaksMakesOneLine() {
        let lines = [line("Раз", x: 0, y: 0.8), line("два", x: 0, y: 0.7), line("три", x: 0, y: 0.6)]
        #expect(OcrPostProcessor.assemble(lines, removeLineBreaks: true) == "Раз два три")
    }

    @Test func removeLineBreaksGluesHyphenatedWords() {
        let lines = [line("перено-", x: 0, y: 0.8), line("сится слово", x: 0, y: 0.7), line("и 5-", x: 0, y: 0.6), line("10 штук", x: 0, y: 0.5)]
        #expect(OcrPostProcessor.assemble(lines, removeLineBreaks: true) == "переносится слово и 5- 10 штук")
    }

    @Test func lowConfidenceLinesAreDropped() {
        let lines = [line("годно", x: 0, y: 0.8, conf: 0.9), line("мусор", x: 0, y: 0.73, conf: 0.1)]
        #expect(OcrPostProcessor.assemble(lines, removeLineBreaks: false, minConfidence: 0.5) == "годно")
        #expect(OcrPostProcessor.assemble(lines, removeLineBreaks: false) == "годно\nмусор")
    }

    @Test func blankInputGivesEmptyString() {
        #expect(OcrPostProcessor.assemble([], removeLineBreaks: false) == "")
        #expect(OcrPostProcessor.assemble([OcrLine("   \u{00A0} ")], removeLineBreaks: true) == "")
    }

    @Test func linesWithoutGeometryKeepInputOrder() {
        let lines = [OcrLine("один"), OcrLine("два"), OcrLine("три")]
        #expect(OcrPostProcessor.assemble(lines, removeLineBreaks: false) == "один\nдва\nтри")
        #expect(OcrPostProcessor.assemble(lines, removeLineBreaks: true) == "один два три")
    }

    @Test func normalizeCleansInvisibleAndRepeatedSpaces() {
        #expect(OcrPostProcessor.normalize("  a\u{00A0}\u{00A0}b\tc\u{200B}d \n") == "a b cd")
    }
}

@Suite struct QrClassifierTests {
    @Test func httpLinksAreOpenable() {
        let c = QrClassifier.classify("https://example.com/a?b=1")
        #expect(c == .url(URL(string: "https://example.com/a?b=1")!))
        #expect(c.openURL?.absoluteString == "https://example.com/a?b=1")
        #expect(c.title == "Ссылка")
    }

    @Test func dangerousSchemesStayPlainText() {
        for s in ["javascript:alert(1)", "file:///etc/passwd", "ftp://host/x", "data:text/html,hi", "smb://server/share"] {
            let c = QrClassifier.classify(s)
            #expect(c == .text(s), "\(s)")
            #expect(c.openURL == nil)
        }
    }

    @Test func textWithSpacesIsNotALink() {
        #expect(QrClassifier.classify("https://example.com is cool") == .text("https://example.com is cool"))
    }

    @Test func emailsAndMailto() {
        #expect(QrClassifier.classify("user@example.com") == .email("user@example.com"))
        #expect(QrClassifier.classify("mailto:user@example.com?subject=hi") == .email("user@example.com"))
        #expect(QrClassifier.classify("user@example.com").openURL?.absoluteString == "mailto:user@example.com")
        #expect(QrClassifier.classify("a@b") == .text("a@b"))
    }

    @Test func phones() {
        let c = QrClassifier.classify("tel:+7 (999) 123-45-67")
        #expect(c == .phone("+7 (999) 123-45-67"))
        #expect(c.openURL?.absoluteString == "tel:+79991234567")
        #expect(QrClassifier.classify("tel:abc") == .text("tel:abc"))
    }

    @Test func wifiPayloadIsParsedWithEscapes() {
        let c = QrClassifier.classify("WIFI:T:WPA;S:Home\\;Net;P:pa\\:ss;;")
        #expect(c == .wifi(ssid: "Home;Net", password: "pa:ss", security: "WPA"))
        #expect(c.copyText == "pa:ss")
        #expect(c.openURL == nil)
        #expect(c.displayText.contains("Home;Net") && c.displayText.contains("pa:ss"))
        #expect(QrClassifier.classify("WIFI:T:WPA;;") == .text("WIFI:T:WPA;;"))
    }

    @Test func plainTextIsTrimmed() {
        #expect(QrClassifier.classify("  привет\n") == .text("привет"))
        #expect(QrClassifier.classify("привет").copyText == "привет")
    }
}

@Suite struct ScreenOcrEngineTests {
    private func rig(_ configure: (TlsRecognizer) -> Void = { _ in }, settings: OcrSettings = OcrSettings()) -> (ScreenOcrEngine, TlsRecognizer, TlsTextSink) {
        let rec = TlsRecognizer()
        configure(rec)
        let sink = TlsTextSink()
        return (ScreenOcrEngine(recognizer: rec, clipboard: sink, settings: settings), rec, sink)
    }

    @Test func recognizedTextIsCopied() {
        let (e, rec, sink) = rig { $0.lines = [line("Привет", x: 0, y: 0.8), line("мир", x: 0, y: 0.73)] }
        #expect(e.process(tlsImage()) == .text("Привет\nмир"))
        #expect(sink.writes == ["Привет\nмир"])
        #expect(rec.textCalls == 1)
    }

    @Test func removeLineBreaksSettingIsApplied() {
        var s = OcrSettings()
        s.removeLineBreaks = true
        let (e, _, sink) = rig({ $0.lines = [line("Привет", x: 0, y: 0.8), line("мир", x: 0, y: 0.7)] }, settings: s)
        #expect(e.process(tlsImage()) == .text("Привет мир"))
        #expect(sink.writes == ["Привет мир"])
    }

    @Test func qrWinsOverTextAndIsNotCopiedAutomatically() {
        let (e, rec, sink) = rig { $0.codes = ["https://example.com"]; $0.lines = [line("текст", x: 0, y: 0.5)] }
        let out = e.process(tlsImage())
        #expect(out == .codes([.url(URL(string: "https://example.com")!)]))
        #expect(rec.textCalls == 0)
        #expect(sink.writes.isEmpty)
    }

    @Test func qrDetectionCanBeDisabled() {
        var s = OcrSettings()
        s.detectQr = false
        let (e, rec, _) = rig({ $0.codes = ["x"]; $0.lines = [line("текст", x: 0, y: 0.5)] }, settings: s)
        #expect(e.process(tlsImage()) == .text("текст"))
        #expect(rec.codeCalls == 0)
    }

    @Test func noTextMeansNothingAndNoClipboardWrite() {
        let (e, _, sink) = rig()
        #expect(e.process(tlsImage()) == .nothing)
        #expect(sink.writes.isEmpty)
    }

    @Test func visionErrorBecomesFailure() {
        let (e, _, sink) = rig { $0.error = TlsError() }
        #expect(e.process(tlsImage()) == .failed("boom"))
        #expect(sink.writes.isEmpty)
    }

    @Test func tinyRegionIsRejectedBeforeVision() {
        let (e, rec, _) = rig()
        #expect(e.process(tlsImage(2, 2)) == .nothing)
        #expect(rec.textCalls == 0 && rec.codeCalls == 0)
    }

    @Test func requestConfigReachesTheRecognizer() {
        var s = OcrSettings()
        s.request.level = .fast
        s.request.languages = ["en-US"]
        let (e, rec, _) = rig({ $0.lines = [OcrLine("x")] }, settings: s)
        _ = e.process(tlsImage())
        #expect(rec.lastConfig?.level == .fast && rec.lastConfig?.languages == ["en-US"])
    }

    @Test func lowConfidenceThresholdFiltersEverythingToNothing() {
        var s = OcrSettings()
        s.minConfidence = 0.9
        let (e, _, sink) = rig({ $0.lines = [line("шум", x: 0, y: 0.5, conf: 0.2)] }, settings: s)
        #expect(e.process(tlsImage()) == .nothing)
        #expect(sink.writes.isEmpty)
    }
}
