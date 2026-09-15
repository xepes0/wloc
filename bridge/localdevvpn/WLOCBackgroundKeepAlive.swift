import CoreLocation
import Foundation

/// Keeps the LocalDevVPN host app runnable while a DVT LocationSimulation
/// session is active. CoreLocation is *not* used as the simulated-location
/// source and received coordinates are never stored or forwarded.
@MainActor
final class WLOCBackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    enum KeepAliveError: Error {
        case servicesDisabled
        case denied
        case restricted
        case authorizationTimedOut
    }

    var onDiagnostic: ((String) -> Void)?

    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<Void, Error>?
    private var authorizationTimeout: Task<Void, Never>?
    private(set) var isRunning = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func prepare() async throws {
        guard CLLocationManager.locationServicesEnabled() else {
            throw KeepAliveError.servicesDisabled
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            startUpdatesIfNeeded()
            return
        case .denied:
            throw KeepAliveError.denied
        case .restricted:
            throw KeepAliveError.restricted
        case .notDetermined:
            try await requestAuthorization()
            startUpdatesIfNeeded()
        @unknown default:
            throw KeepAliveError.denied
        }
    }

    func stop() {
        authorizationTimeout?.cancel()
        authorizationTimeout = nil
        if let continuation = authorizationContinuation {
            authorizationContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
    }

    private func requestAuthorization() async throws {
        guard authorizationContinuation == nil else { return }
        return try await withCheckedThrowingContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
            authorizationTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, let continuation = self.authorizationContinuation else { return }
                self.authorizationContinuation = nil
                self.authorizationTimeout = nil
                continuation.resume(throwing: KeepAliveError.authorizationTimedOut)
            }
        }
    }

    private func startUpdatesIfNeeded() {
        guard !isRunning else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isRunning = true
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let continuation = authorizationContinuation else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationContinuation = nil
            authorizationTimeout?.cancel()
            authorizationTimeout = nil
            continuation.resume()
        case .denied:
            authorizationContinuation = nil
            authorizationTimeout?.cancel()
            authorizationTimeout = nil
            continuation.resume(throwing: KeepAliveError.denied)
        case .restricted:
            authorizationContinuation = nil
            authorizationTimeout?.cancel()
            authorizationTimeout = nil
            continuation.resume(throwing: KeepAliveError.restricted)
        case .notDetermined:
            break
        @unknown default:
            authorizationContinuation = nil
            authorizationTimeout?.cancel()
            authorizationTimeout = nil
            continuation.resume(throwing: KeepAliveError.denied)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Intentionally empty. DVT LocationSimulation is the only control source.
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code != .locationUnknown {
            onDiagnostic?("WLOC background keepalive reported a CoreLocation error.")
        }
    }
}
