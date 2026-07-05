import Foundation

extension String {
    /// This path with any trailing slashes removed, never stripping the root
    /// "/". The one spelling rule shared by every path-keyed store and slug in
    /// Ibis (workspace identity, trust decisions, layout snapshots, Claude's
    /// project slug): the same folder arrives with a trailing slash from
    /// Finder/`open` and usually without one from the CLI, and those must not
    /// key to different entries.
    var strippingTrailingSlashes: String {
        var path = self
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
