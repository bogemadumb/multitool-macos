import Foundation

// MARK: folders

func remoteMentioned(_ folder: String) -> Bool {
    if (folder as NSString).lastPathComponent.lowercased().contains("homeserver") { return true }
    for n in childNames(folder) where (n as NSString).pathExtension.lowercased() == "md" {
        let p = folder + "/" + n
        guard let fi = lstatInfo(p), !fi.isDir, !fi.isLink, fi.size < 262_144,
              let d = FileManager.default.contents(atPath: p) else { continue }
        if String(decoding: d, as: UTF8.self).lowercased().contains("homeserver") { return true }
    }
    return false
}

func analyzeFolder(path: String, env: AnalysisEnv, index: InUseIndex) -> (item: AnalysisItem, links: [(path: String, target: String)], remote: Bool) {
    let w = TreeWalker(cancel: env.cancelled)
    w.run(path)
    let name = (path as NSString).lastPathComponent
    let users = index.users(of: path)
    let refTs = w.newestOutside > 0 ? w.newestOutside : w.newest
    let age = refTs > 0 ? days(Date(timeIntervalSince1970: refTs), env.now) : (lstatInfo(path).map { days(Date(timeIntervalSince1970: $0.mtime), env.now) } ?? 0)
    let comp = w.buckets.filter { $0.value > 0 }
    let (reco, reason) = recommend(RecoInput(name: name, inUse: !users.isEmpty, hasDumps: !w.dumps.isEmpty, ageDays: age, bytes: w.bytes, buckets: comp))
    var item = AnalysisItem(id: "f:" + relToHome(path, env.home), kind: "folder", title: name, path: path, paths: [path])
    item.bytes = w.bytes
    item.logicalBytes = w.logical
    item.files = w.files
    item.ageDays = age
    item.reco = reco
    item.reason = reason
    item.inUseBy = users
    item.composition = comp
    item.heavy = w.childBytes.sorted { $0.value > $1.value }.prefix(3).map { HeavyEntry(name: $0.key, bytes: $0.value) }
    if !w.dumps.isEmpty { item.note = "дампы: " + w.dumps.prefix(3).joined(separator: ", ") }

    let regen = (comp["venv"] ?? 0) + (comp["nodemodules"] ?? 0) + (comp["pycache"] ?? 0)
    let offerKids = users.isEmpty && age >= 2 && !(w.bytes > 0 && Double(regen) >= Double(w.bytes) * 0.9)
    if offerKids {
        let big = w.specials.filter { $0.kind != "pycache" && $0.bytes >= 1_000_000 }.sorted { $0.bytes > $1.bytes }.prefix(6)
        for s in big where index.users(of: s.path).isEmpty && s.path != path {
            let rel = relToHome(s.path, path)
            var c = AnalysisItem(id: "c:" + relToHome(s.path, env.home), kind: "child", title: rel, path: s.path, paths: [s.path])
            c.bytes = s.bytes
            c.reco = .can
            c.reason = s.kind == "venv" ? "venv, пересоздаётся" : "node_modules, пересоздаётся"
            c.ageDays = age
            item.children.append(c)
        }
        let py = w.specials.filter { $0.kind == "pycache" }
        let pyBytes = py.reduce(Int64(0)) { $0 + $1.bytes }
        if pyBytes >= 1_000_000 {
            var c = AnalysisItem(id: "c:" + relToHome(path, env.home) + "#pycache", kind: "child", title: "__pycache__ ×\(py.count)", path: path, paths: py.map(\.path))
            c.bytes = pyBytes
            c.reco = .can
            c.reason = "кэш байткода, пересоздаётся"
            c.ageDays = age
            item.children.append(c)
        }
    }
    return (item, w.links, remoteMentioned(path))
}

// MARK: symlinks into folders

func collectShallowLinks(_ dir: String, depth: Int, maxDepth: Int, skip: Set<String>, into out: inout [(path: String, target: String)]) {
    guard depth <= maxDepth else { return }
    for n in childNames(dir) {
        if n == ".git" || n == "node_modules" || n == "Library" { continue }
        let p = dir + "/" + n
        guard let st = lstatInfo(p) else { continue }
        if st.isLink {
            if let d = try? FileManager.default.destinationOfSymbolicLink(atPath: p) { out.append((p, d)) }
        } else if st.isDir && !skip.contains(p) {
            collectShallowLinks(p, depth: depth + 1, maxDepth: maxDepth, skip: skip, into: &out)
        }
    }
}

