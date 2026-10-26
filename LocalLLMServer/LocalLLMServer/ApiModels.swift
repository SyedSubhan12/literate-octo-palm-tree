import Foundation

struct APIMessage: Codable, Sendable {
    var role: String
    var content: String
}

struct ChatRequest: Decodable {
    var model: String?
    var messages: [APIMessage]
    var temperature: Double?
    var max_tokens: Int?
    var stream: Bool?
}

struct UIMessage: Identifiable {
    let id = UUID()
    var role: String
    var content: String
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let method: String
    let path: String
    let status: Int
    let ms: Int
}

final class Counter: @unchecked Sendable { var n = 0 }
