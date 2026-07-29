import Foundation

// MARK: - RuntimeError

public enum RuntimeRecoveryAction: Equatable, Sendable {
    case retry
    case chooseSmallerModel
    case freeMemory
    case freeStorage
    case waitForDeviceToCool
    case disableLowPowerMode
    case downloadModel
    case installVisionProjector
    case none
}

public enum RuntimeError: Error, Equatable, Sendable {
    case noActiveModel
    case modelNotLoaded(String)
    case modelLoadBlocked(reason: String)
    case generationCancelled
    case backgrounded
    case thermalCritical
    case insufficientMemory(requiredBytes: Int64, availableBytes: Int64)
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case invalidModelFiles(String)
    case unsupportedOperation(String)
    case underlying(String)

    public var developerDescription: String {
        switch self {
        case .noActiveModel:
            return "No LocalModel is selected."
        case .modelNotLoaded(let id):
            return "Model \(id) is not loaded."
        case .modelLoadBlocked(let reason):
            return "Model load was blocked by policy: \(reason)"
        case .generationCancelled:
            return "Generation was cancelled cooperatively."
        case .backgrounded:
            return "Heavy inference was refused because the app is not active."
        case .thermalCritical:
            return "Heavy inference was blocked because ProcessInfo.thermalState is critical."
        case .insufficientMemory(let required, let available):
            return "Insufficient memory: required=\(required), available=\(available)."
        case .insufficientStorage(let required, let available):
            return "Insufficient storage: required=\(required), available=\(available)."
        case .invalidModelFiles(let detail):
            return "Model validation failed: \(detail)"
        case .unsupportedOperation(let detail):
            return "Unsupported operation: \(detail)"
        case .underlying(let detail):
            return "Underlying runtime error: \(detail)"
        }
    }

    public var userTitle: String {
        switch self {
        case .noActiveModel, .modelNotLoaded:
            return "Model not ready"
        case .modelLoadBlocked, .insufficientMemory:
            return "Not enough memory"
        case .generationCancelled:
            return "Generation stopped"
        case .backgrounded:
            return "App is in the background"
        case .thermalCritical:
            return "Device too hot"
        case .insufficientStorage:
            return "Not enough storage"
        case .invalidModelFiles:
            return "Model files are incomplete"
        case .unsupportedOperation:
            return "Feature not available yet"
        case .underlying:
            return "Local AI error"
        }
    }

    public var userDetail: String {
        switch self {
        case .noActiveModel:
            return "Choose a local model before starting generation."
        case .modelNotLoaded:
            return "Load the selected model, then try again."
        case .modelLoadBlocked(let reason):
            return reason
        case .generationCancelled:
            return "The current response was stopped."
        case .backgrounded:
            return "Return to the app before starting local inference."
        case .thermalCritical:
            return "Let the device cool for a minute before trying again."
        case .insufficientMemory:
            return "Close other apps, unload the current model, or choose a smaller model."
        case .insufficientStorage:
            return "Delete unused models or free device storage, then retry."
        case .invalidModelFiles(let detail):
            return detail
        case .unsupportedOperation(let detail):
            return detail
        case .underlying(let detail):
            return detail
        }
    }

    public var recoveryAction: RuntimeRecoveryAction {
        switch self {
        case .noActiveModel:
            return .downloadModel
        case .modelNotLoaded:
            return .retry
        case .modelLoadBlocked, .insufficientMemory:
            return .chooseSmallerModel
        case .generationCancelled:
            return .none
        case .backgrounded:
            return .retry
        case .thermalCritical:
            return .waitForDeviceToCool
        case .insufficientStorage:
            return .freeStorage
        case .invalidModelFiles:
            return .downloadModel
        case .unsupportedOperation:
            return .none
        case .underlying:
            return .retry
        }
    }
}

extension RuntimeError: LocalizedError {
    public var errorDescription: String? { userTitle }
    public var failureReason: String? { userDetail }
    public var recoverySuggestion: String? {
        switch recoveryAction {
        case .retry:
            return "Try again."
        case .chooseSmallerModel:
            return "Choose a smaller model."
        case .freeMemory:
            return "Free memory and retry."
        case .freeStorage:
            return "Free storage and retry."
        case .waitForDeviceToCool:
            return "Wait for the device to cool."
        case .disableLowPowerMode:
            return "Turn off Low Power Mode."
        case .downloadModel:
            return "Download or import a complete model."
        case .installVisionProjector:
            return "Install the matching vision projector file."
        case .none:
            return nil
        }
    }
}
