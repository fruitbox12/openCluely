#!/bin/bash

# ================================================================
# STEALTH COPILOT: V28 (UI OVERHAUL - 1:1 MATCH)
# ================================================================

set -e

echo "🧠 INITIALIZING V28 WITH MATCHING UI..."
PROJECT_DIR="StealthCopilot"
APP_NAME="StealthCopilot"
BUNDLE_ID="com.overlord.stealthcopilot"

# 1. CLEANUP & SETUP
rm -rf "$PROJECT_DIR"
rm -rf "$APP_NAME.app"
mkdir -p "$PROJECT_DIR/Core"
mkdir -p "$PROJECT_DIR/UI"

# 2. CORE LOGIC

# --- DATA MODELS ---
cat << 'EOF' > "$PROJECT_DIR/Core/Models.swift"
import Foundation

enum LogSource: String, Codable {
    case mic = "MIC"
    case system = "SYS"
    case screen = "SCR"
    case ai = "AI"
    case user_text = "USER"
    case internal_sys = "LOG"
}

struct ContextEvent: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let source: LogSource
    let content: String
    let contextLabel: String? 
    let isVisibleInChat: Bool
}
EOF

# --- LOGGER ---
cat << 'EOF' > "$PROJECT_DIR/Core/ContextLogger.swift"
import Foundation
import SwiftUI

class ContextLogger: ObservableObject {
    static let shared = ContextLogger()
    @Published var logs: [ContextEvent] = []
    private let maxLogs = 200
    
    func log(_ source: LogSource, _ content: String, context: String? = nil, visible: Bool = false) {
        let event = ContextEvent(timestamp: Date(), source: source, content: content, contextLabel: context, isVisibleInChat: visible)
        DispatchQueue.main.async {
            self.logs.append(event)
            if self.logs.count > self.maxLogs { self.logs.removeFirst() }
        }
        if visible { print("💬 [CHAT] \(content)") } 
        else { print("🧠 [CTX] [\(source.rawValue)] \(content)") }
    }
}
EOF

# --- VIDEO UTILS ---
cat << 'EOF' > "$PROJECT_DIR/Core/VideoUtils.swift"
import Foundation
import CoreMedia
import CoreImage
import AppKit

class VideoUtils {
    private static let ciContext = CIContext()
    static func sampleBufferToJPEG(buffer: CMSampleBuffer) -> String? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpegData = ciContext.jpegRepresentation(of: ciImage, colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) else { return nil }
        return jpegData.base64EncodedString()
    }
}
EOF

# --- AUDIO UTILS ---
cat << 'EOF' > "$PROJECT_DIR/Core/AudioUtils.swift"
import Foundation
import AVFoundation
import CoreMedia
import Accelerate

class AudioUtils {
    private static let targetSampleRate: Double = 24000.0
    private static var micConverter: AVAudioConverter?
    private static var sysConverter: AVAudioConverter?
    
