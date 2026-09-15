import Foundation

/// Browser -> LocalDevVPN contract used by WLOC iOS 27.
///
/// URL shapes:
///   localdevvpn://wloc/pair?v=1&request=...&callback=https%3A%2F%2F...
///   localdevvpn://wloc/set?v=1&request=...&callback=...&latitude=...&longitude=...
///   localdevvpn://wloc/clear?v=1&request=...&callback=...
///   localdevvpn://wloc/status?v=1&request=...&callback=...
///
/// This file is deliberately Foundation-only so it can be copied into a
/// LocalDevVPN app target without pulling Worker or Web code into the app.

enum WLOCBridgeOperation: String, Sendable {
    case pair
    case set
    case clear
    case status
}

struct WLOCBridgeRequest: Sendable, Equatable {
    static let version = 1

    let requestID: String
    let operation: WLOCBridgeOperation
    let callbackURL: URL
    let latitude: Double?
    let longitude: Double?
}

enum WLOCBridgeParseError: LocalizedError, Equatable {
    case wrongScheme
    case wrongHost
    case unsupportedVersion
    case unsupportedOperation
    case missingRequestID
    case invalidCallback
    case callbackHostNotAllowed
    case missingCoordinates
    case invalidCoordinates

    var errorDescription: String? {
        switch self {
        case .wrongScheme: return "Unsupported URL scheme."
        case .wrongHost: return "Unsupported LocalDevVPN host."
        case .unsupportedVersion: return "Unsupported WLOC bridge version."
        case .unsupportedOperation: return "Unsupported WLOC bridge operation."
        case .missingRequestID: return "Missing WLOC request identifier."
        case .invalidCallback: return "The WLOC callback URL is invalid."
        case .callbackHostNotAllowed: return "The WLOC callback host is not allowed."
        case .missingCoordinates: return "The location request is missing coordinates."
        case .invalidCoordinates: return "The requested coordinates are outside the valid range."
        }
    }
}

enum WLOCDeepLinkParser {
    /// `allowedCallbackHosts` should contain only the maintainer-controlled WLOC
    /// hosts. Pass an empty set only in a local development build.
    static func parse(
        _ url: URL,
        allowedCallbackHosts: Set<String>
    ) throws -> WLOCBridgeRequest {
        guard url.scheme?.lowercased() == "localdevvpn" else {
            throw WLOCBridgeParseError.wrongScheme
        }
        guard url.host?.lowercased() == "wloc" else {
            throw WLOCBridgeParseError.wrongHost
        }

        let operationName = url.pathComponents
            .filter { $0 != "/" }
            .first?
            .lowercased()
        guard let operationName, let operation = WLOCBridgeOperation(rawValue: operationName) else {
            throw WLOCBridgeParseError.unsupportedOperation
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WLOCBridgeParseError.unsupportedVersion
        }
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        guard Int(values["v"] ?? "") == WLOCBridgeRequest.version else {
            throw WLOCBridgeParseError.unsupportedVersion
        }

        let requestID = (values["request"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestID.isEmpty, requestID.count <= 160 else {
            throw WLOCBridgeParseError.missingRequestID
        }

        guard
            let callbackText = values["callback"],
            let callbackURL = URL(string: callbackText),
            callbackURL.scheme?.lowercased() == "https",
            let callbackHost = callbackURL.host?.lowercased()
        else {
            throw WLOCBridgeParseError.invalidCallback
        }
        if !allowedCallbackHosts.isEmpty && !allowedCallbackHosts.contains(callbackHost) {
            throw WLOCBridgeParseError.callbackHostNotAllowed
        }

        var latitude: Double?
        var longitude: Double?
        if operation == .set {
            guard
                let latitudeText = values["latitude"],
                let longitudeText = values["longitude"],
                let parsedLatitude = Double(latitudeText),
                let parsedLongitude = Double(longitudeText)
            else {
                throw WLOCBridgeParseError.missingCoordinates
            }
            guard
                parsedLatitude.isFinite,
                parsedLongitude.isFinite,
                (-90.0 ... 90.0).contains(parsedLatitude),
                (-180.0 ... 180.0).contains(parsedLongitude)
            else {
                throw WLOCBridgeParseError.invalidCoordinates
            }
            latitude = parsedLatitude
            longitude = parsedLongitude
        }

        return WLOCBridgeRequest(
            requestID: requestID,
            operation: operation,
            callbackURL: callbackURL,
            latitude: latitude,
            longitude: longitude
        )
    }
}

enum WLOCBridgeCallback {
    /// Keep callback data intentionally narrow. Pairing records, UDIDs, AltIRK,
    /// PSKs, coordinates and raw diagnostic strings must never be placed in URLs.
    static func makeURL(
        for request: WLOCBridgeRequest,
        status: String,
        code: String? = nil
    ) -> URL? {
        guard var components = URLComponents(url: request.callbackURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "status", value: status))
        if let code, !code.isEmpty {
            items.append(URLQueryItem(name: "code", value: code))
        }
        components.queryItems = items
        return components.url
    }
}
