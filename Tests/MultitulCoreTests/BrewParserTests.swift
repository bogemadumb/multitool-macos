import Testing
import Foundation
@testable import MultitulCore

private let infoJSON = """
{"formulae":[
 {"name":"wget","full_name":"wget","tap":"homebrew/core","desc":"Internet file retriever","homepage":"https://www.gnu.org/software/wget/",
  "versions":{"stable":"1.25.0","head":"HEAD","bottle":true},"dependencies":["libidn2","openssl@3"],
  "installed":[{"version":"1.24.5","installed_as_dependency":false,"installed_on_request":true}],
  "linked_keg":"1.24.5","pinned":false,"outdated":true,"deprecated":false,"disabled":false},
 {"name":"openssl@3","full_name":"openssl@3","tap":"homebrew/core","desc":"Cryptography","homepage":"https://openssl.org",
  "versions":{"stable":"3.4.0"},"dependencies":["ca-certificates"],
  "installed":[{"version":"3.3.2","installed_as_dependency":true,"installed_on_request":false},{"version":"3.4.0","installed_as_dependency":true,"installed_on_request":false}],
  "pinned":true,"outdated":false},
 {"name":"jq","full_name":"jq","tap":"homebrew/core","desc":"JSON processor","homepage":"https://jqlang.github.io/jq/","versions":{"stable":"1.7.1"},"dependencies":[],"installed":[],"pinned":false,"outdated":false}
],
"casks":[
 {"token":"firefox","full_token":"firefox","tap":"homebrew/cask","name":["Mozilla Firefox"],"desc":"Web browser","homepage":"https://www.mozilla.org/firefox/",
  "version":"130.0","installed":"129.0","outdated":true,"auto_updates":true,"deprecated":false,"disabled":false,
  "artifacts":[{"app":["Firefox.app"]},{"zap":[{"trash":["~/Library/Application Support/Firefox"]}]},["uninstall",{"quit":"org.mozilla.firefox"}]]},
 {"token":"iterm2","full_token":"iterm2","tap":"homebrew/cask","name":["iTerm2"],"version":"3.5.0","installed":null,"outdated":false,"auto_updates":false,"artifacts":[{"app":["iTerm.app"]}]}
]}
"""

@Suite struct BrewInfoParserTests {
    @Test func formulaFieldsAreRead() throws {
        let p = try #require(try BrewParsers.parseInfo(infoJSON).first { $0.name == "wget" })
        #expect(p.kind == .formula && p.fullName == "wget" && p.tap == "homebrew/core")
        #expect(p.installedVersion == "1.24.5" && p.latestVersion == "1.25.0")
        #expect(p.installedOnRequest && !p.installedAsDependency && p.outdated && !p.pinned)
        #expect(p.dependencies == ["libidn2", "openssl@3"] && p.desc == "Internet file retriever")
        #expect(p.id == "formula:wget")
    }

    @Test func dependencyAndPinnedFlags() throws {
        let p = try #require(try BrewParsers.parseInfo(infoJSON).first { $0.name == "openssl@3" })
        #expect(p.installedAsDependency && !p.installedOnRequest && p.pinned)
        #expect(p.installedVersion == "3.4.0")
    }

    @Test func notInstalledFormulaHasNoVersion() throws {
        let p = try #require(try BrewParsers.parseInfo(infoJSON).first { $0.name == "jq" })
        #expect(!p.isInstalled && p.installedVersion == nil && p.latestVersion == "1.7.1")
    }

    @Test func caskFieldsAndAppNames() throws {
        let p = try #require(try BrewParsers.parseInfo(infoJSON).first { $0.name == "firefox" })
        #expect(p.kind == .cask && p.displayName == "Mozilla Firefox" && p.installedVersion == "129.0" && p.latestVersion == "130.0")
        #expect(p.autoUpdates && p.outdated && p.appNames == ["Firefox.app"])
    }

    @Test func caskWithNullInstalledIsNotInstalled() throws {
        let p = try #require(try BrewParsers.parseInfo(infoJSON).first { $0.name == "iterm2" })
        #expect(!p.isInstalled && p.appNames == ["iTerm.app"] && !p.autoUpdates)
    }

    @Test func listsKeepFormulaeBeforeCasks() throws {
        let all = try BrewParsers.parseInfo(infoJSON)
        #expect(all.map(\.name) == ["wget", "openssl@3", "jq", "firefox", "iterm2"])
    }

    @Test func emptyAndWhitespaceOutputIsAnEmptyList() throws {
        #expect(try BrewParsers.parseInfo("").isEmpty)
        #expect(try BrewParsers.parseInfo("  \n\n").isEmpty)
        #expect(try BrewParsers.parseInfo(#"{"formulae":[],"casks":[]}"#).isEmpty)
    }

    @Test func malformedJsonThrows() {
        #expect(throws: BrewParseError.invalidJSON) { try BrewParsers.parseInfo("{\"formulae\": [") }
        #expect(throws: BrewParseError.invalidJSON) { try BrewParsers.parseInfo("Error: something broke") }
    }

