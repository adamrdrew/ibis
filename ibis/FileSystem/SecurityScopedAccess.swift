import Foundation

/// Scopes the lifetime of security-scoped access to a URL. For URLs chosen via
/// `NSOpenPanel`, access is granted for the session; this wrapper makes that
/// lifetime explicit and will be reused for bookmark-resolved URLs when recents
/// and state restoration land.
final class SecurityScopedAccess {
    private let url: URL
    private let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        self.didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
