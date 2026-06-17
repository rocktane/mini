import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Constants

let bundleId = "com.rocktane.Mini"

func socketPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Application Support/Mini/mini.sock"
}

// MARK: - Helpers

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("mini: \(message)\n".utf8))
    exit(code)
}

func ttySize() -> (cols: Int, rows: Int) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
        return (Int(ws.ws_col), Int(ws.ws_row))
    }
    return (120, 30)
}

func connectToSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        close(fd)
        return nil
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cptr in
            for (i, b) in pathBytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
            cptr[pathBytes.count] = 0
        }
    }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, size)
        }
    }
    if result < 0 {
        close(fd)
        return nil
    }
    return fd
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var remaining = data
    while !remaining.isEmpty {
        let n = remaining.withUnsafeBytes { buf -> Int in
            write(fd, buf.baseAddress, buf.count)
        }
        if n <= 0 { return false }
        remaining.removeFirst(n)
    }
    return true
}

func readLine(_ fd: Int32, timeoutSec: Int = 5) -> String? {
    var buf = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 1)
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
    while Date() < deadline {
        let n = read(fd, &chunk, 1)
        if n == 1 {
            if chunk[0] == 0x0A { return String(bytes: buf, encoding: .utf8) }
            buf.append(chunk[0])
        } else if n == 0 {
            return String(bytes: buf, encoding: .utf8)
        } else {
            return nil
        }
    }
    return nil
}

func launchApp() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-g", "-b", bundleId]
    do { try task.run() } catch { /* ignore */ }
    task.waitUntilExit()
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    die("usage: mini <command> [args...]", code: 64)
}
let userArgv = Array(args.dropFirst())

let cwd = FileManager.default.currentDirectoryPath
let env = ProcessInfo.processInfo.environment
let (cols, rows) = ttySize()

let payload: [String: Any] = [
    "cwd": cwd,
    "env": env,
    "argv": userArgv,
    "cols": cols,
    "rows": rows,
]
guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
    die("failed to encode request")
}

var requestData = json
requestData.append(0x0A)

let path = socketPath()
var fd = connectToSocket(path)

if fd == nil {
    launchApp()
    let deadline = Date().addingTimeInterval(5.0)
    while Date() < deadline {
        usleep(150_000)
        if let f = connectToSocket(path) { fd = f; break }
    }
}

guard let sock = fd else {
    die("could not reach Mini.app — is it installed? Try: open -b \(bundleId)")
}

if !writeAll(sock, requestData) {
    close(sock)
    die("failed to send request")
}

guard let line = readLine(sock) else {
    close(sock)
    die("no response from Mini.app")
}
close(sock)

if let resp = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
   let status = resp["status"] as? String {
    if status == "started" {
        if let id = resp["jobId"] as? String {
            print("started \(id)")
        }
        exit(0)
    } else {
        let msg = (resp["error"] as? String) ?? "unknown error"
        die(msg)
    }
} else {
    die("invalid response: \(line)")
}
