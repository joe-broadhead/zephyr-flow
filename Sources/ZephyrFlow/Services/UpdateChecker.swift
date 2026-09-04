import AppKit
import Foundation
import ZephyrFlowCore

/// Manual / optional GitHub Releases update check (no background telemetry).
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case updateAvailable(latest: String, notes: String?, htmlURL: URL, downloadURL: URL?)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let session: URLSession
    private let releasesAPI: URL
    private let currentVersion: String

    init(
        currentVersion: String = ZephyrFlowConstants.version,
        releasesAPI: URL = URL(string: "https://api.github.com/repos/joe-broadhead/zephyr-flow/releases/latest")!,
        session: URLSession = .shared
    ) {
        self.currentVersion = currentVersion
        self.releasesAPI = releasesAPI
        self.session = session
    }

    /// User-initiated check against GitHub Releases (HTTPS only).
    func checkForUpdates() async {
        status = .checking
        ZFLog.info("update_check_start current=\(currentVersion)")

        var request = URLRequest(
            url: releasesAPI,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ZephyrFlow/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode == 404 {
                    // No releases published yet
                    status = .upToDate(current: currentVersion)
                    ZFLog.info("update_check_result up_to_date reason=no_release")
                    return
                }
                status = .failed("GitHub returned HTTP \(http.statusCode)")
                ZFLog.info("update_check_fail status=\(http.statusCode)")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            if release.draft {
                status = .upToDate(current: currentVersion)
                return
            }

            let latestTag = release.tagName
            guard AppVersion.isNewer(candidate: latestTag, than: currentVersion) else {
                status = .upToDate(current: currentVersion)
                ZFLog.info("update_check_result up_to_date latest=\(latestTag)")
                return
            }

            let download =
                release.assets
                .first { $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("macos") }
                .map(\.browserDownloadURL)
                ?? release.assets.first { $0.name.lowercased().hasSuffix(".zip") }.map(\.browserDownloadURL)

            let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
            status = .updateAvailable(
                latest: latestTag,
                notes: notes.flatMap { $0.isEmpty ? nil : $0 },
                htmlURL: release.htmlURL,
                downloadURL: download
            )
            ZFLog.info("update_check_result available latest=\(latestTag)")
        } catch {
            status = .failed(error.localizedDescription)
            ZFLog.info("update_check_fail error=\(error.localizedDescription)")
        }
    }

    func openReleasePage() {
        if case .updateAvailable(_, _, let html, _) = status {
            NSWorkspace.shared.open(html)
        } else {
            NSWorkspace.shared.open(ZephyrFlowConstants.githubURL.appendingPathComponent("releases"))
        }
    }

    func openDownload() {
        if case .updateAvailable(_, _, let html, let zip) = status {
            NSWorkspace.shared.open(zip ?? html)
        }
    }

    func resetStatus() {
        status = .idle
    }
}

// MARK: - GitHub API (minimal)

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, draft, prerelease, assets
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
