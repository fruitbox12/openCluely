import Foundation
import ScreenCaptureKit
import AVFoundation

class ContextManager: NSObject, ObservableObject, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    
    // UI STATE
    @Published var isRunning = false
    @Published var isConnected = false
    @Published var micLevel: CGFloat = 0.0
    @Published var sysLevel: CGFloat = 0.0
    @Published var messages: [ChatMessage] = []
    
    // INTERNAL
    private var webSocketTask: URLSessionWebSocketTask?
    private var stream: SCStream?
    private let micSession = AVCaptureSession()
    private let processingQueue = DispatchQueue(label: "com.stealth.processing")
    private let apiKey = ""
    
    private var commitTimer: Timer?
    private var lastFrameTime: Date = Date.distantPast
    private let frameInterval: TimeInterval = 5.0 
    
    func startSession() async {
        print("🚀 Starting Session...")
        connectWebSocket()
        try? await Task.sleep(nanoseconds: 500_000_000)
        setupMic()
        await setupSystemContext()
        DispatchQueue.main.async { self.isRunning = true }
        
        DispatchQueue.main.async {
            self.commitTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                if self.isConnected {
                    self.sendJSON(["type": "input_audio_buffer.commit"])
                }
            }
        }
    }
    
    func stopSession() {
        commitTimer?.invalidate()
        stream?.stopCapture()
        micSession.stopRunning()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        DispatchQueue.main.async { 
            self.isRunning = false 
            self.isConnected = false
        }
    }
    
    // --- WEBSOCKET ---
    private func connectWebSocket() {
        ContextLogger.shared.log(source: .systemAudio, details: "Initiating WebSocket Connection")
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
        webSocketTask?.send(.string(jsonString)) { error in
             if let error = error { print("❌ WS Send Error: \(error.localizedDescription)") }
        }
    }
    
    private func configureSession() {
        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": "You are a helpful assistant. Only speak English. The user will provide audio (both voice and system audio) and screen context. SILENTLY absorb this context. DO NOT REPLY until the user sends a specific text question.",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [ "model": "whisper-1" ],
                "turn_detection": NSNull() 
            ]
        ]
        sendJSON(config)
        print("⚙️ Session Configured")
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("❌ WS Error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.isConnected = false }
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
            } else if type == "response.text.delta", let delta = json["delta"] as? String { 
                self.appendToLastMessage(role: "ai", content: delta)
            } else if type == "response.audio_transcript.done", let transcript = json["transcript"] as? String {
                if self.messages.last?.role == "ai" && self.messages.last?.content.contains(transcript) == false {
                     self.appendToLastMessage(role: "ai", content: transcript)
                } else if self.messages.last?.role != "ai" {
                     self.messages.append(ChatMessage(role: "ai", content: transcript))
                }
            }
        }
    }
    
    private func appendToLastMessage(role: String, content: String) {
        if messages.last?.role == role {
            var lastMsg = messages.removeLast()
            lastMsg.content += content
            messages.append(lastMsg)
        } else {
            messages.append(ChatMessage(role: role, content: content))
        }
    }
    
    func sendText(_ text: String) {
        ContextLogger.shared.log(source: .microphone, details: "User Query: \(text)")
        DispatchQueue.main.async { self.messages.append(ChatMessage(role: "user", content: text)) }
        sendJSON(["type": "input_audio_buffer.commit"])
        let itemEvent: [String: Any] = [
            "type": "conversation.item.create",
            "item": [ "type": "message", "role": "user", "content": [ ["type": "input_text", "text": text] ] ]
        ]
        sendJSON(itemEvent)
        sendJSON(["type": "response.create"])
    }
    
    // --- SCREEN HANDLING ---
    
    private func analyzeScreen(base64Image: String) {
        ContextLogger.shared.log(source: .screen, details: "Analyzing Frame (Size: \(base64Image.count) chars)")
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "gpt-5.2",
            "messages": [
                [ "role": "user", "content": [ ["type": "text", "text": "Describe screen content briefly."], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]] ] ]
            ],
            "max_tokens": 100
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = choices.first?["message"] as? [String: Any],
                  let desc = content["content"] as? String else { return }
            
            ContextLogger.shared.log(source: .screen, details: "Analysis Result: \(desc)")
            
            let ctxEvent: [String: Any] = [
                "type": "conversation.item.create",
                "item": [ "type": "message", "role": "user", "content": [ ["type": "input_text", "text": "System Context Update: \(desc)"] ] ]
            ]
            self?.sendJSON(ctxEvent)
        }.resume()
    }
    
    // --- CHANNEL 1: MICROPHONE ---
    
    private func processMicAudio(_ buffer: CMSampleBuffer) {
        guard let data = AudioUtils.convertBuffer(buffer, isSystem: false) else { return }
        let rms = AudioUtils.calculateRMS(data: data)
        DispatchQueue.main.async { self.micLevel = CGFloat(max(0, (rms + 50) / 50)) }
        
        // Log Logic
        // ContextLogger.shared.log(source: .microphone, details: "Buffer \(data.count) bytes, RMS: \(rms)")
        
        // Send Logic
        if isConnected {
             let event: [String: Any] = ["type": "input_audio_buffer.append", "audio": data.base64EncodedString()]
             sendJSON(event)
        }
    }
    
    // --- CHANNEL 2: SYSTEM AUDIO ---
    
    private func processSystemAudio(_ buffer: CMSampleBuffer) {
        // System audio often comes as Float32 stereo, convert to Int16 Mono 24kHz for OpenAI
        guard let data = AudioUtils.convertBuffer(buffer, isSystem: true) else { return }
        let rms = AudioUtils.calculateRMS(data: data)
        DispatchQueue.main.async { self.sysLevel = CGFloat(max(0, (rms + 50) / 50)) }
        
        // Log Logic
        // ContextLogger.shared.log(source: .systemAudio, details: "Buffer \(data.count) bytes, RMS: \(rms)")

        // Send Logic (Mixed into the same connection for Copilot awareness)
        if isConnected {
             let event: [String: Any] = ["type": "input_audio_buffer.append", "audio": data.base64EncodedString()]
             sendJSON(event)
        }
    }
    
    // --- SETUP & DELEGATES ---
    
    private func setupMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: configureMic()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { granted in if granted { self.configureMic() } }
        default: break
        }
    }
    
    private func configureMic() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        if micSession.canAddInput(input) { micSession.addInput(input) }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: processingQueue)
        if micSession.canAddOutput(output) { micSession.addOutput(output) }
        DispatchQueue.global().async { self.micSession.startRunning(); ContextLogger.shared.log(source: .microphone, details: "Active") }
    }
    
    private func setupSystemContext() async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return }
            let excluded = content.applications.filter { app in app.bundleIdentifier == Bundle.main.bundleIdentifier }
            
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            
            let config = SCStreamConfiguration()
            config.width = 1920
            config.height = 1080
            config.capturesAudio = true // ENABLE SYSTEM AUDIO CHANNEL
            config.excludesCurrentProcessAudio = true // Prevent echo loop
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            
            stream = SCStream(filter: filter, configuration: config, delegate: nil)
            
            // Add Output for both Screen and Audio
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
            
            try await stream?.startCapture()
            ContextLogger.shared.log(source: .systemAudio, details: "Capture Active")
            ContextLogger.shared.log(source: .screen, details: "Capture Active")
        } catch { print("SCK Error: \(error)") }
    }
    
    // DELEGATE 1: MICROPHONE (AVCapture)
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { 
        processMicAudio(sampleBuffer) 
    }
    
    // DELEGATE 2: SYSTEM (ScreenCaptureKit)
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { 
            let now = Date()
            guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
            lastFrameTime = now
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                if let base64 = VideoUtils.sampleBufferToJPEG(buffer: sampleBuffer) { self?.analyzeScreen(base64Image: base64) }
            }
        } else if type == .audio {
            // CHANNEL 2 HANDLING
            processSystemAudio(sampleBuffer)
        }
    }
}
