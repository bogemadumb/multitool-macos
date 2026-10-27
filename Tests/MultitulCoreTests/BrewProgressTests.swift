import Testing
import Foundation
@testable import MultitulCore

private let upgradeTranscript = """
==> Upgrading 2 outdated packages:
wget 1.24.5 -> 1.25.0
curl 8.9.0 -> 8.10.1
==> Fetching downloads for: wget and curl
✔︎ Bottle Manifest wget (1.25.0)  [Downloaded   10.0KB/ 10.0KB]
✔︎ Bottle wget (1.25.0)           [Downloaded    1.0MB/  1.0MB]
✔︎ Bottle curl (8.10.1)           [Downloaded    2.0MB/  2.0MB]
==> Upgrading wget
  1.24.5 -> 1.25.0
==> Pouring wget--1.25.0.arm64_sequoia.bottle.tar.gz
🍺  /opt/homebrew/Cellar/wget/1.25.0: 92 files, 4.5MB
==> Running `brew cleanup wget`...
==> Upgrading curl
  8.9.0 -> 8.10.1
==> Pouring curl--8.10.1.arm64_sequoia.bottle.tar.gz
🍺  /opt/homebrew/Cellar/curl/8.10.1: 530 files, 4.2MB
"""

private func feedAll(_ text: String) -> BrewProgressTracker {
    var t = BrewProgressTracker()
    for l in text.split(separator: "\n", omittingEmptySubsequences: false) { t.feed(String(l)) }
    return t
}

@Suite struct BrewProgressParserTests {
    @Test func planHeaderCarriesTheCount() {
        #expect(BrewProgressParser.parse("==> Upgrading 3 outdated packages:") == .plan(count: 3))
        #expect(BrewProgressParser.parse("==> Upgrading 1 outdated package:") == .plan(count: 1))
    }

    @Test func plannedVersionLine() {
        #expect(BrewProgressParser.parse("wget 1.24.5 -> 1.25.0") == .planned(name: "wget", from: "1.24.5", to: "1.25.0"))
        #expect(BrewProgressParser.parse("  1.24.5 -> 1.25.0 ") == .plain("1.24.5 -> 1.25.0"))
    }

    @Test func downloadingAndFetching() {
        #expect(BrewProgressParser.parse("==> Downloading https://ghcr.io/v2/homebrew/core/wget/blobs/sha256:abc") == .downloading("https://ghcr.io/v2/homebrew/core/wget/blobs/sha256:abc"))
        #expect(BrewProgressParser.parse("==> Downloading from https://cdn.example.com/x.dmg") == .downloading("https://cdn.example.com/x.dmg"))
        #expect(BrewProgressParser.parse("==> Fetching wget") == .fetching("wget"))
        #expect(BrewProgressParser.parse("==> Fetching downloads for: wget and curl") == .fetching("wget and curl"))
    }

    @Test func pouringUpgradingInstalling() {
        #expect(BrewProgressParser.parse("==> Pouring wget--1.25.0.arm64_sequoia.bottle.tar.gz") == .pouring("wget--1.25.0.arm64_sequoia.bottle.tar.gz"))
        #expect(BrewProgressParser.parse("==> Upgrading wget") == .upgrading("wget"))
        #expect(BrewProgressParser.parse("==> Installing wget") == .installing("wget"))
        #expect(BrewProgressParser.parse("==> Installing Cask firefox") == .installing("firefox"))
        #expect(BrewProgressParser.parse("==> Uninstalling Cask firefox") == .uninstalling("firefox"))
    }

    @Test func downloadedBottleMarkers() {
        #expect(BrewProgressParser.parse("✔︎ Bottle wget (1.25.0)  [Downloaded 1.0MB/1.0MB]") == .downloaded("wget"))
        #expect(BrewProgressParser.parse("✔︎ Cask firefox (130.0)  [Downloaded 80MB/80MB]") == .downloaded("firefox"))
        #expect(BrewProgressParser.parse("✔︎ Bottle Manifest wget (1.25.0)") == .step("Bottle Manifest wget (1.25.0)"))
    }

    @Test func errorsAndWarnings() {
        #expect(BrewProgressParser.parse("Error: No available formula with the name \"foo\".") == .error("No available formula with the name \"foo\"."))
        #expect(BrewProgressParser.parse("Warning: wget 1.25.0 is already installed and up-to-date.") == .warning("wget 1.25.0 is already installed and up-to-date."))
    }

    @Test func summaryAndSuccessLines() {
        #expect(BrewProgressParser.parse("🍺  /opt/homebrew/Cellar/wget/1.25.0: 92 files, 4.5MB") == .summary("/opt/homebrew/Cellar/wget/1.25.0: 92 files, 4.5MB"))
        #expect(BrewProgressParser.parse("/opt/homebrew/Cellar/wget/1.25.0: 92 files, 4.5MB") == .summary("/opt/homebrew/Cellar/wget/1.25.0: 92 files, 4.5MB"))
        #expect(BrewProgressParser.parse("🍺  firefox was successfully installed!") == .succeeded("firefox"))
        #expect(BrewProgressParser.parse("firefox was successfully upgraded!") == .succeeded("firefox"))
    }

