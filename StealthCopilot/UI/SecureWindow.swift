import Cocoa
import SwiftUI
class SecureWindowController: NSWindowController {
    convenience init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 500), styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.sharingType = .none; panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isOpaque = false; panel.backgroundColor = .clear; panel.titlebarAppearsTransparent = true; panel.titleVisibility = .hidden; panel.isMovableByWindowBackground = true
        let hostingView = NSHostingView(rootView: SecureChatView()); panel.contentView = hostingView; self.init(window: panel)
    }
}
