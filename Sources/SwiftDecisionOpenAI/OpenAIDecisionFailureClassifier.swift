import Foundation
import SwiftDecision
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Classifies OpenAI transport failures without changing the error or applying recovery policy.
public enum OpenAIDecisionFailureClassifier {
    public static func classify(_ error: any Error) -> DecisionFailureCategory {
        let engineCategory = DecisionFailureCategory.classify(error)
        if engineCategory != .permanent { return engineCategory }

        if let error = error as? URLError {
            return switch error.code {
            case .cancelled: DecisionFailureCategory.cancelled
            case .timedOut: DecisionFailureCategory.timedOut
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet: DecisionFailureCategory.transport
            default: DecisionFailureCategory.permanent
            }
        } else if let error = error as? OpenAIDecisionBackendError,
                  case let .httpFailure(statusCode) = error {
            if statusCode == 429 { return .rateLimited }
            if statusCode == 408 || statusCode == 425 || (500 ..< 600).contains(statusCode) {
                return .serviceUnavailable
            }
            return .permanent
        } else {
            return .permanent
        }
    }
}
