import Foundation

/// Unix-domain socket reading newline-delimited JSON. Each line is answered with `ok` or `error: …`.
/// The socket file is chmod 600, so only the current user can talk to it.
final class SocketServer {
    let path: String
    private let handler: (Data) -> String   // called on `queue`
    private let queue = DispatchQueue(label: "local.polso.socket")
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    private final class Client {
        let source: DispatchSourceRead
        var buffer = Data()
        init(_ s: DispatchSourceRead) { source = s }
    }

    init(path: String, handler: @escaping (Data) -> String) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        guard var addr = Self.address(path) else { close(fd); throw MessageError("socket path too long: \(path)") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let e = posixError("bind"); close(fd); throw e }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let e = posixError("listen"); close(fd); throw e }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll(fd) }
        src.setCancelHandler { close(fd) }
        src.resume()
        acceptSource = src
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            clients.values.forEach { $0.source.cancel() }
            clients = [:]
        }
        unlink(path)
    }

    private func acceptAll(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            clients[fd] = Client(src)
            src.setEventHandler { [weak self] in self?.read(fd) }
            src.setCancelHandler { close(fd) }
            src.resume()
        }
    }

    private func read(_ fd: Int32) {
        guard let c = clients[fd] else { return }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 {
            c.buffer.append(contentsOf: buf[0..<n])
            while let i = c.buffer.firstIndex(of: 0x0A) {
                let line = Data(c.buffer[c.buffer.startIndex..<i])
                c.buffer = Data(c.buffer[(i + 1)...])
                respond(fd, line)
            }
            if c.buffer.count > 1 << 20 {
                write(fd, "error: line longer than 1MB\n")
                drop(fd)
            }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            if !c.buffer.isEmpty { respond(fd, c.buffer) }   // last line without a trailing newline
            drop(fd)
        }
    }

    private func respond(_ fd: Int32, _ line: Data) {
        guard line.contains(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0D) }) else { return }
        write(fd, handler(line) + "\n")
    }

    private func drop(_ fd: Int32) {
        clients[fd]?.source.cancel()
        clients[fd] = nil
    }

    private func write(_ fd: Int32, _ s: String) {
        _ = s.utf8CString.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count - 1) }
    }

    // MARK: client side

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Sends one line and returns the reply, or nil when nobody is listening.
    static func send(_ line: String, to path: String) -> String? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        let msg = line + "\n"
        _ = msg.utf8CString.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count - 1) }
        shutdown(fd, SHUT_WR)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, buf.count)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .newlines) : ""
    }
}

private func posixError(_ what: String) -> Error {
    MessageError("\(what): \(String(cString: strerror(errno)))")
}
