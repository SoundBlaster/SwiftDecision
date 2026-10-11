import Foundation

/// Selects the URL form used by a provider adapter.
///
/// This value describes URL configuration only. Provider adapters remain responsible for their
/// default URLs, operation paths, URL validation, credentials, and request contracts.
public enum APIEndpoint: Sendable, Equatable {
    /// Use the provider adapter's documented default destination.
    case providerDefault

    /// Use an API root; the provider adapter appends its operation path.
    case baseURL(URL)

    /// Use this complete operation URL without changing its path.
    case operationURL(URL)
}
