import Foundation

/// A tiny unix-socket server. Claude Code hooks connect, write one JSON
/// payload, and hang up; we hand the complete payload to the handler.
/// Plain BSD sockets + DispatchSource — no dependencies.
final class HookSocketServer {
    /// Hook payloads are a few hundred bytes; anything this big is junk.
    private static let maxPayloadSize = 1 << 20
    /// A client that stalls longer than this gets dropped, so one stuck
    /// hook can never hold up the ones behind it.
    private static let readTimeout = timeval(tv_sec: 1, tv_usec: 0)

    private let path: String
    private let handler: (Data) -> Void
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "claudebar.socket.accept")
    /// Serial, so payloads reach the handler in the order hooks connected.
    private let readQueue = DispatchQueue(label: "claudebar.socket.read")

    init(path: String, handler: @escaping (Data) -> Void) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        // A stale socket file from a previous run would make bind() fail.
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw posixError("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(listenFD)
            throw posixError("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, size)
            }
        }
        guard bindResult == 0, listen(listenFD, 16) == 0 else {
            let error = posixError("bind/listen")
            close(listenFD)
            throw error
        }
        // Only you get to talk to ClaudeBar.
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        acceptSource = source
    }

    private func acceptConnection() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }

        var timeout = HookSocketServer.readTimeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        readQueue.async { [weak self] in
            let data = HookSocketServer.readPayload(from: fd)
            close(fd)
            if !data.isEmpty {
                self?.handler(data)
            }
        }
    }

    /// Reads until EOF, timeout, or — the common case — until we hold one
    /// complete JSON object. Closing as soon as the payload is complete
    /// matters: macOS `nc` doesn't half-close after its stdin ends, so
    /// without this every hook would sit waiting for `nc -w` to time out.
    private static func readPayload(from fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxPayloadSize {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if looksComplete(data) { break }
        }
        return data
    }

    private static func looksComplete(_ data: Data) -> Bool {
        let whitespace: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]
        guard let last = data.last(where: { !whitespace.contains($0) }),
              last == UInt8(ascii: "}") else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what) failed: \(String(cString: strerror(errno)))"])
    }

    deinit {
        acceptSource?.cancel()
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }
}
