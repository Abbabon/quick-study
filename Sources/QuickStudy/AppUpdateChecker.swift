import Foundation

/// Decides whether GitHub has an app release newer than what's currently running.
///
/// Mirror of `UpdateChecker` (which tracks Scryfall card data) but for the app binary:
/// we read the latest GitHub Release's `tag_name` and compare it against the running
/// bundle's `CFBundleShortVersionString`. The release's `QuickStudy-<ver>.zip` asset is
/// the same artifact `scripts/release.sh` publishes, reused as-is for the manual-install
/// self-update path.
enum AppUpdateChecker {
    static let repo = "Abbabon/quick-study"

    /// What a successful check yields: the published version plus the URLs needed to either
    /// download-and-swap (`zipURL`) or point the user at the release (`pageURL`).
    struct ReleaseInfo: Equatable {
        let version: String   // semver, leading "v" stripped (e.g. "0.3.0")
        let zipURL: URL?      // the QuickStudy-<ver>.zip asset, if present
        let pageURL: URL?     // the release's html_url
        let notes: String?    // release body, if any
    }

    /// The running bundle's user-facing version, or `nil` under `swift run` (no bundle).
    static func currentVersion() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Fetches the latest GitHub Release, or `nil` on any network/parse error
    /// (callers treat `nil` as "leave current state unchanged").
    static func fetchLatest(session: URLSession = .shared) async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent.
        request.setValue("QuickStudy/1.0 (+https://github.com/\(repo))",
                         forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await session.data(for: request)
            let release = try JSONDecoder().decode(APIRelease.self, from: data)
            let version = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst())
                : release.tag_name
            let zipName = "QuickStudy-\(version).zip"
            let asset = release.assets.first { $0.name == zipName }
                ?? release.assets.first { $0.name.hasSuffix(".zip") }
            return ReleaseInfo(version: version,
                               zipURL: asset.flatMap { URL(string: $0.browser_download_url) },
                               pageURL: URL(string: release.html_url),
                               notes: release.body)
        } catch {
            return nil
        }
    }

    /// Pure decision used by both the live check and the unit tests.
    ///
    /// Prompt only when `remote` is strictly newer than the running `current` version and the
    /// user hasn't already dismissed that same (or a newer) version.
    static func shouldPrompt(remote: String, current: String, dismissed: String?) -> Bool {
        guard isNewer(remote, than: current) else { return false }
        if let dismissed, !isNewer(remote, than: dismissed) { return false }
        return true
    }

    /// Component-wise semver compare of `X.Y.Z`. Returns `false` for unparseable input
    /// (a malformed remote should never trigger a prompt).
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        guard let a = components(lhs), let b = components(rhs) else { return false }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Parses "0.3.0" (optionally "v0.3.0") into `[0, 3, 0]`; `nil` if any part is non-numeric.
    private static func components(_ version: String) -> [Int]? {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            out.append(n)
        }
        return out
    }

    private struct APIRelease: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [APIAsset]
    }

    private struct APIAsset: Decodable {
        let name: String
        let browser_download_url: String
    }
}
