import Foundation

/// Gercek bir localhost HTTP/1.1 sunucusu (BSD socket tabanli — availability
/// kisiti yok, deterministik). Her test kendi ephemeral portunda bir instance
/// kurar; sunucu gelen HAM istekleri (method/path/header/body) kaydeder ve
/// programlanabilir bir responder ile yanit doner. Boylece SDK'nin URLSession
/// yolu GERCEK kalir ve assertion'lar sunucunun kaydettigi ham istek govdesi
/// uzerinden yapilir.
final class TestHTTPServer {

    struct RecordedRequest {
        let method: String
        let path: String
        /// Header adlari lowercase normalize edilir.
        let headers: [String: String]
        let body: Data

        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    typealias Responder = (RecordedRequest) -> (status: Int, json: [String: Any])

    enum ServerError: Error { case socketFailed, bindFailed, listenFailed }

    private let lock = NSLock()
    private var _requests: [RecordedRequest] = []
    private var _responder: Responder = { _ in (200, ["success": true]) }
    /// Yanit gondermeden once sunucu tarafinda bekleme (in-flight testleri icin).
    private var _responseDelay: TimeInterval = 0

    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0

    var baseUrl: String { "http://127.0.0.1:\(port)" }

    init() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw ServerError.socketFailed }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(listenFD); throw ServerError.bindFailed }
        guard listen(listenFD, 16) == 0 else { close(listenFD); throw ServerError.listenFailed }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &len)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)

        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 { break } // sunucu kapatildi
                guard let self = self else { close(clientFD); break }
                Thread.detachNewThread { self.handle(clientFD) }
            }
        }
    }

    deinit { stop() }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    // MARK: - Test API

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func requests(to pathPrefix: String) -> [RecordedRequest] {
        requests.filter { $0.path.hasPrefix(pathPrefix) }
    }

    func setResponder(_ responder: @escaping Responder) {
        lock.lock(); _responder = responder; lock.unlock()
    }

    func setResponseDelay(_ delay: TimeInterval) {
        lock.lock(); _responseDelay = delay; lock.unlock()
    }

    /// Baglanti-reddi (connection refused) senaryolari icin: bir port ayirip
    /// hemen kapatir — o porta giden istekler aninda ag hatasi alir.
    static func deadPort() throws -> UInt16 {
        let server = try TestHTTPServer()
        let port = server.port
        server.stop()
        return port
    }

    // MARK: - Connection handling

    private func handle(_ fd: Int32) {
        defer { close(fd) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let headerTerminator = Data("\r\n\r\n".utf8)

        // Header'lar tamamlanana kadar oku.
        var headerRange = buffer.range(of: headerTerminator)
        while headerRange == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            headerRange = buffer.range(of: headerTerminator)
        }
        guard let headerEnd = headerRange else { return }

        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        let method = requestLine.first ?? ""
        let path = requestLine.count > 1 ? requestLine[1] : ""

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Body'yi Content-Length kadar oku.
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        var body = buffer.subdata(in: headerEnd.upperBound..<buffer.count)
        while body.count < contentLength {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            body.append(contentsOf: chunk[0..<n])
        }

        let request = RecordedRequest(method: method, path: path, headers: headers, body: body)
        lock.lock()
        _requests.append(request)
        let responder = _responder
        let delay = _responseDelay
        lock.unlock()

        if delay > 0 { Thread.sleep(forTimeInterval: delay) }

        let (status, json) = responder(request)
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : "STATUS"
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < out.count {
                let n = write(fd, base + sent, out.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
