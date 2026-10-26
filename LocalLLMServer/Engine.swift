import Foundation
import MLX
import MLXLLM
import MLXLMCommon

enum EngineError: Error { case noModel }

/// Wraps MLX Swift LM. One generation at a time (guarded by tryBegin/end).
actor InferenceEngine {
    private var container: ModelContainer?
    private var loadedID: String?
    private var busy = false

    func currentModelID() -> String? { loadedID }

    func load(id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        container = nil
        loadedID = nil
        MLX.GPU.clearCache()
        MLX.GPU.set(cacheLimit: 64 * 1024 * 1024)
        let c = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: id)
        ) { p in progress(p.fractionCompleted) }
        container = c
        loadedID = id
    }

    func unload() {
        container = nil
        loadedID = nil
        MLX.GPU.clearCache()
    }

    func tryBegin() -> Bool {
        if busy { return false }
        busy = true
        return true
    }

    func end() { busy = false }

    func generate(messages: [APIMessage], temperature: Float, maxTokens: Int,
                  onChunk: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let container else { throw EngineError.noModel }
        let chat: [Chat.Message] = messages.map { m in
            switch m.role {
            case "system": return .system(m.content)
            case "assistant": return .assistant(m.content)
            default: return .user(m.content)
            }
        }
        let params = GenerateParameters(maxTokens: maxTokens, maxKVSize: 2048, temperature: temperature)
        let text: String = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(chat: chat))
            let stream = try MLXLMCommon.generate(input: input, parameters: params, context: context)
            var out = ""
            for await item in stream {
                if Task.isCancelled { break }
                if case .chunk(let s) = item {
                    out += s
                    onChunk(s)
                }
            }
            return out
        }
        return text
    }
}
