import Combine
import Foundation

/// Glue object owned by LocalDevVPN's SwiftUI App scene.
/// It receives `localdevvpn://wloc/...` URLs, exposes a user-approval state to
/// SwiftUI, and owns the native executor for the lifetime of the app process.
@MainActor
final class WLOCLocalDevVPNBridgeHost: ObservableObject {
    @Published private(set) var pending: WLOCBridgeCoordinator.Pending?
    @Published private(set) var pairingState: WLOCPairingUIState = .idle
    @Published private(set) var diagnostic: String = ""

    private let executor: WLOCNativeExecutor
    private var coordinator: WLOCBridgeCoordinator!

    init(
        callbackHosts: Set<String> = ["wloc.xepesw.workers.dev"],
        tunnel: WLOCTunnelControlling = TunnelManager.shared
    ) {
        self.executor = WLOCNativeExecutor(tunnel: tunnel)
        self.coordinator = WLOCBridgeCoordinator(
            executor: executor,
            allowedCallbackHosts: callbackHosts
        )

        coordinator.onPendingChange = { [weak self] pending in
            self?.pending = pending
        }
        coordinator.onDiagnostic = { [weak self] message in
            self?.diagnostic = message
        }
        executor.onPairingStateChange = { [weak self] state in
            self?.pairingState = state
        }
        executor.onDiagnostic = { [weak self] message in
            self?.diagnostic = message
        }
    }

    /// Returns true when this URL belongs to WLOC. Existing LocalDevVPN
    /// enable/disable URLs should continue through the app's original handler.
    @discardableResult
    func handleURL(_ url: URL) -> Bool {
        guard
            url.scheme?.lowercased() == "localdevvpn",
            url.host?.lowercased() == "wloc"
        else { return false }

        coordinator.receive(url)
        return true
    }

    func approve() {
        coordinator.approvePendingRequest()
    }

    func reject() {
        coordinator.rejectPendingRequest()
    }

    func resetPairing() {
        do {
            try executor.resetPairing()
            diagnostic = "WLOC pairing reset."
        } catch {
            diagnostic = "Could not reset WLOC pairing."
        }
    }
}