func linksInto(_ folder: String, links: [(path: String, target: String)]) -> [String] {
    let cf = canonicalPath(folder)
    var out: [String] = []
    for l in links {
        if l.path.hasPrefix(folder + "/") { continue }
        let abs = l.target.hasPrefix("/") ? l.target : (l.path as NSString).deletingLastPathComponent + "/" + l.target
        let ct = canonicalPath(abs)
        if ct == cf || ct.hasPrefix(cf + "/") { out.append(l.path) }
    }
    return out
}

// MARK: Acer

func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func globEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        if "*?[]\\".contains(ch) { out.append("\\") }
        out.append(ch)
    }
    return out
}

func remoteArgs(name: String) -> [String] {
    ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "home-wsl",
     "find ~ /mnt/d/Archive -maxdepth 4 -type d -name \(shQuote(globEscape(name))) -exec du -sb {} + 2>/dev/null"]
}

func parseDu(_ out: String) -> [(bytes: Int64, path: String)] {
    out.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
        guard f.count == 2, let b = Int64(f[0]) else { return nil }
        return (b, String(f[1]))
    }
}

func remoteCheck(name: String, localBytes: Int64, env: AnalysisEnv) -> (RemoteState, String) {
    guard let r = env.remote.find(name: name) else { return (.none, "") }
    if r.status == 255 || r.status == 15 || r.status == -1 { return (.unreachable, "Домашний сервер не отвечает") }
    let found = parseDu(r.out)
    let lo = Double(localBytes) * 0.9, hi = Double(localBytes) * 1.1
    if let m = found.first(where: { localBytes == 0 || (Double($0.bytes) >= lo && Double($0.bytes) <= hi) }) {
        return (.copy, "\(m.path) · \(fmtBytes(m.bytes))")
    }
    if found.isEmpty { return (.noCopy, "на домашнем сервере такой папки нет") }
    return (.noCopy, "на домашнем сервере есть, но размер другой: " + found.prefix(2).map { fmtBytes($0.bytes) }.joined(separator: ", ") + " против \(fmtBytes(localBytes))")
}

// MARK: orphan VM disks

private func jsonNames(_ out: String) -> Set<String> {
    var names = Set<String>()
    for line in out.split(separator: "\n") {
        if let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let n = o["name"] as? String { names.insert(n) }
    }
    return names
}

func listLimaNames(env: AnalysisEnv, limaHome: String) -> Set<String> {
    guard let lima = env.clean.findTool("limactl"),
          let r = env.run("/usr/bin/env", ["LIMA_HOME=" + limaHome, lima, "list", "--json"], timeout: 15), r.status == 0 else { return [] }
    return jsonNames(r.out)
}

func scanOrphans(env: AnalysisEnv, index: InUseIndex) -> [AnalysisItem] {
    var items: [AnalysisItem] = []
    let home = env.home

    func diskItem(path: String, title: String, id: String, reco: Reco, reason: String) {
        let w = TreeWalker(cancel: env.cancelled)
        if let st = lstatInfo(path), !st.isDir {
            w.bytes = st.alloc
            w.files = 1
            w.logical = st.size
            w.newestAccess = max(st.atime, st.mtime)
        } else {
            w.run(path)
        }
        guard w.files > 0 else { return }
        var it = AnalysisItem(id: id, kind: "orphan", title: title, path: path, paths: [path])
        it.bytes = w.bytes
        it.logicalBytes = w.logical
        it.reco = reco
        it.reason = reason
        it.ageDays = w.newestAccess > 0 ? days(Date(timeIntervalSince1970: w.newestAccess), env.now) : 0
        it.note = "реально \(fmtBytes(w.bytes)), номинально \(fmtBytes(w.logical))"
        items.append(it)
    }

    for (tag, limaHome) in [("colima", home + "/.colima/_lima"), ("lima", home + "/.lima")] {
        let disks = limaHome + "/_disks"
        guard isRealDir(disks) else { continue }
        let alive = listLimaNames(env: env, limaHome: limaHome)
        for n in childNames(disks) {
            let p = disks + "/" + n
            guard isRealDir(p) else { continue }
            if isRealDir(limaHome + "/" + n) || alive.contains(n) { continue }
            if !index.users(of: p).isEmpty { continue }
            diskItem(path: p, title: "\(tag): диск «\(n)»", id: "o:" + relToHome(p, home), reco: .can, reason: "VM нет, диск остался")
        }
    }

    let vms = home + "/Library/Containers/com.docker.docker/Data/vms"
    if isRealDir(vms) {
        let installed = (env.appsDirs + [home + "/Applications"]).contains { exists($0 + "/Docker.app") }
        let running = env.clean.processBlob.contains("com.docker.docker")
        if !installed && !running {
            for n in childNames(vms) {
                let raw = vms + "/" + n + "/data/Docker.raw"
                guard exists(raw), index.users(of: raw).isEmpty else { continue }
                diskItem(path: raw, title: "Docker Desktop: Docker.raw", id: "o:" + relToHome(raw, home), reco: .can, reason: "Docker Desktop не установлен")
            }
        }
    }

    let utm = home + "/Library/Containers/com.utmapp.UTM/Data/Documents"
    if isRealDir(utm), !env.clean.processBlob.contains("UTM.app") {
        for n in childNames(utm) where n.hasSuffix(".utm") {
            let p = utm + "/" + n
            guard isRealDir(p) else { continue }
            let before = items.count
            diskItem(path: p, title: "UTM: " + String(n.dropLast(4)), id: "o:" + relToHome(p, home), reco: .check, reason: "")
            guard items.count > before else { continue }
            let age = items[items.count - 1].ageDays
            if age >= 90 {
                items[items.count - 1].reason = "не открывали \(age) дн."
            } else {
                items.removeLast()
            }
        }
    }
    return items.sorted { $0.bytes > $1.bytes }
}