    static func calculateRMS(data: Data) -> Float {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return -100 }
        var sum: Double = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let pointer = buffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                let sample = Double(pointer[i]) / 32768.0
                sum += sample * sample
            }
        }
        return 20 * log10(Float(sqrt(sum / Double(sampleCount))) + 1e-9)
    }
    static func dataToInt16Array(_ data: Data) -> [Int16] {
        let count = data.count / MemoryLayout<Int16>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            return Array(ptr)
        }
    }

    private static func runConversion(inputFormat: AVAudioFormat, outputFrameCapacity: AVAudioFrameCount, inputBlock: @escaping AVAudioConverterInputBlock, isSystem: Bool) -> Data? {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: true) else { return nil }
        var converter = isSystem ? sysConverter : micConverter
        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            if isSystem { sysConverter = converter } else { micConverter = converter }
        }
        guard let activeConverter = converter else { return nil }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else { return nil }
        var error: NSError? = nil
        activeConverter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if let channelData = outputBuffer.int16ChannelData {
            let dataLength = Int(outputBuffer.frameLength) * 2
            return Data(bytes: channelData[0], count: dataLength)
        }
        return nil
    }

    static func convertSystemBuffer(_ buffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }
        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else { return nil }
        let inputFrameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))
        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 100
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return AudioUtils.bufferFromCM(buffer, format: inputFormat)
        }
        return runConversion(inputFormat: inputFormat, outputFrameCapacity: outputCapacity, inputBlock: inputBlock, isSystem: true)
    }
    
    static func convertMicBuffer(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format
        let inputFrameCount = buffer.frameLength
        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 100
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        return runConversion(inputFormat: inputFormat, outputFrameCapacity: outputCapacity, inputBlock: inputBlock, isSystem: false)
    }
    
    static func normalizedCorrelation(_ a: [Int16], _ b: [Int16]) -> Float {
        let n = min(a.count, b.count)
        if n < 256 { return 0 }
        var sumA: Float = 0, sumB: Float = 0
        var sumAA: Float = 0, sumBB: Float = 0
        var sumAB: Float = 0
        for i in 0..<n {
            let fa = Float(a[i])
            let fb = Float(b[i])
            sumA += fa; sumB += fb; sumAA += fa * fa; sumBB += fb * fb; sumAB += fa * fb
        }
        let meanA = sumA / Float(n); let meanB = sumB / Float(n)
        let cov = sumAB - Float(n) * meanA * meanB
        let varA = sumAA - Float(n) * meanA * meanA
        let varB = sumBB - Float(n) * meanB * meanB
        let denom = sqrt(max(varA, 1)) * sqrt(max(varB, 1))
        return denom > 0 ? cov / denom : 0
    }
    static func echoScore(mic: [Int16], sys: [Int16]) -> Float {
        let maxLag = 4800
        let step = 240 
        var best: Float = 0
        for lag in stride(from: 0, through: maxLag, by: step) {
            if sys.count < mic.count + lag { break }
            let slice = Array(sys[lag ..< lag + mic.count])
            best = max(best, normalizedCorrelation(mic, slice))
        }
        return best
    }
    private static func bufferFromCM(_ sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let samples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples)
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        if let src = dataPointer {
            if format.commonFormat == .pcmFormatFloat32, let dst = buffer.floatChannelData?[0] { memcpy(dst, src, totalLength) }
            else if format.commonFormat == .pcmFormatInt16, let dst = buffer.int16ChannelData?[0] { memcpy(dst, src, totalLength) }
        }
        return buffer
    }
}
EOF

# --- CONTEXT MANAGER ---
cat << 'EOF' > "$PROJECT_DIR/Core/ContextManager.swift"
import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit
import CryptoKit

