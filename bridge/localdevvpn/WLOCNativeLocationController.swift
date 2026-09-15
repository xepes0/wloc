import Foundation

@MainActor
final class WLOCNativeLocationController {
    enum LocationError: Error {
        case engineUnavailable
        case emptyPairingRecord
        case startFailed
        case updateFailed
        case stopFailed
        case busy
        case notActive
    }

    var onDiagnostic: ((String) -> Void)?
    var onActiveChange: ((Bool) -> Void)?

    private(set) var isActive = false {
        didSet {
            guard oldValue != isActive else { return }
            onActiveChange?(isActive)
        }
    }

    private var activeSession: OpaquePointer?
    private var runID: UUID?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var cancellationRequested = false

    func updateLocation(latitude: Double, longitude: Double) throws {
        guard let activeSession, isActive else { throw LocationError.notActive }
        let result = wloc_location_session_update(activeSession, latitude, longitude)
        guard result == 0 else { throw LocationError.updateFailed }
    }

    func startLocation(
        pairingRecord: Data,
        service: WLOCRemotePairingService,
        latitude: Double,
        longitude: Double
    ) async throws {
        guard activeSession == nil, startContinuation == nil else {
            throw LocationError.busy
        }
        guard !pairingRecord.isEmpty else {
            throw LocationError.emptyPairingRecord
        }
        guard let session = wloc_location_session_create() else {
            throw LocationError.engineUnavailable
        }

        let id = UUID()
        runID = id
        activeSession = session
        cancellationRequested = false
        let sessionBits = UInt(bitPattern: session)
        let contextBits = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        let record = pairingRecord

        return try await withCheckedThrowingContinuation { continuation in
            self.startContinuation = continuation

            DispatchQueue.global(qos: .userInitiated).async {
                guard
                    let session = OpaquePointer(bitPattern: sessionBits),
                    let context = UnsafeMutableRawPointer(bitPattern: contextBits)
                else { return }

                var nativeResult = WLOCLocationResult()
                let returnCode: Int32 = record.withUnsafeBytes { rawBuffer in
                    guard let recordBase = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return 2
                    }
                    return "10.7.0.1".withCString { peerAddress in
                        service.identifier.withCString { identifier in
                            service.authTag.withCString { authTag in
                                wloc_location_session_run(
                                    session,
                                    recordBase,
                                    record.count,
                                    peerAddress,
                                    service.port,
                                    identifier,
                                    authTag,
                                    latitude,
                                    longitude,
                                    wlocLocationStartedCallback,
                                    context,
                                    &nativeResult
                                )
                            }
                        }
                    }
                }

                let errorText = nativeResult.error_message.map { String(cString: $0) }
                wloc_location_result_destroy(&nativeResult)

                DispatchQueue.main.async {
                    guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
                    let controller = Unmanaged<WLOCNativeLocationController>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    controller.finished(
                        id: id,
                        session: session,
                        returnCode: returnCode,
                        errorText: errorText
                    )
                }
            }
        }
    }

    func clearLocation() async throws {
        guard let activeSession else {
            isActive = false
            return
        }
        guard stopContinuation == nil else { throw LocationError.busy }

        cancellationRequested = true
        return try await withCheckedThrowingContinuation { continuation in
            self.stopContinuation = continuation
            wloc_location_session_cancel(activeSession)
        }
    }

    func forceCancel() {
        cancellationRequested = true
        if let activeSession {
            wloc_location_session_cancel(activeSession)
        }
    }

    fileprivate func nativeDidStart() {
        guard activeSession != nil else { return }
        isActive = true
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume()
        }
    }

    private func finished(
        id: UUID,
        session: OpaquePointer,
        returnCode: Int32,
        errorText: String?
    ) {
        guard runID == id else {
            wloc_location_session_destroy(session)
            return
        }

        let wasCancellation = cancellationRequested
        cancellationRequested = false
        runID = nil
        activeSession = nil
        isActive = false
        wloc_location_session_destroy(session)

        let nativeSucceeded = returnCode == 0
        if let startContinuation {
            self.startContinuation = nil
            if let errorText, !errorText.isEmpty { onDiagnostic?(errorText) }
            // A zero return before the started callback is still a failed start:
            // the native callback is the only proof LocationSimulation.set() ran.
            startContinuation.resume(throwing: LocationError.startFailed)
        }

        if let stopContinuation {
            self.stopContinuation = nil
            if nativeSucceeded && wasCancellation {
                stopContinuation.resume()
            } else {
                if let errorText, !errorText.isEmpty { onDiagnostic?(errorText) }
                stopContinuation.resume(throwing: LocationError.stopFailed)
            }
        } else if !wasCancellation && !nativeSucceeded {
            if let errorText, !errorText.isEmpty { onDiagnostic?(errorText) }
        }
    }
}

private let wlocLocationStartedCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    let contextBits = UInt(bitPattern: context)
    DispatchQueue.main.async {
        guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
        let controller = Unmanaged<WLOCNativeLocationController>
            .fromOpaque(context)
            .takeUnretainedValue()
        controller.nativeDidStart()
    }
}
