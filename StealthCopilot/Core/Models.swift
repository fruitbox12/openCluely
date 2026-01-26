import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String // "user", "ai", "system"
    var content: String
}

enum ContextSource: String {
    case microphone = "MIC"
    case systemAudio = "SYS"
    case screen = "SCR"
}

struct ContextLog {
    let timestamp: Date
    let source: ContextSource
    let details: String
}
