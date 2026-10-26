import Foundation
import Network

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

final class HTTPResponder: @unchecked Sendable {
    let conn: NWConnection
    var onClose: (() -> Void)?
    init(_ c: NWConnection) { conn = c }

    private static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    func send(status: Int, json: Data) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + json, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    func beginSSE() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] e in if e != nil { self?.onClose?() } })
    }

    func sse(_ payload: String) {
        conn.send(content: Data("data: \(payload)\n\n".utf8), completion: .contentProcessed { [weak self] e in
            if e != nil { self?.onClose?() }
        })
    }

    func endSSE() {
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [conn] _ in conn.cancel() })
    }
}

final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, HTTPResponder) async -> Void
    static let maxBody = 256 * 1024
    static let maxHeader = 16 * 1024
    static let maxConnections = 8

    private let queue = DispatchQueue(label: "http.server")
    private var listener: NWListener?
    private var conns = 0

    func start(port: UInt16, advertise: Bool = true, onState: @escaping @Sendable (NWListener.State) -> Void, handler: @escaping Handler) throws {
        stop()
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi   // LAN only; never cellular
        guard let p = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let l = try NWListener(using: params, on: p)
        if advertise { l.service = NWListener.Service(name: "LocalLLM", type: "_http._tcp") }
        l.stateUpdateHandler = onState
        l.newConnectionHandler = { [weak self] c in self?.accept(c, handler) }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private final class Box: @unchecked Sendable { var data = Data(); var dispatched = false }

    private func accept(_ conn: NWConnection, _ handler: @escaping Handler) {
        if conns >= Self.maxConnections { conn.cancel(); return }
        conns += 1
        let responder = HTTPResponder(conn)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: conn.cancel()
            case .cancelled:
                self?.conns -= 1
                responder.onClose?()
            default: break
            }
        }
        conn.start(queue: queue)
        let box = Box()
        queue.asyncAfter(deadline: .now() + 15) { if !box.dispatched { conn.cancel() } }

        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, done, error in
                if let data { box.data.append(data) }
                switch Self.parse(box.data) {
                case .ok(let req):
                    box.dispatched = true
                    Task { await handler(req, responder) }
                case .bad(let code, let msg):
                    box.dispatched = true
                    let j = try? JSONSerialization.data(withJSONObject: ["error": ["message": msg, "type": "invalid_request_error"]])
                    responder.send(status: code, json: j ?? Data())
                case .need:
                    if error != nil || done { conn.cancel() } else { readMore() }
                }
            }
        }
        readMore()
    }

    enum Parsed { case need, ok(HTTPRequest), bad(Int, String) }

    static func parse(_ d: Data) -> Parsed {
        guard let r = d.range(of: Data("\r\n\r\n".utf8)) else {
            return d.count > maxHeader ? .bad(431, "Headers too large") : .need
        }
        guard let head = String(data: d[..<r.lowerBound], encoding: .utf8) else { return .bad(400, "Bad request") }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return .bad(400, "Bad request line") }
        var h: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                h[l[..<i].lowercased()] = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let len = Int(h["content-length"] ?? "0"), len >= 0 else { return .bad(400, "Bad Content-Length") }
        if len > maxBody { return .bad(413, "Request body too large (max 256 KB)") }
        let start = r.upperBound
        if d.count - start < len { return .need }
        return .ok(HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: h,
                               body: d.subdata(in: start..<(start + len))))
    }
}
