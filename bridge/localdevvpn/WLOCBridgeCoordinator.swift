import Foundation
import UIKit

/// Narrow interface between the URL bridge and the CoreDevice implementation.
/// Pairing records and CoreDevice identities never cross this boundary as URL data.
@MainActor
protocol WLOCBridgeExecuting: AnyObject {
    func pair() async throws
    func setLocation(latitude: Double, longitude: Double) async throws
    func clearLocation() async throws
    func statusCode() async -> String
}

/// A parsed deep link becomes a pending request first. The host app must present
/// it to the user and call `approvePendingRequest()` explicitly. This prevents an
/// arbitrary web page from silently changing system-wide simulated location just
/// because it knows the public `localdevvpn://` scheme.
@MainActor
final class WLOCBridgeCoordinator {
    struct Pending: Equatable {
        let request: WLOCBridgeRequest
        let summary: String
    }

    enum BridgeErrorCode: String {
        case rejected
        case notPaired = "not_paired"
        case pairingFailed = "pairing_failed"
        case localNetworkDenied = "local_network_denied"
        case tunnelFailed = "tunnel_failed"
        case serviceNotFound = "service_not_found"
        case pairVerifyFailed = "pair_verify_failed"
        case rsdFailed = "rsd_failed"
        case dvtFailed = "dvt_failed"
        case locationRejected = "location_rejected"
        case clearFailed = "clear_failed"
        case backgroundUnavailable = "background_unavailable"
        case internalError = "internal_error"
    }

    var onPendingChange: ((Pending?) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private(set) var pending: Pending? {
        didSet { onPendingChange?(pending) }
    }

    private weak var executor: WLOCBridgeExecuting?
    private let allowedCallbackHosts: Set<String>

    init(executor: WLOCBridgeExecuting, allowedCallbackHosts: Set<String>) {
        self.executor = executor
        self.allowedCallbackHosts = Set(allowedCallbackHosts.map { $0.lowercased() })
    }

    /// Call this from LocalDevVPN's existing `.onOpenURL` handler when the URL
    /// host is `wloc`. Parsing never performs a location-changing action.
    func receive(_ url: URL) {
        do {
            let request = try WLOCDeepLinkParser.parse(
                url,
                allowedCallbackHosts: allowedCallbackHosts
            )
            pending = Pending(request: request, summary: summary(for: request))
        } catch {
            onDiagnostic?("Rejected WLOC URL: \(error.localizedDescription)")
        }
    }

    /// The UI calls this only after explicit user approval.
    func approvePendingRequest() {
        guard let pending, let executor else { return }
        self.pending = nil

        Task { @MainActor in
            do {
                switch pending.request.operation {
                case .pair:
                    try await executor.pair()
                case .set:
                    guard
                        let latitude = pending.request.latitude,
                        let longitude = pending.request.longitude
                    else {
                        throw WLOCBridgeParseError.missingCoordinates
                    }
                    try await executor.setLocation(latitude: latitude, longitude: longitude)
                case .clear:
                    try await executor.clearLocation()
                case .status:
                    let code = await executor.statusCode()
                    await openCallback(for: pending.request, status: "ok", code: code)
                    return
                }

                await openCallback(for: pending.request, status: "ok", code: nil)
            } catch {
                // Do not put raw diagnostics in the callback URL. The production
                // executor should map known failures to one of the fixed codes.
                onDiagnostic?("WLOC operation failed: \(error.localizedDescription)")
                await openCallback(
                    for: pending.request,
                    status: "error",
                    code: BridgeErrorCode.internalError.rawValue
                )
            }
        }
    }

    func rejectPendingRequest() {
        guard let request = pending?.request else { return }
        pending = nil
        Task { @MainActor in
            await openCallback(
                for: request,
                status: "error",
                code: BridgeErrorCode.rejected.rawValue
            )
        }
    }

    private func summary(for request: WLOCBridgeRequest) -> String {
        switch request.operation {
        case .pair:
            return "WLOC wants to pair this iPhone for local CoreDevice control."
        case .set:
            let latitude = request.latitude ?? 0
            let longitude = request.longitude ?? 0
            return String(format: "WLOC wants to set the reported location to %.6f, %.6f.", latitude, longitude)
        case .clear:
            return "WLOC wants to stop location simulation and restore the real location."
        case .status:
            return "WLOC wants to read the local bridge status."
        }
    }

    private func openCallback(
        for request: WLOCBridgeRequest,
        status: String,
        code: String?
    ) async {
        guard let url = WLOCBridgeCallback.makeURL(for: request, status: status, code: code) else {
            onDiagnostic?("Could not construct WLOC callback URL.")
            return
        }
        await UIApplication.shared.open(url)
    }
}