class ContextManager: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    
    @Published var isRunning = false
    @Published var isConnected = false
    @Published var micLevel: CGFloat = 0.0
    @Published var sysLevel: CGFloat = 0.0
    @Published var currentVisualContext: String = "Initializing..."
    
    private var webSocketTask: URLSessionWebSocketTask?
    private let audioEngine = AVAudioEngine()
    private var stream: SCStream?
    private let processingQueue = DispatchQueue(label: "com.stealth.processing")
    private var workspaceObservers: [NSObjectProtocol] = []
    
    private var screenFrameCount: Int = 0
    private var audioFrameCount: Int = 0
    private var lastScreenCounterLog: Date = .distantPast
    private var lastAudioCounterLog: Date = .distantPast
    private var shouldAnalyzeNextFrame: Bool = true

    private var sysNoiseFloorDb: Float = -75.0
    private var sysSmoothedDb: Float = -80.0
    private var sysActiveUntil: Date = .distantPast
    private let micRing = Int16RingBuffer(capacity: 24000 * 3)
    private let sysRing = Int16RingBuffer(capacity: 24000 * 3)
    private let echoWindowSamples = 24000 / 5
    private let echoThreshold: Float = 0.60
    private let sysAttack: Float = 0.35
    private let sysRelease: Float = 0.08
    private let sysSNRThreshold: Float = 10.0
    private let sysHangover: TimeInterval = 0.8

    private let apiKey = ""
    private var lastContextDigest: String = ""
    private var lastContextSentAt: Date = .distantPast
    private var contextRequestID: UInt64 = 0
    private var latestContextRequestID: UInt64 = 0

    private let minContextSendInterval: TimeInterval = 1.5
    private let maxContextStaleness: TimeInterval = 12.0
    private var commitTimer: Timer?
    private var lastFrameTime: Date = Date.distantPast
    private let frameInterval: TimeInterval = 1.0
    private var lastSysLogTime: Date = Date.distantPast
    private let audioLogThrottle: TimeInterval = 2.0
    
    func startSession() async {
        ContextLogger.shared.log(.internal_sys, "Initializing V28 (High-Res)...", visible: false)
        connectWebSocket()
        try? await Task.sleep(nanoseconds: 500_000_000)
        setupMicEngine() 
        await setupSystemContext()
        startWorkspaceObservers()
        DispatchQueue.main.async { self.isRunning = true }
        DispatchQueue.main.async {
            self.commitTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                if self.isConnected { self.sendJSON(["type": "input_audio_buffer.commit"]) }
            }
        }
    }
    
    func stopSession() {
        ContextLogger.shared.log(.internal_sys, "Stopping...", visible: false)
        commitTimer?.invalidate()
        stream?.stopCapture()
        audioEngine.stop()
        stopWorkspaceObservers()
        audioEngine.inputNode.removeTap(onBus: 0)
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        DispatchQueue.main.async { 
            self.isRunning = false 
            self.isConnected = false
        }
    }
    private static func sha256(_ s: String) -> String {
        let hash = SHA256.hash(data: Data(s.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func connectWebSocket() {
        let urlString = "wss://api.openai.com/v1/realtime?model=gpt-realtime"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveMessage()
    }
    
    private func sendJSON(_ dict: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        webSocketTask?.send(.string(jsonString)) { error in if let e = error { print("WS Error: \(e)") } }
    }
    
    private func startWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.forceNextFrameAnalysis() })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.forceNextFrameAnalysis() })
    }

    private func stopWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private func forceNextFrameAnalysis() {
        processingQueue.async { [weak self] in
            self?.lastFrameTime = .distantPast
            self?.shouldAnalyzeNextFrame = true
        }
    }

    private func configureSession() {
        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": "You are an Interview Coder Copilot. Brief answers.",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [ "model": "gpt-4o-transcribe" ],
                "turn_detection": NSNull()
            ]
        ]
        sendJSON(config)
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(_): DispatchQueue.main.async { self.isConnected = false }
            case .success(let message):
                if case .string(let text) = message { self.handleResponse(text) }
                self.receiveMessage()
            }
        }
    }
    
    private func handleResponse(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        DispatchQueue.main.async {
            if type == "session.created" { 
                self.isConnected = true; self.configureSession()
            } else if type == "response.audio_transcript.done", let transcript = json["transcript"] as? String {
                ContextLogger.shared.log(.ai, transcript, visible: true)
            }
        }
    }
    
    func sendText(_ text: String) {
        ContextLogger.shared.log(.user_text, text, visible: true)
        sendJSON(["type": "input_audio_buffer.commit"])
        let itemEvent: [String: Any] = [
            "type": "conversation.item.create",
            "item": [ "type": "message", "role": "user", "content": [ ["type": "input_text", "text": text] ] ]
        ]
        sendJSON(itemEvent)
        sendJSON(["type": "response.create"])
    }
    
    private func setupMicEngine() {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        do { try inputNode.setVoiceProcessingEnabled(true) } catch { print("AEC Fail: \(error)") }
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] (buffer, time) in
            self?.processMicBuffer(buffer)
        }
        try? audioEngine.start()
    }
    
    private func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = AudioUtils.convertMicBuffer(buffer) else { return }
        let rms = AudioUtils.calculateRMS(data: data)
        DispatchQueue.main.async { self.micLevel = CGFloat(max(0, (rms + 50) / 50)) }
        let micPCM: [Int16] = AudioUtils.dataToInt16Array(data)
        micRing.append(micPCM)
        let now = Date()
        if now < sysActiveUntil {
            let micWindow = micRing.latestWindow(count: echoWindowSamples)
            let sysWindow = sysRing.latestWindow(count: micWindow.count)
            if !micWindow.isEmpty && sysWindow.count == micWindow.count {
                let echo = AudioUtils.echoScore(mic: micWindow, sys: sysWindow)
                if echo >= echoThreshold { return }
            }
        }
        if isConnected {
            let event: [String: Any] = ["type": "input_audio_buffer.append", "audio": data.base64EncodedString()]
            sendJSON(event)
        }
    }

    private func pickBestDisplay(from content: SCShareableContent) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           let idNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let id = idNum.uint32Value
            if let match = content.displays.first(where: { $0.displayID == id }) { return match }
        }
        return content.displays.first
    }

    private func setupSystemContext() async {
        do {
            let content = try await SCShareableContent.current
            guard let display = pickBestDisplay(from: content) else { return }
            let excluded = content.applications.filter { app in app.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 1920; config.height = 1080
            config.capturesAudio = true; config.excludesCurrentProcessAudio = true
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
            try await stream?.startCapture()
        } catch { print("SCK Error: \(error)") }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { try? await Task.sleep(nanoseconds: 300_000_000); await setupSystemContext() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let now = Date()
        switch type {
        case .screen:
            screenFrameCount += 1
            if now.timeIntervalSince(lastScreenCounterLog) > 1.0 {
                lastScreenCounterLog = now
                screenFrameCount = 0
            }
            processingQueue.async { [weak self] in self?.analyzeScreen(sampleBuffer) }
        case .audio:
            audioFrameCount += 1
            if now.timeIntervalSince(lastAudioCounterLog) > 2.0 {
                lastAudioCounterLog = now
                audioFrameCount = 0
            }
            processingQueue.async { [weak self] in self?.processSystemAudio(sampleBuffer) }
        @unknown default: break
        }
    }

    private func analyzeScreen(_ buffer: CMSampleBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now
        guard let base64 = VideoUtils.sampleBufferToJPEG(buffer: buffer) else { return }
        contextRequestID &+= 1
        let reqID = contextRequestID
        latestContextRequestID = reqID
        analyzeContext(base64Image: base64, requestID: reqID)
    }

    private func analyzeContext(base64Image: String, requestID: UInt64) {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "gpt-4.1-mini",
            "messages": [ [ "role": "user", "content": [ ["type": "text", "text": "Accurately describe screen content briefly."], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]] ] ] ],
            "max_tokens": 150
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, let data = data, requestID == self.latestContextRequestID else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let desc = message["content"] as? String else { return }
            DispatchQueue.main.async {
                let clean = desc.trimmingCharacters(in: .whitespacesAndNewlines)
                self.currentVisualContext = clean
                let now = Date()
                let digest = Self.sha256(clean)
                let changed = (digest != self.lastContextDigest)
                let stale = now.timeIntervalSince(self.lastContextSentAt) > self.maxContextStaleness
                let canSend = now.timeIntervalSince(self.lastContextSentAt) > self.minContextSendInterval
                guard canSend && (changed || stale) else { return }
                self.lastContextDigest = digest
                self.lastContextSentAt = now
                self.sendJSON([ "type": "conversation.item.create", "item": [ "type": "message", "role": "user", "content": [[ "type": "input_text", "text": "System Context Update: \(clean)" ]] ] ])
                ContextLogger.shared.log(.screen, "Context: \(clean)", visible: false)
            }
        }.resume()
    }

    private func processSystemAudio(_ buffer: CMSampleBuffer) {
        guard let data = AudioUtils.convertSystemBuffer(buffer) else { return }
        let rmsDb = AudioUtils.calculateRMS(data: data)
        DispatchQueue.main.async { self.sysLevel = CGFloat(max(0, min(1, (rmsDb + 50) / 50))) }
        let target = rmsDb
        if target > sysSmoothedDb { sysSmoothedDb = sysSmoothedDb + (target - sysSmoothedDb) * sysAttack } 
        else { sysSmoothedDb = sysSmoothedDb + (target - sysSmoothedDb) * sysRelease }
        let now = Date()
        if now >= sysActiveUntil {
            sysNoiseFloorDb = sysNoiseFloorDb + (sysSmoothedDb - sysNoiseFloorDb) * 0.02
            sysNoiseFloorDb = max(-90, min(sysNoiseFloorDb, -30))
        }
        let snr = sysSmoothedDb - sysNoiseFloorDb
        let isActive = snr >= sysSNRThreshold
        if isActive { sysActiveUntil = now.addingTimeInterval(sysHangover) }
        if now < sysActiveUntil {
            if now.timeIntervalSince(lastSysLogTime) > audioLogThrottle {
                ContextLogger.shared.log(.system, "Audio Active", context: currentVisualContext, visible: false)
                lastSysLogTime = now
            }
        }
        if isConnected {
            let event: [String: Any] = ["type": "input_audio_buffer.append", "audio": data.base64EncodedString()]
            sendJSON(event)
        }
    }
}
EOF
cat << 'EOF' > "$PROJECT_DIR/Core/RingBuffer.swift"
import Foundation
final class Int16RingBuffer {
    private var buf: [Int16]
    private var writeIndex: Int = 0
    private var isFull: Bool = false
    private let capacity: Int
    init(capacity: Int) { self.capacity = max(1024, capacity); self.buf = Array(repeating: 0, count: self.capacity) }
    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        for s in samples { buf[writeIndex] = s; writeIndex += 1; if writeIndex >= capacity { writeIndex = 0; isFull = true } }
    }
    func latestWindow(count: Int) -> [Int16] {
        let n = min(count, isFull ? capacity : writeIndex)
        guard n > 0 else { return [] }
        var out = Array(repeating: Int16(0), count: n)
        let end = writeIndex
        var start = end - n
        if start < 0 { start += capacity }
        if start < end { out.replaceSubrange(0..<n, with: buf[start..<end]) } 
        else { let firstLen = capacity - start; out.replaceSubrange(0..<firstLen, with: buf[start..<capacity]); if n > firstLen { out.replaceSubrange(firstLen..<n, with: buf[0..<(n - firstLen)]) } }
        return out
    }
}
EOF

