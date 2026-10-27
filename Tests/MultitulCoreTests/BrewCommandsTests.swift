import Testing
import Foundation
@testable import MultitulCore

private let brew = "/opt/homebrew/bin/brew"
private func cmds(autoUpdate: Bool = true) -> BrewCommands { BrewCommands(brewPath: brew, autoUpdate: autoUpdate) }

@Suite struct BrewCommandsTests {
    @Test func readOnlyCommands() throws {
        let c = cmds()
        #expect(c.installedInfo().arguments == ["info", "--json=v2", "--installed"])
        #expect(c.outdated(greedy: false).arguments == ["outdated", "--json=v2"])
        #expect(c.outdated(greedy: true).arguments == ["outdated", "--json=v2", "--greedy"])
        #expect(c.leaves().arguments == ["leaves"])
        #expect(c.servicesList().arguments == ["services", "list", "--json"])
        #expect(try c.depsTree("wget").arguments == ["deps", "--tree", "wget"])
        #expect(try c.uses("openssl@3").arguments == ["uses", "--installed", "openssl@3"])
        #expect(try c.info("firefox", kind: .cask).arguments == ["info", "--json=v2", "--cask", "firefox"])
        #expect(c.installedInfo().executable == brew)
    }

    @Test func readOnlyCommandsNeverTriggerAnAutoUpdate() {
        let e = cmds().installedInfo().environment
        #expect(e["HOMEBREW_NO_AUTO_UPDATE"] == "1" && e["HOMEBREW_NO_ANALYTICS"] == "1" && e["NONINTERACTIVE"] == "1")
        #expect(e["HOMEBREW_NO_EMOJI"] == "1" && e["HOMEBREW_NO_COLOR"] == "1")
    }

    @Test func writesAllowTheIndexUpdateOnlyWhenSettingIsOn() throws {
        #expect(try cmds(autoUpdate: true).install("jq", kind: .formula).environment["HOMEBREW_NO_AUTO_UPDATE"] == nil)
        #expect(try cmds(autoUpdate: false).install("jq", kind: .formula).environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(cmds().update().environment["HOMEBREW_NO_AUTO_UPDATE"] == nil)
    }

    @Test func searchFlags() throws {
        #expect(try cmds().search("wget").arguments == ["search", "wget"])
        #expect(try cmds().search(" wget ", kind: .cask, descriptions: true).arguments == ["search", "--cask", "--desc", "wget"])
        #expect(try cmds().search("visual studio").arguments == ["search", "visual studio"])
    }

    @Test func badSearchQueriesAreRejected() {
        for q in ["", "  ", "--help", "-x", "a\nb"] {
            #expect(throws: BrewCommandError.self) { try cmds().search(q) }
        }
    }

    @Test func installAndUninstall() throws {
        #expect(try cmds().install("wget", kind: .formula).arguments == ["install", "--formula", "wget"])
        #expect(try cmds().install("firefox", kind: .cask).arguments == ["install", "--cask", "firefox"])
        #expect(try cmds().uninstall("firefox", kind: .cask, zap: true).arguments == ["uninstall", "--cask", "--zap", "firefox"])
        #expect(try cmds().uninstall("firefox", kind: .cask, zap: false).arguments == ["uninstall", "--cask", "firefox"])
        #expect(try cmds().uninstall("wget", kind: .formula, zap: true, ignoreDependencies: true).arguments == ["uninstall", "--formula", "--ignore-dependencies", "wget"])
    }

    @Test func upgradeVariants() throws {
        #expect(try cmds().upgrade(["wget", "curl"], kind: .formula).arguments == ["upgrade", "--formula", "wget", "curl"])
        #expect(try cmds().upgrade(["firefox"], kind: .cask, greedy: true).arguments == ["upgrade", "--cask", "--greedy", "firefox"])
        #expect(try cmds().upgrade(["wget"], kind: .formula, greedy: true).arguments == ["upgrade", "--formula", "wget"])
        #expect(cmds().upgradeAll(greedy: false).arguments == ["upgrade"])
        #expect(cmds().upgradeAll(greedy: true).arguments == ["upgrade", "--greedy"])
        #expect(throws: BrewCommandError.emptySelection) { try cmds().upgrade([], kind: .formula) }
    }

