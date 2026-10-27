import Foundation
import MultitulCtlCore

func invokingUser() -> (uid: uid_t, home: String)? {
    guard let raw = ProcessInfo.processInfo.environment["SUDO_UID"], !raw.isEmpty,
          raw.allSatisfy({ $0 >= "0" && $0 <= "9" }), let v = UInt32(raw), v > 0,
          let pw = getpwuid(uid_t(v)), let dir = pw.pointee.pw_dir else { return nil }
    return (uid_t(v), String(cString: dir))
}

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data(("multitul-ctl: " + message + "\n").utf8))
    exit(code)
}

let user = invokingUser()
var allowed = ["/usr/local/etc/singbox/staged"]
if let user { allowed.insert(user.home + "/Library/Application Support/Multitul/staging", at: 0) }
let context = CtlContext(allowedApplyDirs: allowed)

let command: CtlCommand
do {
    command = try CtlParser.parse(Array(CommandLine.arguments.dropFirst()), context: context)
} catch {
    FileHandle.standardError.write(Data(("multitul-ctl: \(error)\n" + ctlUsage + "\n").utf8))
    exit(CtlExit.usage)
}

if command != .selftest, geteuid() != 0 { fail("must run as root (use sudo)", CtlExit.noPermission) }

let executor = CtlExecutor(context: context, trustedUid: user?.uid ?? 0, smcFactory: { SmcIOKitDevice(readOnly: false) })
exit(executor.execute(command))
