import Foundation
import SystemExtensions

/// Bridges `OSSystemExtensionRequest` delegate callbacks to a main-actor closure.
/// Invariant: every request is submitted with `queue: .main`, so all callbacks arrive on the main thread.
final class SystemExtensionRequestHandler: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    enum Event {
        case needsUserApproval
        case completed
        case willCompleteAfterReboot
        case properties([OSSystemExtensionProperties])
        case failed(any Error)
    }

    private let onEvent: @MainActor (Event) -> Void

    init(onEvent: @escaping @MainActor (Event) -> Void) {
        self.onEvent = onEvent
    }

    /// Asks sysextd to install (or replace) the embedded camera extension.
    func activate(_ identifier: String) {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Asks sysextd about installed versions of the extension (enabled / awaiting approval).
    func queryProperties(_ identifier: String) {
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace // always take the freshly built version (CFBundleVersion is a timestamp)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        deliver(.needsUserApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        deliver(result == .willCompleteAfterReboot ? .willCompleteAfterReboot : .completed)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        deliver(.failed(error))
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        deliver(.properties(properties))
    }

    private func deliver(_ event: Event) {
        // Already on the main thread (see type invariant); the event is not used after this call.
        nonisolated(unsafe) let event = event
        MainActor.assumeIsolated { onEvent(event) }
    }
}

extension SystemExtensionRequestHandler {
    /// Human-readable explanation for a failed request, with the most likely fix.
    static func message(for error: any Error) -> String {
        let appsHint = "MemeCam must run from /Applications (scripts/build-app.sh --install)."
        let signingHint = "Provision signing with `uv run --script scripts/setup-signing.py`, then rebuild with scripts/build-app.sh."
        guard let error = error as? OSSystemExtensionError else {
            return "\(error.localizedDescription) \(appsHint)"
        }
        switch error.code {
        case .unsupportedParentBundleLocation:
            return "Move MemeCam to the Applications folder and try again. \(appsHint)"
        case .missingEntitlement:
            return "This build is not signed with the System Extension entitlement. \(signingHint)"
        case .extensionNotFound:
            return "The camera extension is missing from the app bundle. \(signingHint)"
        case .codeSignatureInvalid, .validationFailed, .extensionMissingIdentifier, .unknownExtensionCategory:
            return "macOS rejected the camera extension's signature (\(error.code.rawValue)). \(signingHint)"
        case .requestCanceled:
            return "The install request was canceled. Try again."
        case .requestSuperseded:
            return "Another install request replaced this one. Try again."
        case .authorizationRequired:
            return "macOS needs your approval: open System Settings > General > Login Items & Extensions > Camera Extensions."
        case .forbiddenBySystemPolicy:
            return "Camera extensions are blocked by a system policy (MDM) on this Mac."
        case .duplicateExtensionIdentifer:
            return "Another app installed an extension with the same identifier. Remove old MemeCam copies. \(appsHint)"
        default:
            return "Installing the virtual camera failed: \(error.localizedDescription) (code \(error.code.rawValue)). \(appsHint)"
        }
    }
}
