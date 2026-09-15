import Foundation

struct WLOCPairingMaterial: Sendable {
    let record: Data
    let hostAltIRK: Data?
}

enum WLOCPairingUIState: Equatable, Sendable {
    case idle
    case publishing
    case waitingForSettings
    case showingPIN(String)
    case completed
    case failed
}

/// Swift orchestration for `wloc_pairing_session_run`.
///
/// Required Info.plist entries in the LocalDevVPN host app:
/// - NSLocalNetworkUsageDescription
/// - NSBonjourServices: `_remotepairing-pairable-host._tcp`, `_remotepairing._tcp`
@MainActor
final class WLOCNativePairingController: NSObject, NetServiceDelegate {
    var onStateChange: ((WLOCPairingUIState) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private(set) var state: WLOCPairingUIState = .idle {
        didSet { onStateChange?(state) }
    }

    private var publisher: NetService?
    private var activeSession: OpaquePointer?
    private var continuation: CheckedContinuation<WLOCPairingMaterial, Error>?
    private var runID: UUID?

    func pair() async throws -> WLOCPairingMaterial {
        guard activeSession == nil, continuation == nil else {
            throw WLOCNativePairingError.alreadyRunning
        }
        guard let session = wloc_pairing_session_create() else {
            throw WLOCNativePairingError.engineUnavailable
        }

        let id = UUID()
        runID = id
        activeSession = session
        state = .publishing

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let context = Unmanaged.passUnretained(self).toOpaque()
            let sessionBits = UInt(bitPattern: session)
            let contextBits = UInt(bitPattern: context)

            DispatchQueue.global(qos: .userInitiated).async {
                guard
                    let session = OpaquePointer(bitPattern: sessionBits),
                    let context = UnsafeMutableRawPointer(bitPattern: contextBits)
                else { return }

                var result = WLOCPairingResult()
                let returnCode = "WLOC".withCString { hostName in
                    "Mac17,7".withCString { hostModel in
                        wloc_pairing_session_run(
                            session,
                            hostName,
                            hostModel,
                            wlocPairingReadyCallback,
                            wlocPairingPinCallback,
                            context,
                            &result
                        )
                    }
                }

                let material: WLOCPairingMaterial?
                let errorText: String?
                if returnCode == 0,
                   let recordPointer = result.pairing_record,
                   result.pairing_record_length > 0 {
                    let record = Data(bytes: recordPointer, count: result.pairing_record_length)
                    let altIRK: Data?
                    if let irkPointer = result.host_alt_irk, result.host_alt_irk_length > 0 {
                        altIRK = Data(bytes: irkPointer, count: result.host_alt_irk_length)
                    } else {
                        altIRK = nil
                    }
                    material = WLOCPairingMaterial(record: record, hostAltIRK: altIRK)
                    errorText = nil
                } else {
                    material = nil
                    errorText = result.error_message.map { String(cString: $0) }
                }
                wloc_pairing_result_destroy(&result)

                DispatchQueue.main.async {
                    let controller = Unmanaged<WLOCNativePairingController>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    controller.finish(
                        id: id,
                        session: session,
                        material: material,
                        errorText: errorText
                    )
                }
            }
        }
    }

    func cancel() {
        if let activeSession {
            wloc_pairing_session_cancel(activeSession)
        }
        stopPublishing()
    }

    fileprivate func publish(
        serviceIdentifier: String,
        port: UInt16,
        txtRecords: [String: Data]
    ) {
        guard activeSession != nil else { return }
        stopPublishing()

        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceIdentifier,
            port: Int32(port)
        )
        service.includesPeerToPeer = true
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: txtRecords))
        service.schedule(in: .main, forMode: .common)
        service.publish()
        publisher = service
        state = .publishing
    }

    fileprivate func presentPIN(_ pin: String) {
        guard activeSession != nil else { return }
        state = .showingPIN(pin)
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor in
            guard self.publisher === sender else { return }
            self.state = .waitingForSettings
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotPublish errorDict: [String: NSNumber]
    ) {
        Task { @MainActor in
            guard self.publisher === sender else { return }
            self.onDiagnostic?("RemotePairing Bonjour publish failed: \(errorDict)")
            self.cancel()
        }
    }

    private func finish(
        id: UUID,
        session: OpaquePointer,
        material: WLOCPairingMaterial?,
        errorText: String?
    ) {
        guard runID == id else {
            wloc_pairing_session_destroy(session)
            return
        }

        runID = nil
        activeSession = nil
        stopPublishing()
        wloc_pairing_session_destroy(session)

        guard let continuation else { return }
        self.continuation = nil

        if let material {
            state = .completed
            continuation.resume(returning: material)
        } else {
            state = .failed
            let message = errorText?.isEmpty == false ? errorText! : "Remote pairing failed."
            onDiagnostic?(message)
            continuation.resume(throwing: WLOCNativePairingError.failed)
        }
    }

    private func stopPublishing() {
        publisher?.stop()
        publisher?.remove(from: .main, forMode: .common)
        publisher?.delegate = nil
        publisher = nil
    }
}

enum WLOCNativePairingError: Error {
    case alreadyRunning
    case engineUnavailable
    case failed
}

private let wlocPairingReadyCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    UInt16,
    UnsafePointer<UnsafePointer<CChar>?>?,
    UnsafePointer<UnsafePointer<CChar>?>?,
    Int
) -> Void = { context, identifier, port, keys, values, count in
    guard
        let context,
        let identifier,
        let keys,
        let values
    else { return }

    var records: [String: Data] = [:]
    for index in 0..<count {
        guard let key = keys[index], let value = values[index] else { continue }
        records[String(cString: key)] = Data(String(cString: value).utf8)
    }

    let identifierValue = String(cString: identifier)
    let contextBits = UInt(bitPattern: context)
    DispatchQueue.main.async {
        guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
        let controller = Unmanaged<WLOCNativePairingController>
            .fromOpaque(context)
            .takeUnretainedValue()
        controller.publish(
            serviceIdentifier: identifierValue,
            port: port,
            txtRecords: records
        )
    }
}

private let wlocPairingPinCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?
) -> Void = { context, pin in
    guard let context, let pin else { return }
    let pinValue = String(cString: pin)
    let contextBits = UInt(bitPattern: context)
    DispatchQueue.main.async {
        guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
        let controller = Unmanaged<WLOCNativePairingController>
            .fromOpaque(context)
            .takeUnretainedValue()
        controller.presentPIN(pinValue)
    }
}