    @Test func percentLinesFromCurl() {
        #expect(BrewProgressParser.parse("######################                                       45.3%") == .percent(45.3))
        #expect(BrewProgressParser.parse("100.0%") == .percent(100))
    }

    @Test func cleanupAndSteps() {
        #expect(BrewProgressParser.parse("==> Running `brew cleanup wget`...") == .cleanup)
        #expect(BrewProgressParser.parse("==> Moving App 'Firefox.app' to '/Applications/Firefox.app'") == .step("Moving App 'Firefox.app' to '/Applications/Firefox.app'"))
        #expect(BrewProgressParser.parse("==> Caveats") == .caveats)
        #expect(BrewProgressParser.parse("==> Something new") == .section("Something new"))
    }

    @Test func passwordPrompts() {
        #expect(BrewProgressParser.parse("Password:") == .passwordPrompt)
        #expect(BrewProgressParser.parse("sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper") == .passwordPrompt)
        #expect(BrewProgressParser.parse("sudo: no tty present and no askpass program specified") == .passwordPrompt)
        #expect(BrewProgressParser.parse("Error: Failure while executing; `/usr/bin/sudo -E -- /usr/sbin/installer` exited with 1.") == .error("Failure while executing; `/usr/bin/sudo -E -- /usr/sbin/installer` exited with 1."))
        #expect(BrewProgressParser.isPasswordPrompt("Error: Failure while executing; `/usr/bin/sudo -E -- x` exited with 1."))
    }

    @Test func blankLineIsPlain() {
        #expect(BrewProgressParser.parse("   ") == .plain(""))
    }
}

@Suite struct BrewProgressTrackerTests {
    @Test func fullUpgradeTranscript() {
        var t = feedAll(upgradeTranscript)
        #expect(t.expectedCount == 2 && t.steps.map(\.name) == ["wget", "curl"])
        #expect(t.steps[0].state == .done && t.steps[1].state == .done)
        #expect(t.steps[0].from == "1.24.5" && t.steps[0].to == "1.25.0")
        #expect(t.errors.isEmpty && !t.needsPassword)
        t.finishAll()
        #expect(t.fraction == 1 && t.current == nil)
    }

    @Test func fractionGrowsAcrossPackages() {
        var t = BrewProgressTracker()
        #expect(t.fraction == nil)
        for l in ["==> Upgrading 2 outdated packages:", "wget 1 -> 2", "curl 1 -> 2"] { t.feed(l) }
        #expect(t.fraction == 0)
        t.feed("==> Upgrading wget")
        #expect(t.current == "wget" && t.fraction == 0)
        t.feed("==> Downloading https://x/y")
        t.feed("######  50.0%")
        #expect(t.fraction == 0.125)
        t.feed("🍺  /opt/homebrew/Cellar/wget/2: 9 files, 1MB")
        #expect(t.fraction == 0.5)
        t.feed("==> Upgrading curl")
        #expect(t.current == "curl" && t.fraction == 0.5)
    }

    @Test func singleInstallWithoutPlan() {
        var t = BrewProgressTracker()
        for l in ["==> Fetching jq", "==> Pouring jq--1.7.1.bottle.tar.gz", "==> Installing jq", "🍺  /opt/homebrew/Cellar/jq/1.7.1: 20 files, 1MB"] { t.feed(l) }
        #expect(t.steps.map(\.name) == ["jq"] && t.steps[0].state == .done && t.fraction == 1)
    }

    @Test func caskUpgradeUsesSuccessLine() {
        let t = feedAll("==> Upgrading 1 outdated package:\nfirefox 129.0 -> 130.0\n==> Upgrading firefox\n==> Downloading https://download.example/firefox.dmg\n==> Moving App 'Firefox.app'\n🍺  firefox was successfully upgraded!")
        #expect(t.succeededNames == ["firefox"] && t.steps.first?.state == .done)
    }

    @Test func passwordPromptIsFlagged() {
        let t = feedAll("==> Installing Cask docker\nPassword:\nsudo: a terminal is required to read the password")
        #expect(t.needsPassword && t.statusLine == "Нужен пароль администратора")
    }

    @Test func errorsAreCollected() {
        let t = feedAll("==> Upgrading wget\nError: wget: failed to download\nWarning: retrying")
        #expect(t.errors == ["wget: failed to download"] && t.warnings == ["retrying"])
    }

    @Test func caveatsAreCapturedUntilNextSection() {
        let t = feedAll("==> Installing postgresql@16\n==> Caveats\nThis formula has no default config.\nTo start it:\n  brew services start postgresql@16\n==> Summary\n🍺  /opt/homebrew/Cellar/postgresql@16/16.4: 3000 files, 60MB")
        #expect(t.caveats.count == 3 && t.caveats[0].hasPrefix("This formula"))
        #expect(t.steps.first?.state == .done)
    }