// MARK: environments

func lastTouched(_ dir: String, cutoff: Double, limit: Int = 200_000) -> Double {
    var newest = lstatInfo(dir)?.mtime ?? 0
    var stack = [dir]
    var seen = 0
    while let d = stack.popLast() {
        if newest > cutoff { return newest }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
        if names.contains("pyvenv.cfg") { continue }
        for n in names {
            seen += 1
            if seen > limit { return Date().timeIntervalSince1970 }
            if n == "node_modules" || n == "__pycache__" { continue }
            let p = d + "/" + n
            guard let st = lstatInfo(p) else { continue }
            newest = max(newest, st.mtime)
            if newest > cutoff { return newest }
            if st.isDir && !st.isLink { stack.append(p) }
        }
    }
    return newest
}

func findEnvDirs(root: String, skip: Set<String>, cancel: @Sendable () -> Bool) -> [(path: String, kind: String)] {
    var out: [(String, String)] = []
    var stack: [(String, Int)] = [(root, 0)]
    while let (d, depth) = stack.popLast() {
        if cancel() { break }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
        for n in names {
            if n == ".git" || n == "Система" || n == ".claude" || n.hasSuffix(".app") || n.hasSuffix(".photoslibrary") { continue }
            if n.hasPrefix(".") && n != ".venv" { continue }
            let p = d + "/" + n
            guard let st = lstatInfo(p), st.isDir, !st.isLink else { continue }
            if skip.contains(canonicalPath(p)) { continue }
            if n == "node_modules" { out.append((p, "nodemodules")); continue }
            if n == "__pycache__" { out.append((p, "pycache")); continue }
            if exists(p + "/pyvenv.cfg") { out.append((p, "venv")); continue }
            if depth < 10 { stack.append((p, depth + 1)) }
        }
    }
    return out
}

