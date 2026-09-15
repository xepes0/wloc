import Foundation

@MainActor
protocol WLOCTunnelControlling: AnyObject {
    var wlocTunnelIsActive: Bool { get }
    func ensureWLOCTunnelActive() async throws
}

@MainActor
final class WLOCNativeExecutor: WLOCBridgeExecuting {
    enum ExecutorError: Error {
        case notPaired
        case noRemotePairingService
        case everyCandidateRejected
    }

    var onPairingStateChange: ((WLOCPairingUIState) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private let tunnel: WLOCTunnelControlling
    private let keychain: WLOCKeychainStore
    private let pairing = WLOCNativePairingController()
    private let discovery = WLOCBonjourDiscovery()
    private let location = WLOCNativeLocationController()

    init(
        tunnel: WLOCTunnelControlling,
        keychain: WLOCKeychainStore = WLOCKeychainStore()
    ) {
        self.tunnel = tunnel
        self.keychain = keychain

        pairing.onStateChange = { [weak self] state in
            self?.onPairingStateChange?(state)
        }
        pairing.onDiagnostic = { [weak self] message in
            self?.onDiagnostic?(message)
        }
        location.onDiagnostic = { [weak self] message in
            self?.onDiagnostic?(message)
        }
    }

    func pair() async throws {
        let material = try await pairing.pair()
        try keychain.savePairing(
            record: material.record,
            hostAltIRK: material.hostAltIRK
        )
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        guard let pairingRecord = try keychain.loadPairingRecord(), !pairingRecord.isEmpty else {
            throw ExecutorError.notPaired
        }

        // Active DVT sessions support coordinate replacement without another
        // Bonjour discovery, pair verify or secure-tunnel setup.
        if location.isActive {
            try location.updateLocation(latitude: latitude, longitude: longitude)
            return
        }

        try await tunnel.ensureWLOCTunnelActive()
        let candidates = try await discovery.discover()
        guard !candidates.isEmpty else {
            throw ExecutorError.noRemotePairingService
        }

        // Each candidate is cryptographically checked by the native engine via
        // PairingRecord.alt_irk + identifier/authTag before pair verify. Stale or
        // foreign Bonjour announcements therefore fail before DVT opens.
        var lastError: Error?
        for candidate in candidates {
            do {
                try await location.startLocation(
                    pairingRecord: pairingRecord,
                    service: candidate,
                    latitude: latitude,
                    longitude: longitude
                )
                return
            } catch {
                lastError = error
                onDiagnostic?("Rejected RemotePairing candidate \(candidate.name).")
            }
        }

        if let lastError {
            onDiagnostic?("No discovered RemotePairing service matched the saved pairing: \(lastError)")
        }
        throw ExecutorError.everyCandidateRejected
    }

    func clearLocation() async throws {
        try await location.clearLocation()
    }

    func statusCode() async -> String {
        if location.isActive { return "session_active" }
        if !keychain.hasPairingRecord { return "not_paired" }
        if !tunnel.wlocTunnelIsActive { return "tunnel_off" }
        return "ready"
    }

    func resetPairing() throws {
        pairing.cancel()
        location.forceCancel()
        try keychain.resetPairing()
    }
}
