import AppKit
import SwiftUI

/// A nonactivating result panel: no focus stealing and no automatic clipboard write.
@MainActor final class TranscriptCopyOverlay {
    private final class State: ObservableObject {
        @Published var text = ""
        @Published var copied = false
    }
    private struct Content: View {
        @ObservedObject var state: State
        var copy: () -> Void
        var hover: (Bool) -> Void
        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.copied ? "Copied" : "Transcript ready to copy").font(.headline)
                    Text(String(state.text.prefix(120))).font(.caption).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: copy) { Image(systemName: state.copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy transcript").accessibilityLabel("Copy transcript")
            }.padding(16).frame(width: 340, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle()).onHover(perform: hover)
        }
    }
    private let state = State()
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var hovering = false
    func show(text: String) {
        state.text = text; state.copied = false; hovering = false
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false; window.backgroundColor = .clear
            window.hasShadow = true; window.hidesOnDeactivate = false
            window.contentView = NSHostingView(rootView: Content(state: state, copy: { [weak self] in
                guard let self else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                self.state.copied = pasteboard.setString(self.state.text, forType: .string)
            }, hover: { [weak self] inside in
                self?.hovering = inside
                if inside { self?.dismissal?.cancel() } else { self?.scheduleDismissal() }
            }))
            panel = window
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 186, y: screen.visibleFrame.minY + 38))
        }
        panel?.orderFrontRegardless()
        scheduleDismissal()
    }
    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, !self.hovering else { return }
            self.panel?.orderOut(nil)
        }
    }
    func hide() { dismissal?.cancel(); dismissal = nil; panel?.orderOut(nil) }
}