func scanEnvs(env: AnalysisEnv, index: InUseIndex) -> [AnalysisItem] {
    let home = env.home
    let cutoff = env.now.timeIntervalSince1970 - Double(env.envMaxAgeDays) * 86400
    let skip = Set(env.rootsAbs.map { canonicalPath($0) })
    var items: [AnalysisItem] = []
    var pyGroups: [String: (paths: [String], bytes: Int64, root: String)] = [:]
    var ageCache: [String: Double] = [:]

    func touched(_ project: String) -> Double {
        if let v = ageCache[project] { return v }
        let v = lastTouched(project, cutoff: cutoff)
        ageCache[project] = v
        return v
    }

    for rootRel in env.envRoots {
        let root = home + "/" + rootRel
        guard isRealDir(root) else { continue }
        for (p, kind) in findEnvDirs(root: root, skip: skip, cancel: env.cancelled) {
            if env.cancelled() { return items }
            if isDeniedAnalysis(p, home: home, roots: env.rootsAbs) { continue }
            if kind == "pycache" {
                let comps = relToHome(p, root).split(separator: "/").dropLast()
                let key = root + "/" + comps.prefix(2).joined(separator: "/")
                let w = TreeWalker(cancel: env.cancelled)
                w.run(p)
                var g = pyGroups[key] ?? ([], 0, root)
                g.paths.append(p)
                g.bytes += w.bytes
                pyGroups[key] = g
                continue
            }
            let project = (p as NSString).deletingLastPathComponent
            if !index.users(of: project).isEmpty || !index.users(of: p).isEmpty { continue }
            let w = TreeWalker(cancel: env.cancelled)
            w.run(p)
            guard w.bytes >= 5_000_000 else { continue }
            let t = touched(project)
            guard t <= cutoff else { continue }
            var it = AnalysisItem(id: "e:" + relToHome(p, home), kind: "env", title: (project as NSString).lastPathComponent + "/" + (p as NSString).lastPathComponent,
                                  path: p, paths: [p])
            it.bytes = w.bytes
            it.ageDays = days(Date(timeIntervalSince1970: t), env.now)
            it.reco = .can
            it.reason = (kind == "venv" ? "venv" : "node_modules") + ", проект не трогали \(it.ageDays) дн."
            it.note = relToHome(project, home)
            items.append(it)
        }
    }
    for (key, g) in pyGroups where g.bytes >= 2_000_000 {
        if !index.users(of: key).isEmpty { continue }
        let t = touched(key)
        guard t <= cutoff else { continue }
        var it = AnalysisItem(id: "e:" + relToHome(key, home) + "#pycache", kind: "env", title: (key as NSString).lastPathComponent + "/__pycache__ ×\(g.paths.count)",
                              path: key, paths: g.paths)
        it.bytes = g.bytes
        it.ageDays = days(Date(timeIntervalSince1970: t), env.now)
        it.reco = .can
        it.reason = "кэш байткода, проект не трогали \(it.ageDays) дн."
        it.note = relToHome(key, home)
        items.append(it)
    }
    return items.sorted { $0.bytes > $1.bytes }
}

// MARK: HF models

let hfKnownUsers: [(prefix: String, user: String)] = [
    ("mlx-community/whisper", "mlx_whisper"),
    ("speechbrain/", "распознавание голосов"),
    ("pyannote/", "диаризация"),
]

func hfUser(_ repo: String) -> String? {
    let l = repo.lowercased()
    return hfKnownUsers.first { l.hasPrefix($0.prefix) }?.user
}

func hfLastAccess(_ modelDir: String) -> Double {
    var latest = 0.0
    let snaps = modelDir + "/snapshots"
    if let en = FileManager.default.enumerator(atPath: snaps) {
        for case let rel as String in en {
            if let st = statInfo(snaps + "/" + rel), !st.isDir { latest = max(latest, st.atime, st.mtime) }
        }
    }
    return latest
}

func scanModels(env: AnalysisEnv, index: InUseIndex) -> [AnalysisItem] {
    let dir = env.home + "/.cache/huggingface/hub"
    var items: [AnalysisItem] = []
    for n in childNames(dir) where n.hasPrefix("models--") {
        if env.cancelled() { break }
        let p = dir + "/" + n
        guard isRealDir(p) else { continue }
        let w = TreeWalker(cancel: env.cancelled)
        w.run(p)
        guard w.bytes >= 1_000_000 else { continue }
        let repo = n.dropFirst(8).replacingOccurrences(of: "--", with: "/")
        var last = hfLastAccess(p)
        if last == 0 { last = w.newestAccess }
        let age = last > 0 ? days(Date(timeIntervalSince1970: last), env.now) : 0
        var it = AnalysisItem(id: "m:" + n, kind: "model", title: repo, path: p, paths: [p])
        it.bytes = w.bytes
        it.ageDays = age
        it.files = w.files
        let users = index.users(of: repo)
        it.inUseBy = users
        if let u = hfUser(repo) { it.note = "использует: " + u }
        if !users.isEmpty {
            it.reco = .keep
            it.reason = "упомянута в службах"
        } else if age < 30 {
            it.reco = .keep
            it.reason = "использовали \(age) дн. назад"
        } else {
            it.reco = .check
            it.reason = "не открывали \(age) дн."
        }
        items.append(it)
    }
    return items.sorted { $0.bytes > $1.bytes }
}

// MARK: uv

public func lockBusy(_ path: String) -> Bool {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        flock(fd, LOCK_UN)
        return false
    }
    return errno == EWOULDBLOCK
}

public func uvPendingPath(_ env: AnalysisEnv) -> String { env.stateDir + "/uv-prune-pending" }

