import Testing
import Foundation
@testable import MultitulCore

private let scratch = "Documents/Scratch"

private func aenv(_ f: CleanFixture) -> AnalysisEnv {
    var e = AnalysisEnv(clean: f.env(), stateDir: f.home + "/state")
    e.appsDirs = [f.root + "/Applications"]
    return e
}

private func plist(_ f: CleanFixture, _ label: String, args: [String]) {
    let body = args.map { "<string>\($0)</string>" }.joined()
    let xml = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>\(label)</string><key>ProgramArguments</key><array>\(body)</array></dict></plist>"
    let p = f.home + "/Library/LaunchAgents/" + label + ".plist"
    try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? xml.write(toFile: p, atomically: true, encoding: .utf8)
}

private func folder(_ r: AnalysisResult, _ name: String) -> AnalysisItem? { r.folders.first { $0.title == name } }

private struct FakeRemote: RemoteChecking {
    var answer: @Sendable (String) -> (status: Int32, out: String)?
    func find(name: String) -> (status: Int32, out: String)? { answer(name) }
}

@Suite struct RazborTests {
    @Test func orphanColimaDiskDetectedOnlyWithoutInstance() {
        let f = CleanFixture()
        f.file(".colima/_lima/_disks/colima/datadisk", bytes: 2_000_000)
        var r = runAnalysis(env: aenv(f))
        #expect(r.orphans.count == 1)
        #expect(r.orphans.first?.id == "o:.colima/_lima/_disks/colima")
        #expect(r.orphans.first?.reco == .can)
        #expect((r.orphans.first?.bytes ?? 0) >= 2_000_000)
        f.dir(".colima/_lima/colima")
        r = runAnalysis(env: aenv(f))
        #expect(r.orphans.isEmpty)
    }

    @Test func limactlListSavesALiveDisk() {
        let f = CleanFixture()
        f.dir(".colima/_lima/_disks/colima")
        #expect(runAnalysis(env: aenv(f)).orphans.isEmpty)
        f.file(".lima/_disks/vm1/datadisk", bytes: 2_000_000)
        f.tool("limactl")
        var e = aenv(f)
        e.clean.allowExec = true
        e.clean.exec = { _, args, _ in args.contains("list") ? (0, "{\"name\":\"vm1\"}\n") : (1, "") }
        #expect(runAnalysis(env: e).orphans.isEmpty)
        e.clean.exec = { _, _, _ in (0, "") }
        #expect(runAnalysis(env: e).orphans.map(\.title) == ["lima: диск «vm1»"])
    }