    @Test func pinServicesCleanup() throws {
        #expect(try cmds().pin("node", pinned: true).arguments == ["pin", "node"])
        #expect(try cmds().pin("node", pinned: false).arguments == ["unpin", "node"])
        #expect(try cmds().service(.restart, name: "redis").arguments == ["services", "restart", "redis"])
        #expect(try cmds().service(.run, name: "redis").arguments == ["services", "run", "redis"])
        #expect(cmds().servicesCleanup().arguments == ["services", "cleanup"])
        #expect(cmds().cleanup(dryRun: true).arguments == ["cleanup", "--dry-run"])
        #expect(cmds().cleanup(dryRun: false, pruneAll: true).arguments == ["cleanup", "--prune=all"])
        #expect(cmds().autoremove(dryRun: true).arguments == ["autoremove", "--dry-run"])
        #expect(cmds().autoremove(dryRun: false).arguments == ["autoremove"])
        #expect(cmds().doctor().arguments == ["doctor"])
    }

    @Test func dangerousNamesNeverReachTheArgumentList() {
        for bad in ["-rf", "a b", "x;y", "$(id)", "../etc", "x`y`", ""] {
            #expect(throws: BrewCommandError.self) { try cmds().install(bad, kind: .formula) }
            #expect(throws: BrewCommandError.self) { try cmds().uninstall(bad, kind: .cask) }
            #expect(throws: BrewCommandError.self) { try cmds().pin(bad, pinned: true) }
            #expect(throws: BrewCommandError.self) { try cmds().service(.start, name: bad) }
            #expect(throws: BrewCommandError.self) { try cmds().upgrade([bad], kind: .cask) }
        }
    }

    @Test func nothingEverRunsThroughSudo() throws {
        let all: [ManagerCommand] = [
            cmds().installedInfo(), cmds().outdated(greedy: true), cmds().leaves(), cmds().servicesList(), cmds().update(), cmds().upgradeAll(greedy: true),
            cmds().cleanup(dryRun: false), cmds().autoremove(dryRun: false), cmds().servicesCleanup(), cmds().doctor(),
            try cmds().install("a", kind: .cask), try cmds().uninstall("a", kind: .cask, zap: true), try cmds().service(.start, name: "a")
        ]
        for c in all {
            #expect(c.executable == brew && !c.runsAsRootEscalation)
            #expect(!c.arguments.contains("sudo") && !c.arguments.contains("-S"))
        }
        #expect(ManagerCommand("/usr/bin/sudo", ["brew"]).runsAsRootEscalation)
    }

    @Test func timeoutsFitTheOperation() throws {
        #expect(try cmds().install("a", kind: .formula).timeout >= 600)
        #expect(cmds().leaves().timeout <= 120)
        #expect(cmds().upgradeAll(greedy: false).timeout >= 3600)
    }

    @Test func terminalLineIsShellQuoted() throws {
        let line = cmds().terminalLine(try cmds().install("openssl@3", kind: .formula))
        #expect(line == "/opt/homebrew/bin/brew install --formula openssl@3")
        let odd = BrewCommands(brewPath: "/Users/x y/brew")
        let spaced = odd.terminalLine(odd.leaves())
        #expect(spaced.hasPrefix("'/Users/x y/brew'"))
    }

    @Test func installCommandPointsToTheOfficialScript() {
        #expect(BrewCommands.installCommand.contains("raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"))
    }

    @Test func displayNameShowsTheToolNotThePath() {
        #expect(cmds().leaves().display == "brew leaves")
    }
}
