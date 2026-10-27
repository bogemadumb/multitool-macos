import AppKit
import ApplicationServices
import MultitulCore

let args = CommandLine.arguments

if args.contains("--check-ax") {
    let trusted = AXIsProcessTrusted()
    let line = "ax_trusted=\(trusted) pid=\(getpid()) bin=\(args[0])"
    print(line)
    Log.write("check-ax " + line)
    exit(trusted ? 0 : 1)
}

if let i = args.firstIndex(of: "--migrate-vpn") {
    exit(VpnMigrationCLI.run(arguments: Array(args[(i + 1)...])) { print($0) })
}

if let i = args.firstIndex(of: "--vpn-journal-clean") {
    exit(VpnJournalCleanCLI.run(arguments: Array(args[(i + 1)...])) { print($0) })
}

if let i = args.firstIndex(of: "--migrate-storozh") {
    exit(StorozhMigrationCLI.run(arguments: Array(args[(i + 1)...])) { print($0) })
}

if CleanCLI.handles(args) {
    exit(CleanCLI.run(arguments: args, out: { print($0) }, err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }))
}

if WallpaperCLI.handles(args) {
    exit(WallpaperCLI.run(arguments: args, out: { print($0) }, err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }))
}

if MonitorCLI.handles(args) {
    exit(MonitorCLI.run(arguments: args, out: { print($0) }, err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }))
}

if GameModeCLI.handles(args) {
    exit(GameModeCLI.run(arguments: args, out: { print($0) }, err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }))
}

if args.contains("--agent") {
    AgentRunner.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
