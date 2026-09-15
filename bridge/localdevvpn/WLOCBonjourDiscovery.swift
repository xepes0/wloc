import Foundation

struct WLOCRemotePairingService: Equatable, Sendable {
    let name: String
    let port: UInt16
    let identifier: String
    let authTag: String
}

/// Discovers the iPhone's `_remotepairing._tcp.` announcement exposed through
/// the LocalDevVPN self-tunnel. Identity is still verified by the native engine
/// against the saved pairing record; Bonjour data is never trusted by itself.
@MainActor
final class WLOCBonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    enum DiscoveryError: Error {
        case alreadyRunning
        case timedOut
        case browserFailed
    }

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolved: [WLOCRemotePairingService] = []
    private var continuation: CheckedContinuation<[WLOCRemotePairingService], Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finishing = false

    override init() {
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func discover(timeout seconds: TimeInterval = 8) async throws -> [WLOCRemotePairingService] {
        guard continuation == nil else { throw DiscoveryError.alreadyRunning }
        resetState()
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

        timeoutTask = Task { @MainActor [weak self] in
            let duration = max(1, seconds)
            try? await Task.sleep(for: .seconds(duration))
            guard let self, self.continuation != nil else { return }
            if self.resolved.isEmpty {
                self.finish(.failure(DiscoveryError.timedOut))
            } else {
                self.finish(.success(self.deduplicatedResolved()))
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        guard continuation != nil else { return }
        finish(.failure(CancellationError()))
    }

    private func resetState() {
        finishing = false
        browser.stop()
        timeoutTask?.cancel()
        timeoutTask = nil
        for service in services {
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }
        services.removeAll()
        resolved.removeAll()
    }

    private func deduplicatedResolved() -> [WLOCRemotePairingService] {
        var seen = Set<String>()
        return resolved.filter { candidate in
            let key = "\(candidate.identifier)|\(candidate.authTag)|\(candidate.port)"
            return seen.insert(key).inserted
        }
    }

    private func finish(_ result: Result<[WLOCRemotePairingService], Error>) {
        guard !finishing, let continuation else { return }
        finishing = true
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        browser.stop()
        for service in services {
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }
        services.removeAll()
        continuation.resume(with: result)
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            guard self.continuation != nil else { return }
            service.delegate = self
            service.includesPeerToPeer = true
            service.schedule(in: .main, forMode: .common)
            self.services.append(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        Task { @MainActor in
            self.finish(.failure(DiscoveryError.browserFailed))
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            guard self.continuation != nil else { return }
            guard sender.port > 0, sender.port <= Int(UInt16.max) else { return }
            guard let txtData = sender.txtRecordData() else { return }
            let txt = NetService.dictionary(fromTXTRecord: txtData)
            guard
                let identifierData = txt["identifier"],
                let authTagData = txt["authTag"]
            else { return }

            let identifier = String(decoding: identifierData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let authTag = String(decoding: authTagData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, !authTag.isEmpty else { return }

            self.resolved.append(
                WLOCRemotePairingService(
                    name: sender.name,
                    port: UInt16(sender.port),
                    identifier: identifier,
                    authTag: authTag
                )
            )

            // A single valid candidate is usually enough on the self-tunnel, but
            // wait a short grace period so simultaneous stale announcements can
            // also be collected and rejected by the native pairing check.
            if self.resolved.count == 1 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard let self, self.continuation != nil, !self.resolved.isEmpty else { return }
                    self.finish(.success(self.deduplicatedResolved()))
                }
            }
        }
    }
}
