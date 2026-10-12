//
//  UpdateModel.swift
//  Cellular
//

import Foundation
import UserNotifications

/**
 This class checks GitHub for a newer release of Cellular. Updates are not installed automatically: the user is pointed to the release page to download it.

 All state in this class is only accessed on the main thread.
 */
class UpdateModel: ObservableObject {
    struct Release {
        let version: String
        let url: URL
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    static let notificationIdentifier = "update"
    static let notificationURLKey = "url"

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/nickredible/cellular/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private let defaults = UserDefaults.standard
    private var checkTimer: Timer?

    /// The newest release, if it is newer than this version of Cellular
    @Published private(set) var availableUpdate: Release?

    /**
     This function checks for updates now and then once a day.
     */
    func startChecking() {
        checkForUpdates()
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }

    /**
     This function checks GitHub for a newer release, if the user allows it, and notifies the user the first time each new version is found.
     */
    func checkForUpdates() {
        guard defaults.bool(forKey: "checkForUpdates") else {
            availableUpdate = nil
            return
        }

        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            // A repository without releases returns 404, which needs no attention
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                if let error {
                    print("Failed to check for updates: \(error.localizedDescription)")
                }
                return
            }

            DispatchQueue.main.async {
                self?.handleLatestRelease(release)
            }
        }.resume()
    }

    private func handleLatestRelease(_ release: GitHubRelease) {
        let latestVersion = String(release.tagName.trimmingPrefix("v"))
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        guard Self.isVersion(latestVersion, newerThan: currentVersion) else {
            availableUpdate = nil
            return
        }

        print("Cellular \(latestVersion) is available")
        availableUpdate = Release(version: latestVersion, url: release.htmlURL)

        // Only notify once per version, since this is checked every day
        guard defaults.string(forKey: "lastNotifiedUpdateVersion") != latestVersion else { return }
        defaults.set(latestVersion, forKey: "lastNotifiedUpdateVersion")

        let content = UNMutableNotificationContent()
        content.title = "Cellular \(latestVersion) is available"
        content.body = "Click to download it from GitHub."
        content.userInfo = [Self.notificationURLKey: release.htmlURL.absoluteString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: nil))
    }

    /**
     This function compares two version numbers like "1.2.10" component by component, treating missing components as 0.
     */
    static func isVersion(_ version: String, newerThan otherVersion: String) -> Bool {
        let components = version.split(separator: ".").map { Int($0) ?? 0 }
        let otherComponents = otherVersion.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(components.count, otherComponents.count) {
            let component = index < components.count ? components[index] : 0
            let otherComponent = index < otherComponents.count ? otherComponents[index] : 0
            if component != otherComponent {
                return component > otherComponent
            }
        }
        return false
    }
}
