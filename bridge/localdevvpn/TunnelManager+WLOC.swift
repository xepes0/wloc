import Foundation

/// Copy this file into the LocalDevVPN app target together with the other WLOC
/// bridge Swift files. It intentionally uses LocalDevVPN's existing
/// `TunnelManager` instead of creating a second VPN configuration.
@MainActor
extension TunnelManager: WLOCTunnelControlling {
    enum WLOCTunnelError: Error {
        case startTimedOut
    }

    var wlocTunnelIsActive: Bool {
        tunnelStatus == .connected
    }

    func ensureWLOCTunnelActive() async throws {
        if (try? await isVPNActive()) == true, tunnelStatus == .connected {
            return
        }

        startVPN()

        // The VPN configuration/start path is asynchronous. Poll the manager's
        // actual status instead of assuming `startVPN()` means 10.7.0.1 is ready.
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            _ = try? await isVPNActive()
            if tunnelStatus == .connected { return }
        }

        throw WLOCTunnelError.startTimedOut
    }
}
