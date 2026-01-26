import SwiftUI

struct AudioVisualizer: View {
    var level: CGFloat
    var color: Color
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1).fill(color)
                    .frame(width: 3, height: 6 + (level * CGFloat(i + 1) * 6))
            }
        }
    }
}

struct SecureChatView: View {
    @StateObject var context = ContextManager()
    @State private var inputText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("V22: DUAL CHANNEL").font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundColor(.white.opacity(0.8))
                Spacer()
                
                if context.isConnected { 
                    HStack(spacing: 4) {
                        Text("MIC").font(.system(size: 8, weight: .bold)).foregroundColor(.blue)
                        AudioVisualizer(level: context.micLevel, color: .blue)
                    }
                    HStack(spacing: 4) {
                        Text("SYS").font(.system(size: 8, weight: .bold)).foregroundColor(.purple)
                        AudioVisualizer(level: context.sysLevel, color: .purple)
                    }
                } else { 
                    Text("OFFLINE").font(.caption2).foregroundColor(.red)
                }
                
                Button(action: { Task { if context.isRunning { context.stopSession() } else { await context.startSession() } } }) {
                    Image(systemName: context.isRunning ? "power.circle.fill" : "play.circle.fill").font(.system(size: 16)).foregroundColor(context.isRunning ? .red : .green)
                }.buttonStyle(PlainButtonStyle())
            }.padding(10).background(Color.black.opacity(0.6))
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(context.messages) { msg in
                            HStack {
                                if msg.role == "user" { Spacer() }
                                Text(msg.content)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(8)
                                    .background(msg.role == "user" ? Color.blue.opacity(0.6) : Color.white.opacity(0.1))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                    .fixedSize(horizontal: false, vertical: true)
                                if msg.role == "ai" { Spacer() }
                            }
                            .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: context.messages) { _ in 
                    if let last = context.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            
            Divider().background(Color.white.opacity(0.2))
            HStack(spacing: 10) {
                TextField("Ask AI...", text: $inputText).textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(6)
                    .onSubmit { sendMessage() }
                
                Button(action: sendMessage) { 
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue) 
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(inputText.isEmpty)
            }.padding(10).background(Color.black.opacity(0.4))
        }
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
    
    private func sendMessage() { 
        guard !inputText.isEmpty else { return }
        context.sendText(inputText)
        inputText = "" 
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView { let view = NSVisualEffectView(); view.material = material; view.blendingMode = blendingMode; view.state = .active; return view }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