# --- UI (1:1 REPLICATION) ---
cat << 'EOF' > "$PROJECT_DIR/UI/SecureChatView.swift"
import SwiftUI

// --- UI COMPONENTS ---

struct ActionButton: View {
    let icon: String
    let text: String
    var action: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(text).font(.system(size: 12, weight: .medium))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(isHovering ? .white : Color(white: 0.8))
        .onHover { isHovering = $0 }
    }
}

struct LogRow: View {
    let event: ContextEvent
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if event.source == .ai { 
                Image(systemName: "sparkles").foregroundColor(.white).font(.system(size: 12)) 
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(event.content)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .lineLimit(nil)
            }
            
            if event.source != .ai { Spacer() }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
    }
}

// --- MAIN VIEW ---

struct SecureChatView: View {
    @StateObject var context = ContextManager()
    @ObservedObject var logger = ContextLogger.shared
    @State private var inputText = ""
    
    // Custom Colors matching the screenshot (Dark Slate)
    let cardBg = Color(red: 0.13, green: 0.16, blue: 0.19)
    let pillBg = Color(red: 0.08, green: 0.10, blue: 0.11)
    let borderColor = Color.white.opacity(0.12)
    
    var chatMessages: [ContextEvent] { return logger.logs.filter { $0.isVisibleInChat } }
    
