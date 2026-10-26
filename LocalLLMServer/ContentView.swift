import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case chat = "Chat", model = "Model", server = "API Server"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .model: return "cpu"
        case .server: return "network"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var section: AppSection? = .model

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationTitle("LocalLLM")
        } detail: {
            switch section ?? .model {
            case .chat: ChatView()
            case .model: ModelView()
            case .server: ServerView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct ChatView: View {
    @EnvironmentObject var app: AppState
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "airplane").foregroundStyle(.green)
                Text(app.modelLoaded ? "On-device · \(app.modelID)" : "No model loaded")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { app.clearChat() }.disabled(app.messages.isEmpty)
            }.padding(.horizontal).padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(app.messages) { m in
                            HStack {
                                if m.role == "user" { Spacer(minLength: 60) }
                                Text(m.content.isEmpty ? "…" : m.content)
                                    .padding(12)
                                    .background(m.role == "user" ? Color.blue.opacity(0.6) : Color.gray.opacity(0.25))
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .textSelection(.enabled)
                                if m.role != "user" { Spacer(minLength: 60) }
                            }.id(m.id)
                        }
                    }.padding()
                }
                .onChange(of: app.messages.last?.content) { _, _ in
                    if let last = app.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack(alignment: .bottom) {
                TextField("Message", text: $input, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.roundedBorder)
                if app.generating {
                    Button { app.stopChat() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                } else {
                    Button {
                        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        input = ""
                        app.sendChat(t)
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(!app.modelLoaded || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding()
        }
        .navigationTitle("Chat")
    }
}

struct ModelView: View {
    @EnvironmentObject var app: AppState
    @State private var confirm = false

    private var preset: Preset? { presets.first { $0.id == app.modelID } }

    var body: some View {
        Form {
            Section("Device") {
                Text("RAM: \(String(format: "%.0f", app.ramGB)) GB. Keep models at ~4 GB or less on 8 GB iPads.")
            }
            Section("Model (Hugging Face ID)") {
                Picker("Preset", selection: Binding(get: { preset?.id ?? "" }, set: { app.modelID = $0 })) {
                    ForEach(presets) { Text($0.name).tag($0.id) }
                    if preset == nil { Text("Custom").tag("") }
                }
                TextField("mlx-community/…", text: $app.modelID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if let p = preset {
                    Text("Download ≈ \(String(format: "%.1f", p.sizeGB)) GB · License: \(p.license)")
                        .font(.footnote).foregroundStyle(.secondary)
                    if p.sizeGB * 1.5 > app.ramGB * 0.5 {
                        Text("⚠️ Likely too large for this device's memory.").foregroundStyle(.orange)
                    }
                } else {
                    Text("Custom model: check its size and license on huggingface.co before loading.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Status") {
                Text(app.status)
                if app.isLoading { ProgressView(value: app.loadProgress) }
                Button(app.isDownloaded ? "Load model" : "Download & load…") {
                    if app.isDownloaded { app.loadModel() } else { confirm = true }
                }.disabled(app.isLoading)
                Button("Unload model", role: .destructive) { app.unloadModel() }
                    .disabled(!app.modelLoaded)
            }
        }
        .navigationTitle("Model")
        .confirmationDialog(
            "Download \(preset.map { String(format: "≈ %.1f GB", $0.sizeGB) } ?? "this model (size unknown)") from Hugging Face?",
            isPresented: $confirm, titleVisibility: .visible) {
            Button("Download") { app.loadModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Uses Wi-Fi/cellular data once. Afterwards the model runs fully offline.")
        }
    }
}

struct ServerView: View {
    @EnvironmentObject var app: AppState
    @State private var showToken = false

    private var curl: String {
        """
        curl \(app.baseURL)/chat/completions \\
          -H "Authorization: Bearer \(app.token)" \\
          -H "Content-Type: application/json" \\
          -d '{"model":"local-model","messages":[{"role":"user","content":"Hello!"}],"max_tokens":128}'
        """
    }

    var body: some View {
        Form {
            Section("Server") {
                HStack {
                    Circle().fill(app.serverRunning ? .green : .red).frame(width: 10, height: 10)
                    Text(app.serverMessage)
                }
                TextField("Port", text: $app.port).keyboardType(.numberPad).disabled(app.serverRunning)
                if app.serverRunning {
                    Button("Stop server", role: .destructive) { app.stopServer() }
                } else {
                    Button("Start server") { app.startServer() }
                }
                Text("Model: \(app.modelLoaded ? app.modelID : "none")")
                Text("Active requests: \(app.activeRequests)")
                Text("Build 3 (no Bonjour, auto-restart)").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Address") {
                Text(app.baseURL).textSelection(.enabled)
                Button("Copy base URL") { UIPasteboard.general.string = app.baseURL }
                Text("Same Wi-Fi only. Plain HTTP (unencrypted): use a network you trust. Keep this app open and the iPad awake.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("API token") {
                Text(showToken ? app.token : "••••••••••••••••").textSelection(.enabled)
                Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                Button("Copy token") { UIPasteboard.general.string = app.token }
                Button("Rotate token (revokes old one)", role: .destructive) { app.rotateToken() }
            }
            Section("Test from another device") {
                Text(curl).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Button("Copy curl") { UIPasteboard.general.string = curl }
            }
            Section("Recent requests (no prompt content stored)") {
                ForEach(app.logs) { l in
                    Text("\(l.time.formatted(date: .omitted, time: .standard))  \(l.method) \(l.path)  \(l.status)  \(l.ms) ms")
                        .font(.system(.footnote, design: .monospaced))
                }
                Button("Clear logs") { app.logs = [] }.disabled(app.logs.isEmpty)
            }
        }
        .navigationTitle("API Server")
    }
}
