import Testing
import Foundation
@testable import MultitulCore

private let infoJSON = #"{"formulae":[{"name":"wget","full_name":"wget","tap":"homebrew/core","versions":{"stable":"1.25.0"},"installed":[{"version":"1.24.5","installed_on_request":true}]},{"name":"openssl@3","full_name":"openssl@3","versions":{"stable":"3.4.0"},"installed":[{"version":"3.4.0","installed_as_dependency":true}]}],"casks":[{"token":"firefox","name":["Firefox"],"version":"130.0","installed":"129.0","auto_updates":true,"artifacts":[{"app":["Firefox.app"]}]}]}"#
private let outdatedJSON = #"{"formulae":[{"name":"wget","installed_versions":["1.24.5"],"current_version":"1.25.0","pinned":false}],"casks":[{"name":"firefox","installed_versions":"129.0","current_version":"130.0"}]}"#

@MainActor
private struct Rig {
    let runner = MgrRunner()
    let terminal = MgrTerminal()
    let clock = TlsClock()
    let manager: BrewManager

    init(brewInstalled: Bool = true, settings: BrewSettings = BrewSettings()) {
        let files = mgrFiles(executables: brewInstalled ? ["/opt/homebrew/bin/brew"] : [])
        manager = BrewManager(runner: runner, locator: ToolLocator(files: files), settings: settings, clock: clock)
        manager.terminal = terminal
        manager.detect()
    }

    func scriptHealthy() {
        runner.on("info --json=v2 --installed", out: infoJSON)
        runner.on("outdated --json=v2", out: outdatedJSON)
        runner.on("leaves", out: "wget\n")
        runner.on("services list --json", out: #"[{"name":"redis","status":"started","user":"me","file":"/x.plist","exit_code":0}]"#)
    }
}

@MainActor @Suite struct BrewManagerReadTests {
    @Test func detectsBrewInTheStandardPrefix() {
        let r = Rig()
        #expect(r.manager.availability == .available("/opt/homebrew/bin/brew"))
        #expect(r.manager.commands?.brewPath == "/opt/homebrew/bin/brew")
    }

    @Test func missingBrewIsReportedWithoutRunningAnything() async {
        let r = Rig(brewInstalled: false)
        #expect(r.manager.availability == .missing)
        await r.manager.refresh()
        #expect(r.manager.lastFailure?.kind == .missingBrew && r.runner.calls.isEmpty)
    }

    @Test func refreshMergesInstalledOutdatedLeavesAndServices() async {
        let r = Rig()
        r.scriptHealthy()
        await r.manager.refresh()
        let s = r.manager.snapshot
        #expect(s.packages.map(\.name) == ["wget", "openssl@3", "firefox"])
        #expect(s.packages.first { $0.name == "wget" }?.outdated == true && s.packages.first { $0.name == "firefox" }?.outdated == true)
        #expect(s.leafPackages.map(\.name) == ["wget"] && s.dependencyPackages.map(\.name) == ["openssl@3"])
        #expect(s.casks.count == 1 && s.outdatedCount == 2 && s.services.map(\.name) == ["redis"])
        #expect(s.loadedAt == r.clock.now && r.manager.lastFailure == nil && !r.manager.isRefreshing)
    }

    @Test func refreshAsksBrewForExactlyTheFourReadCommands() async {
        let r = Rig()
        r.scriptHealthy()
        await r.manager.refresh()
        #expect(Set(r.runner.argLines) == ["info --json=v2 --installed", "outdated --json=v2", "leaves", "services list --json"])
    }

    @Test func greedySettingReachesOutdated() async {
        var s = BrewSettings()
        s.includeGreedy = true
        let r = Rig(settings: s)
        r.scriptHealthy()
        r.runner.on("outdated --json=v2 --greedy", out: outdatedJSON)
        await r.manager.refresh()
        #expect(r.runner.argLines.contains("outdated --json=v2 --greedy"))
    }

    @Test func malformedInfoKeepsThePreviousList() async {
        let r = Rig()
        r.scriptHealthy()
        await r.manager.refresh()
        r.runner.on("info --json=v2 --installed", out: "{ broken")
        await r.manager.refresh()
        #expect(r.manager.lastFailure?.kind == .other)
        #expect(r.manager.snapshot.packages.count == 3)
    }

    @Test func offlineFailureIsClassified() async {
        let r = Rig()
        r.scriptHealthy()
        r.runner.on("outdated --json=v2", status: 1, err: "curl: (6) Could not resolve host: ghcr.io")
        await r.manager.refresh()
        #expect(r.manager.lastFailure?.kind == .offline)
        #expect(r.manager.snapshot.packages.count == 3)
    }