    var body: some View {
        VStack(spacing: 12) {
            
            // 1. CONTROL PILL (Floating Top Bar)
            HStack(spacing: 0) {
                // Logo Section
                HStack {
                   Image(systemName: "safari.fill") // Placeholder for the app logo
                       .font(.system(size: 16))
                       .foregroundColor(.white)
                }
                .padding(.leading, 12)
                
                Spacer().frame(width: 12)
                
                // Hide Button
                Button(action: { /* Window hide logic */ }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                        Text("Hide").font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(16)
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer().frame(width: 8)
                
                // Stop Button
                Button(action: { 
                    if context.isRunning { context.stopSession() } else { Task { await context.startSession() } }
                }) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.1)).frame(width: 28, height: 28)
                        Image(systemName: context.isRunning ? "square.fill" : "play.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 6)
            }
            .frame(height: 44)
            .background(pillBg)
            .cornerRadius(22)
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(borderColor, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
            
            // 2. MAIN INTERACTION CARD
            VStack(alignment: .leading, spacing: 0) {
                
                // A. Quick Actions Header
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ActionButton(icon: "sparkles", text: "Assist") {}
                        ActionButton(icon: "wand.and.stars", text: "What should I say?") {}
                        ActionButton(icon: "message", text: "Follow-up questions") {}
                        ActionButton(icon: "clock.arrow.circlepath", text: "Recap") {}
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
                
                // B. Chat / Content Area
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                             if chatMessages.isEmpty {
                                 Text("") // Spacer
                                     .frame(height: 100)
                             } else {
                                 ForEach(chatMessages) { event in LogRow(event: event).id(event.id) }
                             }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(minHeight: 100, maxHeight: 300)
                    .onChange(of: chatMessages.count) { _ in if let last = chatMessages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                }
                
                Spacer()
                
                // C. Input Field (Bottom)
                HStack(spacing: 10) {
                    ZStack(alignment: .leading) {
                        if inputText.isEmpty {
                            HStack(spacing: 4) {
                                Text("Ask about your screen or conversation, or")
                                    .foregroundColor(.gray)
                                // Visual Key Hint: CMD
                                Text("⌘")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.gray)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5), lineWidth: 1))
                                // Visual Key Hint: ENTER
                                Image(systemName: "return")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.gray)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5), lineWidth: 1))
                                
