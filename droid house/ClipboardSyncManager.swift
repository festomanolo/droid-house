import Foundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class ClipboardSyncManager: ObservableObject {
    static let shared = ClipboardSyncManager()
    
    @Published var isAutoSyncEnabled: Bool = true
    @Published var clipboardHistory: [ClipboardItem] = []
    @Published var lastSyncedText: String = ""
    @Published var isSyncing: Bool = false
    
    /// Timestamp of the last value the phone reported, so we only adopt genuinely
    /// newer text rather than re-applying the same clip forever.
    @Published private(set) var lastAndroidTimestamp: Int64 = 0

    /// What the phone says about its own capture route, surfaced so the UI can
    /// explain why a background copy on the device may not arrive on its own.
    @Published private(set) var androidSource: String = "none"

    private var changeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var androidPollTask: Task<Void, Never>?
    private let companionSync = CompanionSync.shared

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkMacClipboard()
            }
        }
        startAndroidPolling()
    }

    /// Polls the phone for clipboard changes.
    ///
    /// Without this the sync was only ever one-way in practice: the Mac pushed
    /// on every local copy, but nothing pulled, so anything captured on the
    /// phone sat on the bridge until the user pressed "Pull from Android".
    private func startAndroidPolling() {
        androidPollTask?.cancel()
        androidPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard self.isAutoSyncEnabled else { continue }
                await self.pollAndroidClipboard()
            }
        }
    }

    /// Adopts the phone's clipboard when it reports something newer than what
    /// we last saw. The timestamp guard is what stops this from fighting the
    /// Mac→phone direction in a loop.
    private func pollAndroidClipboard() async {
        guard let snapshot = await companionSync.androidClipboardSnapshot() else { return }

        androidSource = snapshot.source

        guard snapshot.timestamp > lastAndroidTimestamp else { return }
        lastAndroidTimestamp = snapshot.timestamp

        let text = snapshot.text
        guard !text.isEmpty, text != lastSyncedText else { return }

        // Values that originated on this Mac come back labelled "mac"; adopting
        // them would just echo our own copy back at us.
        guard snapshot.source != "mac" else {
            lastSyncedText = text
            return
        }

        lastSyncedText = text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        changeCount = NSPasteboard.general.changeCount

        clipboardHistory.insert(
            ClipboardItem(id: UUID(), text: text, timestamp: Date(), source: .android),
            at: 0
        )
        if clipboardHistory.count > 100 { clipboardHistory.removeLast() }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        androidPollTask?.cancel()
        androidPollTask = nil
    }
    
    private func checkMacClipboard() async {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != changeCount else { return }
        changeCount = currentCount
        
        guard isAutoSyncEnabled,
              let newText = NSPasteboard.general.string(forType: .string),
              !newText.isEmpty,
              newText != lastSyncedText else { return }
        
        lastSyncedText = newText
        let item = ClipboardItem(id: UUID(), text: newText, timestamp: Date(), source: .mac)
        clipboardHistory.insert(item, at: 0)
        
        do {
            try await companionSync.setAndroidClipboard(text: newText)
        } catch {
            print("Failed to sync clipboard to Android: \(error.localizedDescription)")
        }
    }
    
    func pullFromAndroid() async {
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            if let text = try await companionSync.getAndroidClipboard(), !text.isEmpty, text != lastSyncedText {
                lastSyncedText = text
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.changeCount = NSPasteboard.general.changeCount
                
                let item = ClipboardItem(id: UUID(), text: text, timestamp: Date(), source: .android)
                clipboardHistory.insert(item, at: 0)
            }
        } catch {
            print("Failed to pull clipboard from Android: \(error.localizedDescription)")
        }
    }
    
    func pushToAndroid(_ text: String) async {
        isSyncing = true
        defer { isSyncing = false }
        
        lastSyncedText = text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        self.changeCount = NSPasteboard.general.changeCount
        
        do {
            try await companionSync.setAndroidClipboard(text: text)
        } catch {
            print("Failed to push clipboard to Android: \(error.localizedDescription)")
        }
    }
}
