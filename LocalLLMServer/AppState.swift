import SwiftUI
import Network
import Security

struct Preset: Identifiable, Hashable {
    let id: String
    let name: String
    let sizeGB: Double
    let license: String
}

let presets: [Preset] = [
    Preset(id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", name: "Qwen2.5 1.5B Instruct (4-bit)", sizeGB: 0.9, license: "Apache-2.0"),
    Preset(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama 3.2 3B Instruct (4-bit)", sizeGB: 1.8, license: "Llama 3.2 Community License"),
    Preset(id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B (4-bit)", sizeGB: 2.3, license: "Apache-2.0"),
]

@MainActor
final class AppState: ObservableObject {
    let engine = InferenceEngine()
    let server = HTTPServer()
    private let ud = UserDefaults.standard

    // Model
    @Published var modelID: String
    @Published var modelLoaded = false
    @Published var isLoading = false
    @Published var loadProgress = 0.0
    @Published var status = "No model loaded"

    // Server
    @Published var serverRunning = false
    @Published var serverMessage = "Stopped"
    @Published var port: String
    @Published var ip: String? = nil
    @Published var activeRequests = 0
    @Published var logs: [LogEntry] = []
    @Published var token: String {
        didSet { ud.set(token, forKey: "token") }
    }

    // Chat
    @Published var messages: [UIMessage] = []
    @Published var generating = false
    private var chatTask: Task<Void, Never>?

    init() {
        modelID = ud.string(forKey: "modelID") ?? presets[0].id
        port = ud.string(forKey: "port") ?? "8080"
        token = ud.string(forKey: "token") ?? Self.makeToken()
        ud.set(token, forKey: "token")
    }

    static func makeToken() -> String {
        var b = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        let s = Data(b).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "llm-" + s
    }

    func rotateToken() { token = Self.makeToken() }

    var baseURL: String { "http://\(ip ?? "<ip>"):\(port)/v1" }
    var ramGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }
    var isDownloaded: Bool { (ud.stringArray(forKey: "downloaded") ?? []).contains(modelID) }

    // MARK: Model

    func loadModel() {
        guard !isLoading else { return }
        isLoading = true
        modelLoaded = false
        loadProgress = 0
        status = "Downloading / loading…"
        let id = modelID
        ud.set(id, forKey: "modelID")
        Task {
            do {
                try await engine.load(id: id) { p in Task { @MainActor in self.loadProgress = p } }
                modelLoaded = true
                status = "Loaded: \(id)"
                var d = ud.stringArray(forKey: "downloaded") ?? []
                if !d.contains(id) { d.append(id); ud.set(d, forKey: "downloaded") }
            } catch {
                status = "Load failed: \(error.localizedDescription). If memory ran out, pick a smaller model."
            }
            isLoading = false
        }
    }

    func unloadModel() {
        stopChat()
        Task {
            await engine.unload()
            modelLoaded = false
            status = "Model unloaded"
        }
    }

    // MARK: Chat

    func sendChat(_ text: String) {
        guard modelLoaded, !generating, !text.isEmpty else { return }
        messages.append(UIMessage(role: "user", content: text))
        messages.append(UIMessage(role: "assistant", content: ""))
        generating = true
        let history = messages.dropLast().map { APIMessage(role: $0.role, content: $0.content) }
        chatTask = Task {
            guard await engine.tryBegin() else {
                messages[messages.count - 1].content = "[Busy: an API request is generating. Try again shortly.]"
                generating = false
                return
            }
            do {
                let full = try await engine.generate(messages: history, temperature: 0.7, maxTokens: 512) { _ in }
                messages[messages.count - 1].content = full
            } catch {
                messages[messages.count - 1].content += "\n[error: \(error.localizedDescription)]"
            }
            await engine.end()
            generating = false
        }
    }

    func stopChat() { chatTask?.cancel() }
    func clearChat() { stopChat(); messages = [] }

    // MARK: Server

    func startServer() {
        guard let p = UInt16(port), p >= 1024 else { serverMessage = "Invalid port (use 1024–65535)"; return }
        ud.set(port, forKey: "port")
        ip = Self.localIP()
        serverMessage = "Starting…"
        do {
            try server.start(port: p, onState: { [weak self] st in
                Task { @MainActor in self?.serverState(st) }
            }, handler: { [weak self] req, r in
                await self?.handle(req, r)
            })
        } catch {
            serverMessage = "Could not start: \(error.localizedDescription)"
        }
    }

    func stopServer() {
        server.stop()
        serverRunning = false
        serverMessage = "Stopped"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func serverState(_ st: NWListener.State) {
        switch st {
        case .ready:
            serverRunning = true
            serverMessage = "Running"
            ip = Self.localIP()
            UIApplication.shared.isIdleTimerDisabled = true   // keep screen awake while serving
        case .failed(let e):
            server.stop()
            serverRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
            if case .posix(let code) = e, code == .EADDRINUSE {
                serverMessage = "Port \(port) is already in use. Choose another port."
            } else {
                serverMessage = "Server failed: \(e.localizedDescription)"
            }
        default: break
        }
    }

    static func localIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = ptr.pointee
            guard let addr = i.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: i.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        return nil
    }

    // MARK: API routing

    private func handle(_ req: HTTPRequest, _ r: HTTPResponder) async {
        let t0 = Date()
        activeRequests += 1
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        let status = await route(req, path, r)
        activeRequests -= 1
        logs.insert(LogEntry(method: req.method, path: path, status: status,
                             ms: Int(Date().timeIntervalSince(t0) * 1000)), at: 0)
        if logs.count > 100 { logs.removeLast() }
    }

    @discardableResult
    private func reply(_ r: HTTPResponder, _ code: Int, _ obj: [String: Any]) -> Int {
        r.send(status: code, json: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
        return code
    }

    private func fail(_ r: HTTPResponder, _ code: Int, _ msg: String, _ type: String) -> Int {
        reply(r, code, ["error": ["message": msg, "type": type]])
    }

    private func route(_ req: HTTPRequest, _ path: String, _ r: HTTPResponder) async -> Int {
        if req.method == "GET" && path == "/health" {
            return reply(r, 200, ["status": "ok", "model_loaded": modelLoaded, "inference_device": "local"])
        }
        guard req.headers["authorization"] == "Bearer \(token)" else {
            return fail(r, 401, "Missing or invalid API token", "invalid_api_key")
        }
        switch (req.method, path) {
        case ("GET", "/v1/models"):
            var data: [[String: Any]] = []
            if let id = await engine.currentModelID() {
                data.append(["id": id, "object": "model", "owned_by": "local"])
            }
            return reply(r, 200, ["object": "list", "data": data])
        case ("POST", "/v1/chat/completions"):
            return await chat(req, r)
        default:
            return fail(r, 404, "Not found", "not_found")
        }
    }

    private func chat(_ req: HTTPRequest, _ r: HTTPResponder) async -> Int {
        guard let cr = try? JSONDecoder().decode(ChatRequest.self, from: req.body) else {
            return fail(r, 400, "Malformed JSON, or 'messages' missing/invalid (content must be a string)", "invalid_request_error")
        }
        guard !cr.messages.isEmpty, cr.messages.count <= 64,
              cr.messages.allSatisfy({ ["system", "user", "assistant"].contains($0.role) }) else {
            return fail(r, 400, "'messages' must hold 1–64 items with role system/user/assistant", "invalid_request_error")
        }
        guard let mid = await engine.currentModelID() else {
            return fail(r, 503, "No model is loaded. Load one in the app's Model tab.", "model_not_loaded")
        }
        if let m = cr.model, m != "local-model", m != mid {
            return fail(r, 404, "Unknown model '\(m)'. Use 'local-model' or '\(mid)'.", "model_not_found")
        }
        let temp = Float(min(max(cr.temperature ?? 0.7, 0), 2))
        let maxTok = min(max(cr.max_tokens ?? 256, 1), 1024)
        guard await engine.tryBegin() else {
            return fail(r, 429, "Busy: only one generation at a time. Retry shortly.", "rate_limit_exceeded")
        }
        let id = "chatcmpl-" + UUID().uuidString.prefix(12).lowercased()
        let created = Int(Date().timeIntervalSince1970)
        let engine = self.engine
        let msgs = cr.messages

        if cr.stream == true {
            func chunk(_ delta: [String: Any], _ finish: Any) -> String {
                let o: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": mid,
                                        "choices": [["index": 0, "delta": delta, "finish_reason": finish]]]
                return String(data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), encoding: .utf8) ?? "{}"
            }
            r.beginSSE()
            r.sse(chunk(["role": "assistant", "content": ""], NSNull()))
            let count = Counter()
            let work = Task {
                try await engine.generate(messages: msgs, temperature: temp, maxTokens: maxTok) { s in
                    count.n += 1
                    r.sse(chunk(["content": s], NSNull()))
                }
            }
            r.onClose = { work.cancel() }   // client disconnected → stop generating
            let result = await work.result
            await engine.end()
            if case .failure = result, !work.isCancelled {
                r.sse(chunk(["content": "\n[generation error]"], NSNull()))
            }
            r.sse(chunk([:], count.n >= maxTok ? "length" : "stop"))
            r.sse("[DONE]")
            r.endSSE()
            return 200
        }

        let count = Counter()
        let work = Task {
            try await engine.generate(messages: msgs, temperature: temp, maxTokens: maxTok) { _ in count.n += 1 }
        }
        r.onClose = { work.cancel() }
        let result = await work.result
        await engine.end()
        switch result {
        case .success(let text):
            return reply(r, 200, [
                "id": id, "object": "chat.completion", "created": created, "model": mid,
                "choices": [["index": 0,
                             "message": ["role": "assistant", "content": text],
                             "finish_reason": count.n >= maxTok ? "length" : "stop"]],
            ])
        case .failure:
            return fail(r, 500, "Generation failed (possibly out of memory). Try a smaller model or fewer tokens.", "server_error")
        }
    }
}
