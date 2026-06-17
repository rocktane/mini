import Darwin
import Foundation

/// Minimal Unix-domain-socket JSON-line server.
/// One request per client connection, writes one response, closes.
@MainActor
final class SocketServer {
    private var listenFd: Int32 = -1
    private var source: DispatchSourceRead?
    let path: String
    var onRequest: (([String: Any]) -> [String: Any])?

    init(path: String) {
        self.path = path
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "MiniSocket", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NSError(domain: "MiniSocket", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "socket path too long"])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { cptr in
                for (i, b) in bytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[bytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, size)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "MiniSocket", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed: \(String(cString: strerror(errno)))"])
        }
        // Owner-only access; only this user should reach the socket.
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            close(fd)
            throw NSError(domain: "MiniSocket", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(listenFd, nil, nil)
        guard client >= 0 else { return }
        // Handle on a background queue; only invoke onRequest on main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handle(client: client)
        }
    }

    nonisolated private func handle(client fd: Int32) {
        defer { close(fd) }
        guard let line = Self.readLine(fd: fd) else { return }
        guard let dict = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            _ = Self.writeLine(fd: fd, json: ["status": "error", "error": "invalid json"])
            return
        }
        var response: [String: Any] = ["status": "error", "error": "no handler"]
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
            if let handler = self?.onRequest {
                response = handler(dict)
            }
            sema.signal()
        }
        sema.wait()
        _ = Self.writeLine(fd: fd, json: response)
    }

    nonisolated private static func readLine(fd: Int32) -> String? {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return buf.isEmpty ? nil : String(bytes: buf, encoding: .utf8) }
            for i in 0..<n {
                if chunk[i] == 0x0A {
                    return String(bytes: buf, encoding: .utf8)
                }
                buf.append(chunk[i])
            }
            if buf.count > 1_000_000 { return nil }
        }
    }

    nonisolated private static func writeLine(fd: Int32, json: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: json) else { return false }
        data.append(0x0A)
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { buf in
                write(fd, buf.baseAddress, buf.count)
            }
            if n <= 0 { return false }
            remaining.removeFirst(n)
        }
        return true
    }
}