                                Text("for Assist")
                                    .foregroundColor(.gray)
                            }
                            .font(.system(size: 13))
                            .allowsHitTesting(false)
                        }
                        
                        TextField("", text: $inputText)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .padding(.vertical, 10)
                            .onSubmit { sendMessage() }
                    }
                    
                    // Send Button
                    Button(action: sendMessage) {
                        ZStack {
                            Circle().fill(Color(red: 0.1, green: 0.3, blue: 0.8)).frame(width: 30, height: 30)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(inputText.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 8)
            }
            .background(cardBg)
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderColor, lineWidth: 1))
        }
        .padding(12)
        .background(Color.clear) // The window itself is transparent
    }
    
    private func sendMessage() { guard !inputText.isEmpty else { return }; context.sendText(inputText); inputText = "" }
}
EOF

# --- WINDOW & APP ---
cat << 'EOF' > "$PROJECT_DIR/UI/SecureWindow.swift"
import Cocoa
import SwiftUI

class SecureWindowController: NSWindowController {
    convenience init() {
        // Updated rect to accommodate the taller UI with the detached pill
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400), styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.sharingType = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear 
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        
        let hostingView = NSHostingView(rootView: SecureChatView())
        panel.contentView = hostingView
        self.init(window: panel)
    }
}
EOF
cat << 'EOF' > "$PROJECT_DIR/App.swift"
import SwiftUI
@main struct StealthCopilotApp: App { @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate; var body: some Scene { Settings { EmptyView() } } }
class AppDelegate: NSObject, NSApplicationDelegate { var secureWindow: SecureWindowController?; func applicationDidFinishLaunching(_ notification: Notification) { secureWindow = SecureWindowController(); if let screen = NSScreen.main, let window = secureWindow?.window { let frame = screen.visibleFrame; window.setFrameOrigin(NSPoint(x: frame.maxX - window.frame.width - 50, y: frame.maxY - window.frame.height - 100)); window.orderFront(nil) } } }
EOF

# 3. BUILD
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"
cat <<EOF > "$APP_NAME.app/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>$APP_NAME</string><key>CFBundleIdentifier</key><string>$BUNDLE_ID</string><key>CFBundleName</key><string>$APP_NAME</string><key>LSUIElement</key><true/><key>NSMicrophoneUsageDescription</key><string>Hearing.</string><key>NSAppleEventsUsageDescription</key><string>Seeing.</string></dict></plist>
EOF
cat <<EOF > "entitlements.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/><key>com.apple.security.device.camera</key><true/><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
EOF

echo "🔨 Compiling..."
swiftc "$PROJECT_DIR/App.swift" "$PROJECT_DIR/Core/"*.swift "$PROJECT_DIR/UI/"*.swift \
    -o "$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    -target arm64-apple-macosx13.0 \

echo "🔐 Signing..."
codesign --force --deep --sign - --entitlements entitlements.plist "$APP_NAME.app"
rm entitlements.plist

echo "✅ DONE. Launching..."
./StealthCopilot.app/Contents/MacOS/StealthCopilot
