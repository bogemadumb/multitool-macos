import Foundation
import IOKit
import IOKit.ps

public enum ToolRunner {
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}

enum Registry {
    static func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return d
    }

    static func services(_ className: String, _ body: (io_registry_entry_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var e = IOIteratorNext(it)
        while e != 0 {
            body(e)
            IOObjectRelease(e)
            e = IOIteratorNext(it)
        }
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

public enum CPUReader {
    public static func perCoreTicks() -> [CPUTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { i in
            let b = i * stride
            return CPUTicks(user: UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]),
                            system: UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                            idle: UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]),
                            nice: UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
        }
    }

    public static func totalTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }
}

public enum GPUReader {
    public static func read() -> GPUReading? {
        var best: GPUReading?
        Registry.services("IOAccelerator") { e in
            guard let perf = Registry.property(e, "PerformanceStatistics") as? [String: Any],
                  let u = RegistryParsers.gpuUtilization(perf) else { return }
            if best == nil || u > best!.utilization {
                let model = (Registry.property(e, "model") as? Data).flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
                best = GPUReading(utilization: u, name: model)
            }
        }
        return best
    }
}

public enum MemoryReader {
    public static func pages() -> VMPages? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        var p = VMPages(pageSize: UInt64(getpagesize()))
        p.free = UInt64(stats.free_count)
        p.active = UInt64(stats.active_count)
        p.inactive = UInt64(stats.inactive_count)
        p.speculative = UInt64(stats.speculative_count)
        p.wired = UInt64(stats.wire_count)
        p.compressor = UInt64(stats.compressor_page_count)
        p.purgeable = UInt64(stats.purgeable_count)
        p.fileBacked = UInt64(stats.external_page_count)
        p.anonymous = UInt64(stats.internal_page_count)
        return p
    }

    public static func swap() -> (used: UInt64, total: UInt64) {
        var s = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &s, &size, nil, 0) == 0 else { return (0, 0) }
        return (s.xsu_used, s.xsu_total)
    }

    public static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(level: Int(level))
    }

    public static func read() -> MemoryReading? {
        guard let p = pages() else { return nil }
        let sw = swap()
        return MemoryReading(composition: MemoryMath.compose(p, totalBytes: ProcessInfo.processInfo.physicalMemory),
                             swapUsedBytes: sw.used, swapTotalBytes: sw.total, pressure: pressure())
    }
}

public enum NetworkReader {
    private static let rtmIfInfo2: UInt8 = 0x12

    public static func counters() -> (inBytes: UInt64, outBytes: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return nil }
        var inB: UInt64 = 0
        var outB: UInt64 = 0
        var off = 0
        buf.withUnsafeBytes { raw in
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let size = Int(hdr.ifm_msglen)
                if size <= 0 { break }
                if hdr.ifm_type == rtmIfInfo2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m.ifm_index), &name) != nil {
                        let n = String(cString: name)
                        if n.hasPrefix("en") && (Int32(m.ifm_flags) & IFF_LOOPBACK) == 0 {
                            inB &+= m.ifm_data.ifi_ibytes
                            outB &+= m.ifm_data.ifi_obytes
                        }
                    }
                }
                off += size
            }
        }
        return (inB, outB)
    }

    public static func localIP() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: [(String, String)] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en"), (cur.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { found.append((name, ip)) }
            }
        }
        return found.sorted { $0.0 < $1.0 }.first?.1
    }
}

public enum DiskReader {
    public static func volumes() -> [DiskVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [DiskVolume] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let free = v.volumeAvailableCapacityForImportantUsage ?? 0
            out.append(DiskVolume(path: u.path, name: v.volumeName ?? u.lastPathComponent, totalBytes: UInt64(total),
                                  freeBytes: UInt64(max(free, 0)), isInternal: v.volumeIsInternal ?? true,
                                  isEjectable: v.volumeIsEjectable ?? false))
        }
        return out.sorted { $0.path == "/" ? true : ($1.path == "/" ? false : $0.path < $1.path) }
    }

    public static func ioTotals() -> (read: UInt64, write: UInt64) {
        var stats: [[String: Any]] = []
        Registry.services("IOBlockStorageDriver") { e in
            if let s = Registry.property(e, "Statistics") as? [String: Any] { stats.append(s) }
        }
        return RegistryParsers.diskIOTotals(stats)
    }

    public static func smart() -> SmartStatus {
        let text = ToolRunner.run("/usr/sbin/diskutil", ["info", "-plist", "/"], timeout: 10)
        return SystemParsers.smartStatus(plist: Data(text.utf8))
    }
}

public enum PowerReader {
    public static func read() -> BatteryReading {
        var sources: [[String: Any]] = []
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for s in list {
                if let d = IOPSGetPowerSourceDescription(blob, s)?.takeUnretainedValue() as? [String: Any] { sources.append(d) }
            }
        }
        var smart: [String: Any]?
        Registry.services("AppleSmartBattery") { e in if smart == nil { smart = Registry.properties(e) } }
        return RegistryParsers.compose(iops: sources, smart: smart)
    }
}


public enum USBReader {
    public static func devices() -> [USBDevice] {
        var all: [USBDevice] = []
        Registry.services("IOUSBHostDevice") { e in
            if let p = Registry.properties(e), let d = RegistryParsers.usbDevice(p) { all.append(d) }
        }
        return RegistryParsers.externalUSB(all)
    }
}

public enum IdleReader {
    public static func seconds() -> Double? {
        var result: Double?
        Registry.services("IOHIDSystem") { e in
            if result == nil, let v = Registry.property(e, "HIDIdleTime") as? NSNumber { result = v.doubleValue / 1e9 }
        }
        return result
    }
}

public struct ProcessDetail: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var parentName: String?
    public var path: String?
    public var startTime: Date?
    public var args: [String]
    public var bundlePath: String?

    public var uptime: TimeInterval? { startTime.map { max(Date().timeIntervalSince($0), 0) } }
}

public enum ProcessDetailReader {
    static func pidPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func procArgs(_ pid: Int32) -> (execPath: String, args: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return SystemParsers.procArgs(Array(buf.prefix(size)))
    }

    public static func read(pid: Int32) -> ProcessDetail? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        let path = pidPath(pid)
        let pa = procArgs(pid)
        let name = pa.map { SystemParsers.baseName($0.execPath) } ?? path.map(SystemParsers.baseName) ?? ""
        let ppid = Int32(info.pbi_ppid)
        var parent: String?
        if ppid > 0 { parent = pidPath(ppid).map(SystemParsers.baseName) ?? procArgs(ppid).map { SystemParsers.baseName($0.execPath) } }
        let start = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
        return ProcessDetail(pid: pid, ppid: ppid, name: name, parentName: parent, path: path, startTime: start,
                             args: pa?.args ?? [], bundlePath: path.flatMap(SystemParsers.bundlePath(forExecutable:)))
    }
}