    @Test func statusLineShowsPhaseAndPackage() {
        var t = BrewProgressTracker()
        t.feed("==> Upgrading wget")
        #expect(t.statusLine == "Обновление: wget")
        t.feed("==> Pouring wget--1.bottle.tar.gz")
        #expect(t.statusLine == "Распаковка: wget")
    }

    @Test func finishAllKeepsFailedStepsOpen() {
        var t = feedAll("==> Upgrading wget\nError: boom")
        t.finishAll()
        #expect(t.steps.first?.state == .working)
    }

    @Test func uninstallFlow() {
        let t = feedAll("==> Uninstalling Cask firefox\n==> Backing App 'Firefox.app' up\n==> Removing App '/Applications/Firefox.app'\n==> Purging files for version 130.0 of Cask firefox")
        #expect(t.steps.map(\.name) == ["firefox"] && t.phase.hasPrefix("Purging"))
    }
}

@Suite struct BrewErrorClassifierTests {
    @Test func lockedByAnotherBrew() {
        let f = BrewErrorClassifier.classify("Error: A `brew upgrade` process has already locked /opt/homebrew/Cellar/wget/1.25.0.\nPlease wait for it to finish or terminate it to continue.")
        #expect(f.kind == .locked && f.summary.contains("занят"))
        #expect(BrewErrorClassifier.classify("Error: Another active Homebrew update process is already in progress.").kind == .locked)
    }

    @Test func offlineVariants() {
        for text in ["curl: (6) Could not resolve host: ghcr.io", "Error: Failed to download resource \"wget\"", "curl: (7) Failed to connect to github.com port 443", "fatal: unable to access 'https://github.com/Homebrew/brew/': Could not resolve host", "curl: (28) Operation timed out after 10000 ms"] {
            #expect(BrewErrorClassifier.classify(text).kind == .offline, "\(text)")
        }
    }

    @Test func sudoPromptsForCasks() {
        #expect(BrewErrorClassifier.classify("sudo: a terminal is required to read the password; either use the -S option").kind == .needsPassword)
        #expect(BrewErrorClassifier.classify("sudo: no tty present and no askpass program specified").kind == .needsPassword)
        #expect(BrewErrorClassifier.classify("Error: Failure while executing; `/usr/bin/sudo -E -- /usr/sbin/installer -pkg x` exited with 1.").kind == .needsPassword)
        #expect(BrewErrorClassifier.classify("Password:\n").kind == .needsPassword)
    }

    @Test func notFound() {
        #expect(BrewErrorClassifier.classify("Error: No available formula or cask with the name \"nope\".").kind == .notFound)
        #expect(BrewErrorClassifier.classify("Error: No formulae or casks found for nope.").kind == .notFound)
    }

    @Test func usedByOthers() {
        let f = BrewErrorClassifier.classify("Error: Refusing to uninstall /opt/homebrew/Cellar/openssl@3/3.4.0\nbecause it is required by curl, wget and 2 other formulae, which are currently installed.\nYou can override this and force removal with:\n  brew uninstall --ignore-dependencies openssl@3")
        #expect(f.kind == .inUse)
        let g = BrewErrorClassifier.classify("Error: Refusing to uninstall /x because it is required by curl, wget, which are currently installed.")
        #expect(g.blockers == ["curl", "wget"])
    }

    @Test func permissionChecksumDiskFull() {
        #expect(BrewErrorClassifier.classify("Error: The following directories are not writable by your user:\n/opt/homebrew/share").kind == .permission)
        #expect(BrewErrorClassifier.classify("Error: SHA256 mismatch\nExpected: abc\nActual: def").kind == .checksum)
        #expect(BrewErrorClassifier.classify("Error: No space left on device @ io_write").kind == .diskFull)
    }

    @Test func timeoutAndMissingBinary() {
        #expect(BrewErrorClassifier.classify("", status: 15, timedOut: true).kind == .timedOut)
        #expect(BrewErrorClassifier.classify("cannot launch /opt/homebrew/bin/brew: nope", status: 127).kind == .missingBrew)
    }

    @Test func unknownErrorKeepsTheFirstErrorLine() {
        let f = BrewErrorClassifier.classify("some noise\nError: something odd happened\nmore")
        #expect(f.kind == .other && f.message == "something odd happened" && f.summary.contains("something odd"))
        #expect(BrewErrorClassifier.classify("").kind == .other)
    }

    @Test func everyKindHasAReadableTitle() {
        for k in [BrewFailureKind.locked, .offline, .needsPassword, .notFound, .permission, .inUse, .checksum, .diskFull, .timedOut, .missingBrew, .other] {
            #expect(!k.title.isEmpty)
        }
    }
}
