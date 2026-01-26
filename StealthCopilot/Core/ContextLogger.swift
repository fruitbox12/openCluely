import Foundation

class ContextLogger {
    static let shared = ContextLogger()
    private let dateFormatter: DateFormatter
    
    init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }
    
    func log(source: ContextSource, details: String) {
        let timestamp = Date()
        let logString = "[\(dateFormatter.string(from: timestamp))] [\(source.rawValue)] \(details)"
        print(logString) // In a real app, append to a file
    }
}
