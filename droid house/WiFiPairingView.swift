import SwiftUI

/// Pairs the Mac with the DroidHouse companion over Wi-Fi, so the phone works
/// with no adb, USB cable or developer options at all.
struct WiFiPairingSection: View {
    @ObservedObject var adbService: ADBService
    @ObservedObject private var store = WiFiCompanionStore.shared

    @State private var host = ""
    @State private var code = ""
    @State private var isPairing = false
    @State private var error: String?
    @State private var success: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label("DroidHouse over Wi-Fi", systemImage: "wifi")
                    .font(.headline)
                Text("No adb needed. Open DroidHouse on the phone. It shows its address and a 6-digit pairing code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.paired.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paired")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(store.paired) { phone in
                        pairedRow(phone)
                    }
                }
            }

            let unpaired = store.discovered.filter { found in !store.paired.contains { $0.id == found.id } }
            if !unpaired.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Found on this network")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(unpaired) { phone in
                        Button {
                            host = phone.host
                            error = nil
                        } label: {
                            HStack {
                                Image(systemName: "iphone.gen3")
                                Text(phone.model)
                                Spacer()
                                Text(phone.host)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .background(host == phone.host ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            } else if store.paired.isEmpty {
                Text("Searching the network… If nothing appears, type the address the phone shows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("Phone address (192.168.x.x)", text: $host)
                    .textFieldStyle(.roundedBorder)
                TextField("Code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit(pair)
            }
            .disabled(isPairing)

            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let success {
                    Label(success, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(isPairing ? "Pairing…" : "Pair", action: pair)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                              || code.filter(\.isNumber).count != 6
                              || isPairing)
            }
        }
        .onAppear { store.start() }
    }

    private func pairedRow(_ phone: PairedPhone) -> some View {
        let online = store.reachable.contains(phone.id)
        return HStack {
            Circle()
                .fill(online ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(phone.model)
            Spacer()
            Text(online ? phone.host : "Offline")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Forget") {
                store.forget(phone)
                Task { await adbService.detectDevices() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func pair() {
        guard !isPairing else { return }
        isPairing = true
        error = nil
        success = nil

        Task {
            defer { isPairing = false }
            do {
                let phone = try await store.pair(host: host, code: code)
                code = ""
                success = "Paired with \(phone.model)"
                await adbService.detectDevices()
                if let device = adbService.connectedDevices.first(where: { $0.id == phone.deviceID }) {
                    adbService.selectedDevice = device
                    await adbService.listFiles(path: "/sdcard")
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