    @Test func orphanDockerRawAndUtm() {
        let f = CleanFixture()
        f.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 2_000_000)
        var e = aenv(f)
        #expect(runAnalysis(env: e).orphans.count == 1)
        f.dir("Applications/Docker.app")
        e.appsDirs = [f.home + "/Applications"]
        #expect(runAnalysis(env: e).orphans.isEmpty)
        f.file("Library/Containers/com.utmapp.UTM/Data/Documents/win.utm/data/disk.img", bytes: 2_000_000)
        f.ageTree("Library/Containers/com.utmapp.UTM/Data/Documents/win.utm", 100)
        var r = runAnalysis(env: e)
        #expect(r.orphans.map(\.title) == ["UTM: win"])
        #expect(r.orphans.first?.reco == .check)
        f.ageTree("Library/Containers/com.utmapp.UTM/Data/Documents/win.utm", 10)
        r = runAnalysis(env: e)
        #expect(r.orphans.isEmpty)
    }

    @Test func inUseByPlistTextWithPathBoundary() {
        let f = CleanFixture()
        f.file("\(scratch)/demo-project/run.py")
        f.file("\(scratch)/demo/other.py")
        f.file("\(scratch)/idle/x.py")
        plist(f, "dev.multitool.svc-a", args: ["/bin/sh", "-c", "cd \(f.home)/\(scratch)/demo-project && python run.py"])
        plist(f, "dev.multitool.svc-b", args: ["\(f.home)/\(scratch)/demo-project/run.py"])
        for n in ["demo-project", "demo", "idle"] { f.ageTree("\(scratch)/\(n)", 40) }
        let r = runAnalysis(env: aenv(f))
        let k = folder(r, "demo-project")
        #expect(k?.reco == .keep)
        #expect(k?.inUseBy.sorted() == ["dev.multitool.svc-a", "dev.multitool.svc-b"])
        #expect(folder(r, "demo")?.inUseBy.isEmpty == true)
        #expect(folder(r, "idle")?.reco == .check)
    }

    @Test func inUseByScriptReferencedFromPlistAndPsBlob() {
        let f = CleanFixture()
        f.file("\(scratch)/viaScript/a.py")
        f.file("\(scratch)/viaPs/a.py")
        let script = f.file("Documents/Система/run.sh")
        try? "#!/bin/sh\ncd \(f.home)/\(scratch)/viaScript\n".write(toFile: script, atomically: true, encoding: .utf8)
        plist(f, "dev.multitool.runner", args: [script])
        var e = aenv(f)
        e.clean.processBlob = "screen -dmS x python \(f.home)/\(scratch)/viaPs/a.py"
        let r = runAnalysis(env: e)
        #expect(folder(r, "viaScript")?.inUseBy == ["dev.multitool.runner"])
        #expect(folder(r, "viaPs")?.inUseBy == ["ps"])
    }

    @Test func symlinkIntoFolderWarns() {
        let f = CleanFixture()
        f.file("\(scratch)/target/data.bin", bytes: 4096)
        f.file("\(scratch)/other/x.txt")
        f.link("\(scratch)/other/lnk", to: f.home + "/\(scratch)/target/data.bin")
        f.link("\(scratch)/target/self", to: f.home + "/\(scratch)/target/data.bin")
        f.dir("Documents/Личное")
        f.link("Documents/Личное/shortcut", to: f.home + "/\(scratch)/other")
        let r = runAnalysis(env: aenv(f))
        #expect(folder(r, "target")?.symlinks == [f.home + "/\(scratch)/other/lnk"])
        #expect(folder(r, "other")?.symlinks == [f.home + "/Documents/Личное/shortcut"])
    }

    @Test func recommendationRulesOnFolders() {
        let f = CleanFixture()
        f.file("\(scratch)/dumpy/db.dump", bytes: 200_000)
        f.file("\(scratch)/fresh/a.txt")
        f.file("\(scratch)/kontakty-x/a.txt")
        f.file("\(scratch)/videos/clip.mp4", bytes: 3_000_000)
        f.file("\(scratch)/projekt/notes.txt", bytes: 3_000_000)
        f.file("\(scratch)/projekt/.venv/pyvenv.cfg", bytes: 100)
        f.file("\(scratch)/projekt/.venv/lib/x.so", bytes: 2_000_000)
        f.file("\(scratch)/justvenv/pyvenv.cfg", bytes: 100)
        f.file("\(scratch)/justvenv/lib/x.so", bytes: 2_000_000)
        f.file("\(scratch)/middle/a.txt", bytes: 5000)
        f.file("\(scratch)/smalldump/x.sql", bytes: 500)
        for n in ["dumpy", "kontakty-x", "videos", "justvenv", "smalldump"] { f.ageTree("\(scratch)/\(n)", 40) }
        f.ageTree("\(scratch)/projekt", 10)
        f.ageTree("\(scratch)/middle", 10)
        let r = runAnalysis(env: aenv(f))
        #expect(folder(r, "dumpy")?.reco == .keep)
        #expect(folder(r, "dumpy")?.reason.contains("дамп") == true)
        #expect(folder(r, "fresh")?.reco == .keep)
        #expect(folder(r, "kontakty-x")?.reco == .keep)
        #expect(folder(r, "videos")?.reco == .check)
        #expect(folder(r, "justvenv")?.reco == .can)
        #expect(folder(r, "smalldump")?.reco == .check)
        #expect(folder(r, "middle")?.reco == .keep)
        let p = folder(r, "projekt")
        #expect(p?.reco == .keep)
        #expect(p?.children.count == 1)
        #expect(p?.children.first?.reco == .can)
        #expect(p?.children.first?.title == ".venv")
        #expect(p?.heavy.first?.name == "notes.txt")
    }

    @Test func recommendPureFunction() {
        func rec(_ name: String = "x", inUse: Bool = false, dumps: Bool = false, age: Int = 30, bytes: Int64 = 1000, _ b: [String: Int64] = [:]) -> Reco {
            recommend(RecoInput(name: name, inUse: inUse, hasDumps: dumps, ageDays: age, bytes: bytes, buckets: b)).0
        }
        #expect(rec(inUse: true) == .keep)
        #expect(rec(dumps: true) == .keep)
        #expect(rec("contacts-list") == .keep)
        #expect(rec(age: 1) == .keep)
        #expect(rec(age: 30) == .check)
        #expect(rec(age: 30, ["venv": 950]) == .can)
        #expect(rec(age: 5, bytes: 1_000_000_000, ["video": 600_000_000]) == .check)
        #expect(rec(age: 5) == .keep)
        #expect(rec("renders-2", age: 5) == .check)
    }

    @Test func freshAndInUseFoldersOfferNoChildren() {
        let f = CleanFixture()
        f.file("\(scratch)/hot/notes.txt", bytes: 3_000_000)
        f.file("\(scratch)/hot/.venv/pyvenv.cfg", bytes: 100)
        f.file("\(scratch)/hot/.venv/lib/x.so", bytes: 2_000_000)
        f.file("\(scratch)/svc/notes.txt", bytes: 3_000_000)
        f.file("\(scratch)/svc/.venv/pyvenv.cfg", bytes: 100)
        f.file("\(scratch)/svc/.venv/lib/x.so", bytes: 2_000_000)
        f.ageTree("\(scratch)/svc", 30)
        plist(f, "dev.multitool.svc", args: ["\(f.home)/\(scratch)/svc/.venv/bin/python", "x"])
        let r = runAnalysis(env: aenv(f))
        #expect(folder(r, "hot")?.children.isEmpty == true)
        #expect(folder(r, "svc")?.children.isEmpty == true)
        #expect(folder(r, "svc")?.reco == .keep)
    }

    @Test func venvAndNodeModulesAgeFilter() {
        let f = CleanFixture()
        for (proj, days) in [("projOld", 20.0), ("projNew", 3.0), ("projBusy", 20.0), ("projEdge", 13.0)] {
            f.file("Documents/\(proj)/src.js", bytes: 100)
            f.file("Documents/\(proj)/node_modules/pkg/big.js", bytes: 6_000_000)
            f.ageTree("Documents/\(proj)", days)
        }
        f.file("Documents/Система/proj/node_modules/pkg/big.js", bytes: 6_000_000)
        f.ageTree("Documents/Система", 40)
        f.file("\(scratch)/inscratch/node_modules/pkg/big.js", bytes: 6_000_000)
        f.ageTree("\(scratch)/inscratch", 40)
        f.file("Code/app/.venv/pyvenv.cfg", bytes: 50)
        f.file("Code/app/.venv/lib/x.so", bytes: 6_000_000)
        f.file("Code/app/main.py", bytes: 100)
        f.ageTree("Code/app", 15)
        f.file("Code/small/.venv/pyvenv.cfg", bytes: 50)
        f.file("Code/small/.venv/lib/x.so", bytes: 100_000)
        f.ageTree("Code/small", 60)
        plist(f, "dev.multitool.busy", args: ["node", "\(f.home)/Documents/projBusy/server.js"])
        let r = runAnalysis(env: aenv(f))
        #expect(r.envs.map(\.title).sorted() == ["app/.venv", "projOld/node_modules"])
        #expect(r.envs.allSatisfy { $0.reco == .can && $0.ageDays >= 14 })
        #expect(r.envs.allSatisfy { !$0.path.contains("Система") && !$0.path.contains("Scratch") })
    }

    @Test func envAgeThresholdIsConfigurable() {
        let f = CleanFixture()
        f.file("Documents/projA/src.js", bytes: 100)
        f.file("Documents/projA/node_modules/pkg/big.js", bytes: 6_000_000)
        f.ageTree("Documents/projA", 10)
        var e = aenv(f)
        #expect(runAnalysis(env: e).envs.isEmpty)
        e.envMaxAgeDays = 7
        #expect(runAnalysis(env: e).envs.map(\.title) == ["projA/node_modules"])
    }

    @Test func huggingFaceDedupesBlobsAndMapsUsers() {
        let f = CleanFixture()
        let hub = ".cache/huggingface/hub"
        f.file("\(hub)/models--mlx-community--whisper-tiny/blobs/abc", bytes: 2_000_000)
        f.link("\(hub)/models--mlx-community--whisper-tiny/snapshots/r1/model.bin", to: "../../blobs/abc")
        f.link("\(hub)/models--mlx-community--whisper-tiny/snapshots/r2/model.bin", to: "../../blobs/abc")
        f.file("\(hub)/models--speechbrain--spkrec/blobs/d1", bytes: 1_500_000)
        f.link("\(hub)/models--speechbrain--spkrec/snapshots/r1/x.ckpt", to: "../../blobs/d1")
        f.file("\(hub)/models--pyannote--seg/blobs/e1", bytes: 1_200_000)
        f.link("\(hub)/models--pyannote--seg/snapshots/r1/x.bin", to: "../../blobs/e1")
        f.file("\(hub)/models--other--tiny/blobs/z", bytes: 100)
        f.ageTree("\(hub)/models--mlx-community--whisper-tiny/blobs", 90)
        f.ageTree("\(hub)/models--speechbrain--spkrec/blobs", 90)
        let r = runAnalysis(env: aenv(f))
        let m = Dictionary(uniqueKeysWithValues: r.models.map { ($0.title, $0) })
        #expect(m.count == 3)
        let w = m["mlx-community/whisper-tiny"]
        #expect((w?.bytes ?? 0) >= 2_000_000 && (w?.bytes ?? 0) < 2_100_000)
        #expect(w?.note == "использует: mlx_whisper")
        #expect(w?.reco == .check)
        #expect(m["pyannote/seg"]?.reco == .keep)
        #expect(hfUser("someone/else") == nil)
    }

    // MARK: uv

    @Test func uvLockBusyMarksPendingAndRetryClears() {
        let f = CleanFixture()
        let lockPath = f.file(".cache/uv/.lock", bytes: 0)
        f.tool("uv")
        let code = LockedBox<Int32>(2)
        var e = aenv(f)
        e.clean.allowExec = true
        e.clean.exec = { _, _, _ in (code.value, "") }
        let fd = open(lockPath, O_RDONLY)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        #expect(lockBusy(lockPath))
        #expect(scanUv(env: e)?.reco == .check)
        #expect(scanUv(env: e)?.reason == "занято (MCP), повторю позже")
        #expect(runUvPrune(env: e) == .busy)
        #expect(exists(uvPendingPath(e)))
        #expect(uvRetryPending(env: e) == .busy)
        #expect(exists(uvPendingPath(e)))
        flock(fd, LOCK_UN)
        close(fd)
        #expect(!lockBusy(lockPath))
        #expect(scanUv(env: e)?.reco == .can)
        #expect(runUvPrune(env: e) == .failed("код 2"))
        #expect(exists(uvPendingPath(e)))
        code.mutate { $0 = 0 }
        #expect(uvRetryPending(env: e) == .done)
        #expect(!exists(uvPendingPath(e)))
        #expect(uvRetryPending(env: e) == nil)
    }

    @Test func uvPruneIsInvokedWithLockTimeoutAndNeverWithoutExec() {
        let f = CleanFixture()
        f.file(".cache/uv/.lock", bytes: 0)
        f.tool("uv")
        var e = aenv(f)
        #expect(runUvPrune(env: e) == .failed("запуск запрещён"))
        e.clean.allowExec = true
        e.clean.exec = { tool, args, _ in f.execLog.mutate { $0.append(([tool] + args).joined(separator: " ")) }; return (0, "") }
        #expect(runUvPrune(env: e) == .done)
        #expect(f.execLog.value == ["/usr/bin/env UV_LOCK_TIMEOUT=5 \(f.root)/bin/uv cache prune"])
        #expect(CleanFixture().env().findTool("uv") == nil)
    }

    @Test func uvIsNeverPartOfThePlanAsAPathAndNeverInDiskCleanup() {
        let f = CleanFixture()
        f.file(".cache/uv/.lock", bytes: 0)
        f.file(".cache/uv/archive-v0/x", bytes: 5000)
        f.tool("uv")
        let r = runAnalysis(env: aenv(f))
        let uv = r.uv
        #expect(uv?.kind == "uv" && uv?.paths.isEmpty == true)
        let plan = planAnalysisClean(r, picked: ["uv:prune"], env: aenv(f), index: InUseIndex())
        #expect(plan.ops.map(\.op) == [.uv])
        #expect(isDeniedAnalysis(f.home + "/.cache/uv/archive-v0", home: f.home, roots: [f.home + "/" + scratch]))
    }

    // MARK: trash then verify

    private func junkFixture(_ f: CleanFixture) -> (AnalysisResult, AnalysisEnv) {
        f.file("\(scratch)/junk/a.bin", bytes: 3_000_000)
        f.ageTree("\(scratch)/junk", 40)
        let e = aenv(f)
        return (runAnalysis(env: e), e)
    }

    @Test func trashThenVerifyAbortsWhenServiceDied() {
        let f = CleanFixture()
        f.file(".Trash/unrelated.txt")
        var (r, e) = junkFixture(f)
        let junk = folder(r, "junk")!
        #expect(junk.reco == .check)
        let calls = LockedBox<Int>(0)
        e.clean.launchctlList = {
            var n = 0
            calls.mutate { $0 += 1; n = $0 }
            return n == 1 ? "PID\tStatus\tLabel\n111\t0\tdev.multitool.alive\n222\t0\tdev.multitool.victim\n-\t0\tcom.apple.x\n"
                          : "PID\tStatus\tLabel\n111\t0\tdev.multitool.alive\n-\t78\tdev.multitool.victim\n"
        }
        let plan = planAnalysisClean(r, picked: [junk.id], env: e, index: InUseIndex())
        #expect(plan.ops.count == 1)
        let byId = Dictionary(uniqueKeysWithValues: r.allItems.map { ($0.id, $0) })
        let rep = executeAnalysisClean(plan, items: byId, env: e)
        #expect(rep.aborted)
        #expect(rep.died == ["dev.multitool.victim"])
        #expect(rep.emptiedCount == 0)
        #expect(rep.trashedCount == 1)
        #expect(!f.exists("\(scratch)/junk"))
        #expect(f.exists(".Trash/unrelated.txt"))
        #expect(rep.inTrash.count == 1 && FileManager.default.fileExists(atPath: rep.inTrash[0]))
        #expect(analysisReportLines(rep).contains { $0.hasPrefix("СТОП") })
    }

    @Test func trashThenVerifyDeletesOnlyOwnItemsWhenAllAlive() {
        let f = CleanFixture()
        f.file(".Trash/unrelated.txt")
        f.file(".Trash/folder/also.txt")
        var (r, e) = junkFixture(f)
        let junk = folder(r, "junk")!
        e.clean.launchctlList = { "PID\tStatus\tLabel\n111\t0\tdev.multitool.alive\n-\t0\tdev.multitool.oneshot\n" }
        let plan = planAnalysisClean(r, picked: [junk.id], env: e, index: InUseIndex())
        let byId = Dictionary(uniqueKeysWithValues: r.allItems.map { ($0.id, $0) })
        let rep = executeAnalysisClean(plan, items: byId, env: e)
        #expect(!rep.aborted)
        #expect(rep.died.isEmpty)
        #expect(rep.emptiedCount == 1)
        #expect(rep.doneIds == [junk.id])
        #expect(rep.freedBytes == junk.bytes)
        #expect(!f.exists("\(scratch)/junk"))
        #expect(f.exists(".Trash/unrelated.txt"))
        #expect(f.exists(".Trash/folder/also.txt"))
        #expect(!FileManager.default.fileExists(atPath: rep.inTrash[0]))
    }

    @Test func finishedOneShotIsNotADeadService() {
        let before = parseLaunchctl("1\t0\tdev.multitool.a\n2\t0\tdev.multitool.b\n3\t0\tdev.multitool.c\n")
        let after = parseLaunchctl("1\t0\tdev.multitool.a\n-\t0\tdev.multitool.b\n")
        #expect(diedServices(before: before, after: after) == ["dev.multitool.c"])
        let after2 = parseLaunchctl("1\t0\tdev.multitool.a\n-\t1\tdev.multitool.b\n9\t0\tdev.multitool.c\n")
        #expect(diedServices(before: before, after: after2) == ["dev.multitool.b"])
    }

    @Test func planRevalidatesInUseDedupesAndRefusesKeepAndDenied() {
        let f = CleanFixture()
        f.file("\(scratch)/proj/notes.txt", bytes: 3_000_000)
        f.file("\(scratch)/proj/.venv/pyvenv.cfg", bytes: 100)
        f.file("\(scratch)/proj/.venv/lib/x.so", bytes: 2_000_000)
        f.ageTree("\(scratch)/proj", 30)
        f.file("\(scratch)/hot/a.txt")
        var r = runAnalysis(env: aenv(f))
        let proj = folder(r, "proj")!
        let kid = proj.children[0]
        var e = aenv(f)
        var plan = planAnalysisClean(r, picked: [proj.id, kid.id], env: e, index: InUseIndex())
        #expect(plan.ops.count == 1)
        #expect(plan.ops.first?.op == .trash(proj.path))
        plan = planAnalysisClean(r, picked: [kid.id, folder(r, "hot")!.id, "nope"], env: e, index: InUseIndex())
        #expect(plan.ops.map(\.op) == [.trash(kid.path)])
        #expect(plan.skipped.count == 2)
        let busy = InUseIndex(sources: [InUseSource(name: "dev.multitool.late", text: norm(f.home + "/\(scratch)/proj/run.py"))])
        plan = planAnalysisClean(r, picked: [proj.id, kid.id], env: e, index: busy)
        #expect(plan.ops.isEmpty)
        #expect(plan.skipped.count == 2)
        var forged = proj
        forged.id = "f:forged"
        forged.paths = [f.home + "/Documents/Система", f.home + "/.cache/uv", f.home + "/.claude", f.home + "/Documents/Универ/x", "/etc"]
        r.folders.append(forged)
        e = aenv(f)
        plan = planAnalysisClean(r, picked: ["f:forged"], env: e, index: InUseIndex())
        #expect(plan.ops.isEmpty)
        #expect(plan.denied.count == 5)
    }

    @Test func analysisDenylist() {
        let f = CleanFixture()
        let h = f.home
        let roots = [h + "/" + scratch]
        for rel in ["Documents/Система/x", ".cache/uv/archive-v0", ".claude/projects", "Documents/Универ/a.docx", "Documents/Scratch",
                    "Documents", "Library/Mail/x", ".ssh/id", "Downloads/x"] {
            #expect(isDeniedAnalysis(h + "/" + rel, home: h, roots: roots), "must deny \(rel)")
        }
        f.dir("Documents/Личное/proj/node_modules")
        f.file("Documents/Личное/proj/.venv/pyvenv.cfg")
        f.dir("Documents/Личное/proj/src")
        for rel in ["Documents/Scratch/a", "Documents/Scratch/a/b/c", ".colima/_lima/_disks/colima", ".cache/huggingface/hub/models--a--b",
                    "Documents/Личное/proj/node_modules", "Documents/Личное/proj/.venv"] {
            #expect(!isDeniedAnalysis(h + "/" + rel, home: h, roots: roots), "must allow \(rel)")
        }
        #expect(isDeniedAnalysis(h + "/Documents/Личное/proj/src", home: h, roots: roots))
        f.link("Documents/Scratch/sneaky", to: h + "/Documents/Система")
        f.dir("Documents/Система")
        #expect(isDeniedAnalysis(h + "/Documents/Scratch/sneaky", home: h, roots: roots))
    }

    // MARK: Acer

    @Test func remoteArgsAreSafeArgvAndQuotedName() throws {
        for name in ["проект", "plain", "it's; rm -rf ~ $(whoami) `id`", "a b*c[1]?"] {
            let a = remoteArgs(name: name)
            #expect(Array(a.prefix(5)) == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "home-wsl"])
            #expect(a.count == 6)
            let q = shQuote(globEscape(name))
            #expect(a[5].contains("-name \(q) -exec du -sb {} +"))
        }
    }

    @Test func remoteCheckSizeWindowAndUnreachableThroughTheRunnerAbstraction() {
        let seen = LockedBox<[String]>([])
        let answer = LockedBox<(Int32, String)?>((0, "1000000\t/home/x/archive/проект\n5000000\t/mnt/d/other/проект\n"))
        let f = CleanFixture()
        var e = aenv(f)
        e.remote = SshRemoteChecker(exec: { tool, args, _ in
            seen.mutate { $0 = [tool] + args }
            return answer.value ?? (0, "")
        }, allowed: true)
        var r = remoteCheck(name: "проект", localBytes: 1_050_000, env: e)
        #expect(r.0 == .copy)
        #expect(seen.value.first == "/usr/bin/ssh")
        #expect(seen.value.last?.contains("-name 'проект'") == true)
        r = remoteCheck(name: "проект", localBytes: 1_200_000, env: e)
        #expect(r.0 == .noCopy)
        #expect(r.1.contains("размер другой"))
        answer.mutate { $0 = (0, "") }
        #expect(remoteCheck(name: "x", localBytes: 10, env: e).0 == .noCopy)
        answer.mutate { $0 = (255, "") }
        #expect(remoteCheck(name: "x", localBytes: 10, env: e).0 == .unreachable)
        e.remote = SshRemoteChecker(exec: { _, _, _ in (0, "never") }, allowed: false)
        #expect(remoteCheck(name: "x", localBytes: 10, env: e).0 == RemoteState.none)
        #expect(f.execLog.value.isEmpty)
    }

    @Test func remoteMentionTriggersCheckAndUpgradesToCan() {
        let f = CleanFixture()
        f.file("\(scratch)/archived/data.bin", bytes: 3_000_000)
        try? "Архив на homeserver лежит в D:".write(toFile: f.home + "/\(scratch)/archived/README.md", atomically: true, encoding: .utf8)
        f.file("\(scratch)/nomention/data.bin", bytes: 3_000_000)
        f.file("\(scratch)/mismatch/data.bin", bytes: 3_000_000)
        try? "лежит на homeserver".write(toFile: f.home + "/\(scratch)/mismatch/notes.md", atomically: true, encoding: .utf8)
        for n in ["archived", "nomention", "mismatch"] { f.ageTree("\(scratch)/\(n)", 40) }
        var e = aenv(f)
        e.clean.allowExec = true
        let asked = LockedBox<[String]>([])
        e.remote = FakeRemote { name in
            asked.mutate { $0.append(name) }
            return name == "archived" ? (0, "3000010\t/mnt/d/Archive/scratch/archived\n") : (0, "100\t/mnt/d/Archive/mismatch\n")
        }
        let r = runAnalysis(env: e)
        #expect(asked.value.sorted() == ["archived", "mismatch"])
        let a = folder(r, "archived")!
        #expect(a.remote == .copy && a.reco == .can)
        #expect(folder(r, "nomention")?.remote == RemoteState.none)
        #expect(folder(r, "nomention")?.reco == .check)
        let m = folder(r, "mismatch")!
        #expect(m.remote == .noCopy && m.reco == .check)
        var noRemote = e
        noRemote.checkRemote = false
        #expect(folder(runAnalysis(env: noRemote), "archived")?.reco == .check)
    }

    @Test func unreachableRemoteIsAskedOnlyOnce() {
        let f = CleanFixture()
        for n in ["a", "b", "c"] {
            f.file("\(scratch)/\(n)/data.bin", bytes: 1_000_000)
            try? "homeserver".write(toFile: f.home + "/\(scratch)/\(n)/notes.md", atomically: true, encoding: .utf8)
            f.ageTree("\(scratch)/\(n)", 40)
        }
        var e = aenv(f)
        e.clean.allowExec = true
        let asked = LockedBox(0)
        e.remote = FakeRemote { _ in asked.mutate { $0 += 1 }; return (255, "") }
        let r = runAnalysis(env: e)
        #expect(asked.value == 1)
        #expect(r.folders.allSatisfy { $0.remote == .unreachable })
    }

    @Test func analysisJsonRoundTripAndCancel() {
        let f = CleanFixture()
        f.file("\(scratch)/a/x.txt")
        let r = runAnalysis(env: aenv(f))
        let back = try? JSONDecoder().decode(AnalysisResult.self, from: analysisJSON(r))
        #expect(back?.folders.map(\.id) == r.folders.map(\.id))
        var e = aenv(f)
        e.cancelled = { true }
        #expect(runAnalysis(env: e).cancelled)
    }

    @Test func walkerDoesNotFollowSymlinksAndSplitsBuckets() {
        let f = CleanFixture()
        f.file("outside/big.bin", bytes: 5_000_000)
        f.file("\(scratch)/w/clip.mov", bytes: 100_000)
        f.file("\(scratch)/w/node_modules/p/i.js", bytes: 50_000)
        f.file("\(scratch)/w/prof/Default/Preferences", bytes: 1000)
        f.file("\(scratch)/w/prof/Default/Cache/c", bytes: 60_000)
        f.link("\(scratch)/w/lnk", to: f.home + "/outside")
        let w = TreeWalker()
        w.run(f.home + "/\(scratch)/w")
        #expect(w.bytes < 1_000_000)
        #expect((w.buckets["video"] ?? 0) >= 100_000)
        #expect((w.buckets["nodemodules"] ?? 0) >= 50_000)
        #expect((w.buckets["browser"] ?? 0) >= 60_000)
        #expect(w.links.count == 1)
        #expect(w.specials.count == 1 && w.specials[0].kind == "nodemodules")
    }
}