    @Test func wrongShapeThrows() {
        #expect(throws: BrewParseError.unexpectedShape) { try BrewParsers.parseInfo("[1,2]") }
    }

    @Test func entriesWithoutNameAreSkipped() throws {
        let t = try BrewParsers.parseInfo(#"{"formulae":[{"desc":"x"},{"name":""},{"name":"ok","installed":[]}],"casks":[{"name":["x"]}]}"#)
        #expect(t.map(\.name) == ["ok"])
    }
}

@Suite struct BrewOutdatedParserTests {
    @Test func formulaeAndCasksWithArrays() throws {
        let t = try BrewParsers.parseOutdated("""
        {"formulae":[{"name":"wget","installed_versions":["1.24.5"],"current_version":"1.25.0","pinned":false,"pinned_version":null},
                     {"name":"node","installed_versions":["21.0","22.1"],"current_version":"23.0","pinned":true,"pinned_version":"22.1"}],
         "casks":[{"name":"firefox","installed_versions":["129.0"],"current_version":"130.0"}]}
        """)
        #expect(t.count == 3)
        #expect(t[0] == BrewOutdatedItem(name: "wget", kind: .formula, installedVersions: ["1.24.5"], currentVersion: "1.25.0"))
        #expect(t[1].pinned && t[1].installedVersion == "22.1")
        #expect(t[2].kind == .cask && t[2].currentVersion == "130.0")
    }

