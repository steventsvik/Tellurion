#if os(macOS)
import Darwin
import Foundation

/// Reads processes and their listening sockets straight from the kernel (libproc), the
/// way `lsof` does, without starting `lsof` or `ps`. A full scan of the user's processes
/// takes a couple of milliseconds, so the sidebar can keep its port list current cheaply.
/// Only this user's processes are visible, which is all a dev server can be.
enum ProcessProbe {
    struct Listener: Hashable {
        let pid: Int32
        let port: Int
    }

    struct BSDInfo {
        let pid: Int32
        let ppid: Int32
        /// The executable's short name ("node", "ruby").
        let name: String
        let start: Date
    }

    /// Every TCP port the user's processes are listening on.
    static func listeners() -> [Listener] {
        let uid = getuid()
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.size + 64)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let me = getpid()
        var result: [Listener] = []
        var seen: Set<Listener> = []
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        for pid in pids.prefix(Int(filled) / MemoryLayout<Int32>.size) where pid > 0 && pid != me {
            var bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
            guard bytes > 0 else { continue }
            // A full buffer may mean more descriptors than it holds: grow and read again.
            while Int(bytes) / fdSize >= fds.count, fds.count < 65_536 {
                fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fds.count * 4)
                bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
            }
            for fd in fds.prefix(Int(bytes) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                      info.psi.soi_kind == SOCKINFO_TCP else { continue }
                let tcp = info.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
                // IPv4 and IPv6 sockets on the same port count once.
                let listener = Listener(pid: pid, port: port)
                if seen.insert(listener).inserted { result.append(listener) }
            }
        }
        return result
    }

    static func bsdInfo(_ pid: Int32) -> BSDInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafePointer(to: info.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) * 2) { String(cString: $0) }
        }
        let comm = withUnsafePointer(to: info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
        }
        return BSDInfo(pid: pid, ppid: Int32(info.pbi_ppid), name: name.isEmpty ? comm : name,
                       start: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)))
    }

    /// The process's working directory.
    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Resident memory, in bytes.
    static func memory(_ pid: Int32) -> Int64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return Int64(info.pti_resident_size)
    }

    /// The full command line, from the kernel's copy of the process's arguments.
    static func commandLine(_ pid: Int32) -> String? {
        guard let arguments = procArgs(pid)?.arguments, !arguments.isEmpty else { return nil }
        return arguments.joined(separator: " ")
    }

    /// One variable of the environment the process started with.
    static func environment(_ pid: Int32, _ name: String) -> String? {
        let prefix = name + "="
        return procArgs(pid)?.environment.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// The kernel's copy of the process's arguments and environment (`NAME=value` strings).
    static func procArgs(_ pid: Int32) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // Layout: argc, the executable path, padding NULs, argc NUL-terminated arguments, then
        // the environment's strings up to an empty one.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        func next() -> String {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(bytes: buffer[start..<index], encoding: .utf8) ?? ""
        }
        var arguments: [String] = []
        while arguments.count < argc && index < size { arguments.append(next()) }
        var environment: [String] = []
        while index < size && buffer[index] != 0 { environment.append(next()) }
        return (arguments, environment)
    }

    /// The pids of every process this user runs.
    static func userPIDs() -> [Int32] {
        let uid = getuid()
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.size + 64)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return pids.prefix(max(0, Int(filled)) / MemoryLayout<Int32>.size).filter { $0 > 0 }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
#endif
