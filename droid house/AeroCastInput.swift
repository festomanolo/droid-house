import SwiftUI
import AppKit

// MARK: - Raw AppKit input bridges
//
// SwiftUI on macOS has no scroll-wheel gesture and no way to take raw key
// events for a non-text view, so both are bridged from AppKit. Each installs a
// local event monitor rather than an overlay view, which keeps the video layer
// free of a hit-testing sibling that would swallow the drag gestures.

/// Delivers scroll-wheel deltas while `enabled` and the pointer is over the view.
struct ScrollWheelModifier: ViewModifier {
    let enabled: Bool
    let onScroll: (CGFloat) -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
            .onChange(of: enabled) { _, _ in
                remove()
                install()
            }
    }

    private func install() {
        guard enabled, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Precise deltas (trackpad) arrive far more frequently and much
            // smaller than a notched wheel; scale them up so both feel similar.
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY * 0.6
                : event.scrollingDeltaY * 6
            if abs(delta) > 0.5 { onScroll(delta) }
            return event
        }
    }

    private func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

extension View {
    func onScrollWheel(enabled: Bool, perform: @escaping (CGFloat) -> Void) -> some View {
        modifier(ScrollWheelModifier(enabled: enabled, onScroll: perform))
    }
}

/// Routes key presses to a handler while `enabled`.
///
/// Returning `nil` from the monitor swallows the event, which is what stops the
/// Mac from also acting on a keystroke meant for the phone (and stops the
/// system beep for keys with no local binding).
struct KeyCaptureModifier: ViewModifier {
    let enabled: Bool
    let onKey: (NSEvent) -> Bool

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
            .onChange(of: enabled) { _, _ in
                remove()
                install()
            }
    }

    private func install() {
        guard enabled, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKey(event) ? nil : event
        }
    }

    private func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

extension View {
    func captureKeys(enabled: Bool, perform: @escaping (NSEvent) -> Bool) -> some View {
        modifier(KeyCaptureModifier(enabled: enabled, onKey: perform))
    }
}
