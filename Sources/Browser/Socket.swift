import Foundation
import Darwin

private let maxMessage = 8 * 1024 * 1024

private func address(_ path: String) throws -> sockaddr_un {
    var result = sockaddr_un()
    result.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: result.sun_path) else {
        throw BrowserError("socket_path_too_long", "Unix Socket 路径过长")
    }
    withUnsafeMutableBytes(of: &result.sun_path) { $0.copyBytes(from: bytes) }
    result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return result
}

private func withAddress<T>(_ value: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &value) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func socketError(_ operation: String) -> BrowserError {
    BrowserError("ipc_error", "\(operation): \(String(cString: strerror(errno)))")
}

private func configure(_ fd: Int32) {
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    var timeout = timeval(tv_sec: 75, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
}

private func readMessage(_ fd: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while data.count <= maxMessage {
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw socketError("read / incomplete response") }
        if let end = buffer[..<n].firstIndex(of: 10) {
            guard data.count + end <= maxMessage else { throw BrowserError("message_too_large", "IPC 消息超过 8 MiB") }
            data.append(contentsOf: buffer[..<end]); return data
        }
        data.append(contentsOf: buffer[..<n])
    }
    throw BrowserError("message_too_large", "IPC 消息超过 8 MiB")
}

private func writeMessage(_ fd: Int32, _ data: Data) throws {
    guard data.count <= maxMessage else { throw BrowserError("message_too_large", "IPC 消息超过 8 MiB") }
    var line = data; line.append(10)
    try line.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw socketError("write") }
            offset += n
        }
    }
}

func sendRequest(_ request: Request, path: String) throws -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw socketError("socket") }
    defer { close(fd) }
    configure(fd)
    var addr = try address(path)
    guard withAddress(&addr, { Darwin.connect(fd, $0, $1) }) == 0 else { throw socketError("connect; 请先启动 browser daemon") }
    try writeMessage(fd, JSONEncoder().encode(request))
    return try readMessage(fd)
}

final class SocketServer {
    private var fd: Int32 = -1
    private var socketLock: Int32 = -1
    private let path: String
    private let connections = DispatchSemaphore(value: 32)
    init(path: String) { self.path = path }

    func start(handler: @escaping @MainActor (Request) async -> [String: Any]) throws {
        // Never unlink a live daemon's socket. The lock also protects a custom socket shared by two data roots.
        socketLock = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard socketLock >= 0, flock(socketLock, LOCK_EX | LOCK_NB) == 0 else {
            throw BrowserError("already_running", "Socket 已被其他应用占用")
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                throw BrowserError("unsafe_socket_path", "拒绝覆盖非本人 Socket 文件")
            }
            unlink(path) // An IPC endpoint, not a user file.
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("socket") }
        var addr = try address(path)
        guard withAddress(&addr, { Darwin.bind(fd, $0, $1) }) == 0 else { throw socketError("bind") }
        chmod(path, S_IRUSR | S_IWUSR)
        guard listen(fd, 32) == 0 else { throw socketError("listen") }
        let listener = fd
        let connections = self.connections
        DispatchQueue.global().async {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                configure(client)
                // Reserve before dispatching: incomplete clients count toward the bound.
                guard connections.wait(timeout: .now()) == .success else {
                    _ = fcntl(client, F_SETFL, O_NONBLOCK)
                    try? writeMessage(client, jsonData(failure(BrowserError("server_busy", "在途连接已达 32；请稍后重试"))))
                    close(client); continue
                }
                DispatchQueue.global().async {
                    var uid: uid_t = 0; var gid: gid_t = 0
                    guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); connections.signal(); return }
                    do {
                        let request = try JSONDecoder().decode(Request.self, from: readMessage(client))
                        Task { @MainActor in
                            let response = await handler(request)
                            DispatchQueue.global().async {
                                defer { close(client); connections.signal() }
                                do { try writeMessage(client, jsonData(response)) }
                                catch {
                                    var failed = failure(error)
                                    failed["timing"] = response["timing"]
                                    try? writeMessage(client, jsonData(failed))
                                }
                            }
                        }
                    } catch {
                        try? writeMessage(client, jsonData(failure(error))); close(client); connections.signal()
                    }
                }
            }
        }
    }

    deinit {
        if fd >= 0 { close(fd); unlink(path) }
        if socketLock >= 0 { close(socketLock) }
    }
}
