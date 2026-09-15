import SwiftUI

/// Small confirmation panel that can be overlaid on LocalDevVPN's existing
/// ContentView. It prevents a random web page from silently driving the public
/// `localdevvpn://` URL scheme.
struct WLOCBridgeApprovalView: View {
    @ObservedObject var host: WLOCLocalDevVPNBridgeHost

    var body: some View {
        Group {
            if let pending = host.pending {
                VStack(alignment: .leading, spacing: 12) {
                    Text("WLOC request")
                        .font(.headline)
                    Text(pending.summary)
                        .font(.subheadline)
                    HStack {
                        Button("Cancel", role: .cancel) {
                            host.reject()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Allow") {
                            host.approve()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
                .shadow(radius: 8)
            } else if pairingNeedsGuidance {
                pairingGuidance
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
                    .shadow(radius: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: host.pending != nil)
    }

    private var pairingNeedsGuidance: Bool {
        switch host.pairingState {
        case .publishing, .waitingForSettings, .showingPIN:
            true
        case .idle, .completed, .failed:
            false
        }
    }

    @ViewBuilder
    private var pairingGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pair this iPhone")
                .font(.headline)

            switch host.pairingState {
            case .publishing:
                Text("Preparing the local Remote Pairing service…")
            case .waitingForSettings:
                Text("Open Settings → Privacy & Security → Developer Mode → Pair with Host, then choose WLOC.")
            case .showingPIN(let pin):
                Text("Pairing code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pin)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            case .idle, .completed, .failed:
                EmptyView()
            }

            if !host.diagnostic.isEmpty {
                Text(host.diagnostic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