    @Test func caskInstalledVersionsAsString() throws {
        let t = try BrewParsers.parseOutdated(#"{"formulae":[],"casks":[{"name":"iterm2","installed_versions":"3.4.0","current_version":"3.5.0"}]}"#)
        #expect(t.first?.installedVersions == ["3.4.0"] && t.first?.id == "cask:iterm2")
    }

    @Test func nothingOutdated() throws {
        #expect(try BrewParsers.parseOutdated(#"{"formulae":[],"casks":[]}"#).isEmpty)
        #expect(try BrewParsers.parseOutdated("").isEmpty)
    }

    @Test func malformedOutdatedThrows() {
        #expect(throws: BrewParseError.invalidJSON) { try BrewParsers.parseOutdated("<html>") }
        #expect(throws: BrewParseError.unexpectedShape) { try BrewParsers.parseOutdated("[]") }
    }

    @Test func numericCurrentVersionIsKept() throws {
        let t = try BrewParsers.parseOutdated(#"{"formulae":[{"name":"x","installed_versions":["1"],"current_version":2}],"casks":[]}"#)
        #expect(t.first?.currentVersion == "2")
    }
}

@Suite struct BrewServicesParserTests {
    @Test func statusesAndFields() throws {
        let t = try BrewParsers.parseServices("""
        [{"name":"postgresql@16","status":"started","user":"user","file":"/Users/user/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist","exit_code":0},
         {"name":"redis","status":"none","user":null,"file":null,"exit_code":null},
         {"name":"nginx","status":"error","user":"user","file":"/x.plist","exit_code":78},
         {"name":"cron","status":"scheduled","user":"user","file":"/y.plist","exit_code":0},
         {"name":"weird","status":"paused"}]
        """)
        #expect(t.map(\.status) == [.started, .none, .error, .scheduled, .unknown])
        #expect(t[0].exitCode == 0 && t[0].user == "user" && t[0].status.isRunning)
        #expect(t[1].user.isEmpty && t[1].file.isEmpty && t[1].exitCode == nil && !t[1].status.isRunning)
        #expect(t[2].exitCode == 78 && t[3].status.isRunning)
    }

    @Test func emptyListAndEmptyOutput() throws {
        #expect(try BrewParsers.parseServices("[]").isEmpty)
        #expect(try BrewParsers.parseServices("").isEmpty)
    }

    @Test func malformedServicesThrow() {
        #expect(throws: BrewParseError.invalidJSON) { try BrewParsers.parseServices("Error: no") }
        #expect(throws: BrewParseError.unexpectedShape) { try BrewParsers.parseServices(#"{"name":"x"}"#) }
    }
}

@Suite struct BrewTextParserTests {
    @Test func searchWithBothHeaders() {
        let r = BrewParsers.parseSearch("==> Formulae\nwget\nwgetpaste\n\n==> Casks\nwget-gui\n")
        #expect(r.map(\.name) == ["wget", "wgetpaste", "wget-gui"])
        #expect(r.map(\.kind) == [.formula, .formula, .cask])
    }

    @Test func searchWithoutHeadersUsesDefaultKind() {
        let r = BrewParsers.parseSearch("firefox\nfirefox@beta\n", defaultKind: .cask)
        #expect(r.count == 2 && r.allSatisfy { $0.kind == .cask })
        #expect(BrewParsers.parseSearch("jq\n").first?.kind == nil)
    }

    @Test func searchWithDescriptions() {
        let r = BrewParsers.parseSearch("==> Formulae\nwget: Internet file retriever\njq: Lightweight and flexible command-line JSON processor\n")
        #expect(r[0].name == "wget" && r[0].desc == "Internet file retriever")
        #expect(r[1].desc.hasPrefix("Lightweight"))
    }

    @Test func searchSkipsNoiseAndDuplicates() {
        let r = BrewParsers.parseSearch("==> Searching local taps...\n✔ wget\nwget\nNo formula or cask found for \"zzz\".\nError: boom\n\nuser/tap/tool\n")
        #expect(r.map(\.name) == ["wget", "user/tap/tool"])
    }

    @Test func emptySearchOutput() {
        #expect(BrewParsers.parseSearch("").isEmpty)
        #expect(BrewParsers.parseSearch("\n\n  \n").isEmpty)
    }

    @Test func leavesListDedupes() {
        #expect(BrewParsers.parseNameList("wget\n\njq\nwget\n  node@22  \n") == ["wget", "jq", "node@22"])
        #expect(BrewParsers.parseNameList("").isEmpty)
    }

    @Test func dependencyTree() throws {
        let tree = try #require(BrewParsers.parseDepsTree("""
        wget
        ├── libidn2
        │   ├── gettext
        │   └── libunistring
        ├── openssl@3
        │   └── ca-certificates
        └── libnghttp2
        """))
        #expect(tree.name == "wget" && tree.children.map(\.name) == ["libidn2", "openssl@3", "libnghttp2"])
        #expect(tree.children[0].children.map(\.name) == ["gettext", "libunistring"])
        #expect(tree.children[1].children.first?.name == "ca-certificates")
        #expect(tree.depth == 3 && tree.flattened.count == 6)
    }

    @Test func deeperAndLastBranchIndent() throws {
        let tree = try #require(BrewParsers.parseDepsTree("a\n└── b\n    └── c\n        └── d\n"))
        #expect(tree.flattened == ["b", "c", "d"] && tree.depth == 4)
    }

    @Test func treeWithoutDependenciesAndEmpty() {
        #expect(BrewParsers.parseDepsTree("jq\n")?.children.isEmpty == true)
        #expect(BrewParsers.parseDepsTree("") == nil)
        #expect(BrewParsers.parseDepsTree("Error: No available formula") == nil)
    }

    @Test func dedupedTreeNodesWithMarker() throws {
        let tree = try #require(BrewParsers.parseDepsTree("a\n├── b\n│   └── c\n└── c (*)\n"))
        #expect(tree.children.map(\.name) == ["b", "c"])
    }

    @Test func autoremoveDryRun() {
        let out = "==> Would autoremove 2 unneeded formulae:\nlibevent\nreadline\n"
        #expect(BrewParsers.parseAutoremove(out) == ["libevent", "readline"])
        #expect(BrewParsers.parseAutoremove("").isEmpty)
        #expect(BrewParsers.parseAutoremove("==> Would autoremove 1 unneeded formula:\nx\n==> Other\ny").first == "x")
    }

    @Test func cleanupDryRunReport() {
        let r = BrewParsers.parseCleanup("Would remove: /opt/homebrew/Cellar/wget/1.24.5 (92 files, 4.5MB)\nWould remove: /Users/x/Library/Caches/Homebrew/wget--1.24.5 (1.2MB)\n==> This operation would free approximately 5.7MB of disk space.\n")
        #expect(r.isDryRun && r.items.count == 2 && r.bytes == Int64(5.7 * 1024 * 1024))
    }

    @Test func cleanupRealReport() {
        let r = BrewParsers.parseCleanup("Removing: /Users/x/Library/Caches/Homebrew/a--1 (3.1GB)...\n==> This operation has freed approximately 3.1GB of disk space.\n")
        #expect(!r.isDryRun && r.items.count == 1 && r.bytes == Int64(3.1 * 1024 * 1024 * 1024))
        #expect(BrewParsers.parseCleanup("").items.isEmpty && BrewParsers.parseCleanup("").bytes == 0)
    }

    @Test func sizeUnits() {
        #expect(BrewParsers.sizeBytes(in: "10B") == 10)
        #expect(BrewParsers.sizeBytes(in: "freed 512KB of") == Int64(524_288))
        #expect(BrewParsers.sizeBytes(in: "3.1 MB") == Int64(3.1 * 1_048_576))
        #expect(BrewParsers.sizeBytes(in: "no size here") == nil)
    }

    @Test func nameValidation() {
        for ok in ["wget", "openssl@3", "python@3.12", "user/tap/tool", "g++", "font-fira-code", "a_b"] { #expect(BrewName.isValid(ok), "\(ok)") }
        for bad in ["", "-rf", "a b", "a;b", "$(x)", "/etc/passwd", "../x", "wget\n", "имя", "a|b", "a`b"] { #expect(!BrewName.isValid(bad), "\(bad)") }
        #expect(BrewName.isValidQuery("visual studio code") && !BrewName.isValidQuery("--help") && !BrewName.isValidQuery("") && !BrewName.isValidQuery("a\nb"))
    }
}