public func scanUv(env: AnalysisEnv) -> AnalysisItem? {
    guard env.clean.findTool("uv") != nil else { return nil }
    let cache = env.home + "/.cache/uv"
    guard isRealDir(cache) else { return nil }
    let w = TreeWalker(cancel: env.cancelled)
    w.run(cache)
    let busy = lockBusy(cache + "/.lock")
    let pending = exists(uvPendingPath(env))
    var it = AnalysisItem(id: "uv:prune", kind: "uv", title: "uv: кэш", path: "", paths: [])
    it.logicalBytes = w.bytes
    it.reco = busy ? .check : .can
    it.reason = busy ? "занято (MCP), повторю позже" : (pending ? "ждёт очереди, lock свободен" : "lock свободен")
    it.note = "кэш \(fmtBytes(w.bytes)), убирается только неиспользуемое"
    return it
}

// MARK: orchestrator

public func runAnalysis(env: AnalysisEnv) -> AnalysisResult {
    let t0 = Date()
    var res = AnalysisResult(stamp: t0.timeIntervalSince1970, roots: env.roots, remoteChecked: env.checkRemote && env.clean.allowExec)
    let home = env.home
    env.progress(0.01, "Читаю службы и процессы")
    let index = InUseIndex.build(env)

    env.progress(0.04, "Ищу брошенные диски")
    res.orphans = scanOrphans(env: env, index: index)

    var dirs: [String] = []
    for r in env.rootsAbs {
        for n in childNames(r) where !n.hasPrefix(".") && isRealDir(r + "/" + n) { dirs.append(r + "/" + n) }
    }
    var allLinks: [(path: String, target: String)] = []
    var mentions: [String] = []
    for (i, d) in dirs.enumerated() {
        if env.cancelled() { res.cancelled = true; return res }
        env.progress(0.08 + 0.5 * Double(i) / Double(max(dirs.count, 1)), "Папка \(i + 1) из \(dirs.count): \((d as NSString).lastPathComponent)")
        let r = analyzeFolder(path: d, env: env, index: index)
        res.folders.append(r.item)
        allLinks += r.links
        if r.remote { mentions.append(d) }
    }
    if env.cancelled() { res.cancelled = true; return res }

    env.progress(0.6, "Ищу симлинки внутрь папок")
    let skip = Set(env.rootsAbs)
    collectShallowLinks(home + "/Documents", depth: 1, maxDepth: 3, skip: skip, into: &allLinks)
    for r in env.rootsAbs { collectShallowLinks(r, depth: 1, maxDepth: 1, skip: [], into: &allLinks) }
    for extra in ["bin", ".local/bin", "Library/LaunchAgents"] { collectShallowLinks(home + "/" + extra, depth: 1, maxDepth: 1, skip: [], into: &allLinks) }
    for i in res.folders.indices { res.folders[i].symlinks = linksInto(res.folders[i].path, links: allLinks) }

    if res.remoteChecked && !mentions.isEmpty {
        var down = false
        for (i, d) in mentions.enumerated() {
            if env.cancelled() { res.cancelled = true; return res }
            env.progress(0.62 + 0.08 * Double(i) / Double(mentions.count), "Сверяю с домашним сервером: \((d as NSString).lastPathComponent)")
            guard let k = res.folders.firstIndex(where: { $0.path == d }) else { continue }
            if down { res.folders[k].remote = .unreachable; res.folders[k].remoteNote = "Домашний сервер не отвечает"; continue }
            let (st, note) = remoteCheck(name: (d as NSString).lastPathComponent, localBytes: res.folders[k].logicalBytes, env: env)
            res.folders[k].remote = st
            res.folders[k].remoteNote = note
            if st == .unreachable { down = true }
            if st == .copy && res.folders[k].reco == .check {
                res.folders[k].reco = .can
                res.folders[k].reason = "копия на домашнем сервере есть"
            }
        }
    } else if !mentions.isEmpty {
        res.notes.append("Сверка с домашним сервером пропущена")
    }
    res.folders.sort { $0.bytes > $1.bytes }

    env.progress(0.72, "Окружения по дому")
    res.envs = scanEnvs(env: env, index: index)
    if env.cancelled() { res.cancelled = true; return res }
    env.progress(0.9, "Модели HuggingFace")
    res.models = scanModels(env: env, index: index)
    env.progress(0.96, "Кэш uv")
    res.uv = scanUv(env: env)
    res.seconds = Date().timeIntervalSince(t0)
    env.progress(1, "Готово")
    return res
}

public func analysisJSON(_ r: AnalysisResult) -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? enc.encode(r)) ?? Data()
}