    @Test func servicesFailureDoesNotFailTheRefresh() async {
        let r = Rig()
        r.scriptHealthy()
        r.runner.on("services list --json", status: 1, err: "Error: Unknown command: services")
        await r.manager.refresh()
        #expect(r.manager.snapshot.services.isEmpty && r.manager.lastFailure == nil)
    }

    @Test func emptyBrewIsFine() async {
        let r = Rig()
        r.runner.on("info --json=v2 --installed", out: #"{"formulae":[],"casks":[]}"#)
        r.runner.on("outdated --json=v2", out: #"{"formulae":[],"casks":[]}"#)
        r.runner.on("leaves", out: "")
        r.runner.on("services list --json", out: "[]")
        await r.manager.refresh()
        #expect(r.manager.snapshot.packages.isEmpty && r.manager.lastFailure == nil)
    }

    @Test func searchParsesAndLimits() async {
        var s = BrewSettings()
        s.searchLimit = 10
        let r = Rig(settings: s)
        let names = (0..<30).map { "pkg\($0)" }.joined(separator: "\n")
        r.runner.on("search --desc", out: "==> Formulae\n" + names + "\n==> Casks\nwget-gui")
        await r.manager.search("pkg")
        #expect(r.manager.searchResults.count == 10)
        #expect(r.runner.argLines == ["search --desc pkg"])
    }

    @Test func searchWithoutResultsIsNotAnError() async {
        let r = Rig()
        r.runner.on("search", status: 1, err: "Error: No formulae or casks found for \"zzzz\".")
        await r.manager.search("zzzz")
        #expect(r.manager.searchResults.isEmpty && r.manager.lastFailure == nil)
    }

    @Test func searchOfflineSetsFailure() async {
        let r = Rig()
        r.runner.on("search", status: 1, err: "curl: (6) Could not resolve host: formulae.brew.sh")
        await r.manager.search("wget")
        #expect(r.manager.lastFailure?.kind == .offline)
    }

    @Test func emptyQueryClearsTheResults() async {
        let r = Rig()
        r.runner.on("search", out: "wget\n")
        await r.manager.search("wget")
        #expect(r.manager.searchResults.count == 1)
        await r.manager.search("   ")
        #expect(r.manager.searchResults.isEmpty)
    }

    @Test func detailsTreeAndDependents() async {
        let r = Rig()
        r.runner.on("info --json=v2 --formula wget", out: infoJSON)
        r.runner.on("deps --tree wget", out: "wget\n├── libidn2\n└── openssl@3\n")
        r.runner.on("uses --installed wget", out: "curl\n")
        let p = await r.manager.details(of: "wget", kind: .formula)
        #expect(p?.name == "wget")
        #expect(await r.manager.dependencyTree(of: "wget")?.children.count == 2)
        #expect(await r.manager.dependents(of: "wget") == ["curl"])
        #expect(await r.manager.dependencyTree(of: "bad name") == nil)
    }

    @Test func orphanAndCleanupPreviews() async {
        let r = Rig()
        r.runner.on("autoremove --dry-run", out: "==> Would autoremove 1 unneeded formula:\nlibevent\n")
        r.runner.on("cleanup --dry-run", out: "Would remove: /x (1MB)\n==> This operation would free approximately 1MB of disk space.\n")
        await r.manager.previewOrphans()
        await r.manager.previewCleanup()
        #expect(r.manager.snapshot.orphans == ["libevent"])
        #expect(r.manager.snapshot.cleanup?.bytes == 1_048_576 && r.manager.snapshot.cleanup?.isDryRun == true)
    }

    @Test func caskDataRefreshesStaleSnapshotOnly() async {
        let r = Rig()
        r.scriptHealthy()
        let first = await r.manager.caskData()
        #expect(first.installed.map(\.name) == ["firefox"] && first.outdated.map(\.name) == ["firefox"])
        let calls = r.runner.calls.count
        _ = await r.manager.caskData()
        #expect(r.runner.calls.count == calls)
        r.clock.advance(600)
        _ = await r.manager.caskData()
        #expect(r.runner.calls.count > calls)
    }
}

@MainActor @Suite struct BrewManagerJobTests {
    private func finished(_ r: Rig) async {
        await r.manager.queue.waitUntilIdle()
        await mgrWait { !r.manager.isRefreshing && r.runner.argLines.filter { $0 == "leaves" }.count >= 1 }
    }

    @Test func upgradeStreamsProgressAndRefreshesAfterwards() async {
        let r = Rig()
        r.scriptHealthy()
        let lines = ["==> Upgrading 1 outdated package:", "wget 1.24.5 -> 1.25.0", "==> Upgrading wget", "==> Pouring wget--1.25.0.bottle.tar.gz", "🍺  /opt/homebrew/Cellar/wget/1.25.0: 92 files, 4.5MB"]
        r.runner.on("upgrade --formula wget", lines: lines.map { ManagerLine(.out, $0) })
        let id = r.manager.upgrade("wget", kind: .formula)
        #expect(id != nil)
        await finished(r)
        let j = r.manager.queue.job(id!)
        #expect(j?.state == .succeeded && j?.result == "wget обновлён" && j?.log.count == 5)
        #expect(r.runner.argLines.contains("upgrade --formula wget") && r.runner.argLines.contains("info --json=v2 --installed"))
        #expect(r.manager.snapshot.packages.count == 3)
    }

    @Test func lockedBrewFailsWithAReadableMessage() async {
        let r = Rig()
        r.scriptHealthy()
        r.runner.on("upgrade", status: 1, lines: [ManagerLine(.err, "Error: A `brew upgrade` process has already locked /opt/homebrew/Cellar/wget/1.25.0.")], err: "Error: A `brew upgrade` process has already locked /opt/homebrew/Cellar/wget/1.25.0.")
        let id = r.manager.upgradeAll()!
        await finished(r)
        guard case .failed(let m)? = r.manager.queue.job(id)?.state else { Issue.record("expected failure"); return }
        #expect(m.contains("занят"))
    }

    @Test func noInternetDuringInstall() async {
        let r = Rig()
        r.scriptHealthy()
        r.runner.on("install --formula jq", status: 1, lines: [ManagerLine(.err, "curl: (6) Could not resolve host: ghcr.io")], err: "curl: (6) Could not resolve host: ghcr.io\nError: Failed to download resource \"jq\"")
        let id = r.manager.install("jq", kind: .formula)!
        await finished(r)
        guard case .failed(let m)? = r.manager.queue.job(id)?.state else { Issue.record("expected failure"); return }
        #expect(m.contains("интернет"))
    }

    @Test func caskNeedingSudoOffersTerminal() async {
        let r = Rig()
        r.scriptHealthy()
        let err = "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper\nError: Failure while executing; `/usr/bin/sudo -E -- /usr/sbin/installer` exited with 1."
        r.runner.on("install --cask docker", status: 1, lines: [ManagerLine(.err, "Password:")], err: err)
        let id = r.manager.install("docker", kind: .cask)!
        await finished(r)
        guard case .failed(let m)? = r.manager.queue.job(id)?.state else { Issue.record("expected failure"); return }
        #expect(m.contains("пароль") && m.contains("Terminal"))
        #expect(r.manager.terminalLines[id] == "/opt/homebrew/bin/brew install --cask docker")
        #expect(r.manager.openInTerminal(job: id))
        #expect(r.terminal.commands == ["/opt/homebrew/bin/brew install --cask docker"])
    }

    @Test func preferTerminalSendsCasksStraightThere() async {
        var s = BrewSettings()
        s.preferTerminalForCasks = true
        let r = Rig(settings: s)
        r.scriptHealthy()
        let id = r.manager.install("docker", kind: .cask)!
        await r.manager.queue.waitUntilIdle()
        #expect(r.terminal.commands == ["/opt/homebrew/bin/brew install --cask docker"])
        #expect(!r.runner.argLines.contains("install --cask docker"))
        #expect(r.manager.queue.job(id)?.result == "Открыто в Terminal")
        r.manager.install("jq", kind: .formula)
        await r.manager.queue.waitUntilIdle()
        #expect(r.runner.argLines.contains("install --formula jq"))
    }

    @Test func terminalFailureIsShown() async {
        var s = BrewSettings()
        s.preferTerminalForCasks = true
        let r = Rig(settings: s)
        r.terminal.ok = false
        let id = r.manager.uninstall("docker", kind: .cask)!
        await r.manager.queue.waitUntilIdle()
        #expect(r.manager.queue.job(id)?.state == .failed("Не удалось открыть Terminal"))
    }

    @Test func uninstallRefusedBecauseOfDependents() async {
        let r = Rig()
        r.scriptHealthy()
        r.runner.on("uninstall --formula openssl@3", status: 1, lines: [], err: "Error: Refusing to uninstall /opt/homebrew/Cellar/openssl@3/3.4.0\nbecause it is required by curl, wget, which are currently installed.")
        let id = r.manager.uninstall("openssl@3", kind: .formula)!
        await finished(r)
        guard case .failed(let m)? = r.manager.queue.job(id)?.state else { Issue.record("expected failure"); return }
        #expect(m.contains("нужен другим"))
    }

    @Test func cancellingARunningUpgrade() async {
        let r = Rig()
        r.scriptHealthy()
        r.runner.on("upgrade --formula wget", lines: [ManagerLine(.out, "==> Upgrading wget")], hang: true)
        let id = r.manager.upgrade("wget", kind: .formula)!
        await mgrWait { r.manager.queue.job(id)?.log.isEmpty == false }
        r.manager.queue.cancel(id)
        await finished(r)
        #expect(r.manager.queue.job(id)?.state == .cancelled)
    }

    @Test func jobsRunOneAfterAnother() async {
        let r = Rig()
        r.scriptHealthy()
        r.runner.on("upgrade --formula a", out: "")
        r.runner.on("upgrade --formula b", out: "")
        let a = r.manager.upgrade("a", kind: .formula)!
        let b = r.manager.upgrade("b", kind: .formula)!
        #expect(r.manager.queue.job(a)?.state == .running)
        #expect(r.manager.queue.job(b)?.state == .queued)
        await finished(r)
        #expect(r.manager.queue.job(b)?.state == .succeeded)
    }

    @Test func invalidNamesNeverRunAndSetAFailure() {
        let r = Rig()
        #expect(r.manager.install("-rf", kind: .formula) == nil)
        #expect(r.manager.uninstall("a b", kind: .cask) == nil)
        #expect(r.manager.setPinned("x;y", pinned: true) == nil)
        #expect(r.runner.calls.isEmpty && r.manager.lastFailure != nil)
    }

    @Test func missingBrewRefusesToQueue() {
        let r = Rig(brewInstalled: false)
        #expect(r.manager.upgradeAll() == nil)
        #expect(r.manager.lastFailure?.kind == .missingBrew && r.manager.queue.jobs.isEmpty)
    }

    @Test func pinAndServiceCommands() async {
        let r = Rig()
        r.scriptHealthy()
        r.runner.on("pin wget", out: "")
        r.runner.on("services restart redis", out: "==> Successfully restarted `redis`")
        let p = r.manager.setPinned("wget", pinned: true)!
        let s = r.manager.service(.restart, name: "redis")!
        await finished(r)
        #expect(r.manager.queue.job(p)?.state == .succeeded && r.manager.queue.job(s)?.state == .succeeded)
        #expect(r.manager.queue.job(p)?.title == "Закрепление wget")
    }

    @Test func cleanupAfterUpgradeIsQueuedWhenEnabled() async {
        var s = BrewSettings()
        s.cleanupAfterUpgrade = true
        let r = Rig(settings: s)
        r.scriptHealthy()
        r.runner.on("upgrade", out: "")
        r.runner.on("cleanup", out: "")
        _ = r.manager.upgradeAll()
        await r.manager.queue.waitUntilIdle()
        await mgrWait { r.runner.argLines.contains("cleanup") }
        await r.manager.queue.waitUntilIdle()
        #expect(r.runner.argLines.contains("cleanup"))
        #expect(r.manager.queue.jobs.contains { $0.kind == "cleanup" })
    }

    @Test func outcomeMapping() {
        let t = BrewProgressTracker()
        #expect(BrewManager.outcome(for: ManagerResult(status: 0), tracker: t, doneText: "ok") == .success("ok"))
        #expect(BrewManager.outcome(for: ManagerResult(status: 130, cancelled: true), tracker: t, doneText: "ok") == .cancelled)
        if case .failure(let m) = BrewManager.outcome(for: ManagerResult(status: 1, stderr: "Error: whatever"), tracker: t, doneText: "ok") { #expect(m.contains("whatever")) } else { Issue.record("expected failure") }
        if case .failure = BrewManager.outcome(for: ManagerResult(status: 15, timedOut: true), tracker: t, doneText: "ok") {} else { Issue.record("timeout must fail") }
    }

    @Test func zeroExitWithAnErrorLineStillFails() {
        var t = BrewProgressTracker()
        t.feed("Error: wget: post-install step did not complete successfully")
        if case .failure(let m) = BrewManager.outcome(for: ManagerResult(status: 0), tracker: t, doneText: "ok") { #expect(!m.isEmpty) } else { Issue.record("expected failure") }
    }
}
