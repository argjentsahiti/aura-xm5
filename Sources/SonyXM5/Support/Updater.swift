import Foundation
import AppKit

/// Checks GitHub Releases for a newer build.
///
/// Deliberately passive: it reports what it finds and hands you the command or
/// the download page. Nothing is downloaded or replaced behind your back.
@MainActor
final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published var automaticallyCheck: Bool {
        didSet { UserDefaults.standard.set(automaticallyCheck, forKey: autoKey) }
    }

    /// True when Homebrew owns this copy, so we can suggest the right command.
    let installedViaHomebrew: Bool

    private let autoKey = "updates.automatic"
    private let lastCheckKey = "updates.lastCheck"
    private let releasesAPI = URL(string: "https://api.github.com/repos/argjentsahiti/aura-xm5/releases/latest")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    init() {
        let defaults = UserDefaults.standard
        automaticallyCheck = defaults.object(forKey: autoKey) as? Bool ?? true

        // Homebrew keeps casks in its Caskroom and symlinks/moves into
        // /Applications; the receipt is the reliable signal.
        let caskroom = "/opt/homebrew/Caskroom/aura"
        let intelCaskroom = "/usr/local/Caskroom/aura"
        installedViaHomebrew = FileManager.default.fileExists(atPath: caskroom)
            || FileManager.default.fileExists(atPath: intelCaskroom)
    }

    /// The command or action that actually updates this install.
    var updateInstruction: String {
        installedViaHomebrew
            ? "brew upgrade --cask aura"
            : "Download the new version from GitHub"
    }

    func checkOnLaunchIfDue() {
        guard automaticallyCheck else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        let elapsed = Date().timeIntervalSince1970 - last
        // Once a day is plenty for a menu-bar utility.
        guard elapsed > 60 * 60 * 24 else { return }
        check()
    }

    func check() {
        guard status != .checking else { return }
        status = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        var request = URLRequest(url: releasesAPI)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.status = .failed(error.localizedDescription)
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.status = .failed("Could not read the release feed")
                    return
                }

                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let page = (json["html_url"] as? String)
                    ?? "https://github.com/argjentsahiti/aura-xm5/releases/latest"

                if Self.isNewer(latest, than: self.currentVersion) {
                    self.status = .available(version: latest, url: page)
                    Log.write("update", "available: \(latest) (running \(self.currentVersion))")
                } else {
                    self.status = .upToDate
                    Log.write("update", "up to date (\(self.currentVersion))")
                }
            }
        }.resume()
    }

    func openReleasePage() {
        guard case .available(_, let url) = status, let link = URL(string: url) else { return }
        NSWorkspace.shared.open(link)
    }

    func copyUpdateCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(updateInstruction, forType: .string)
    }

    /// Numeric component-wise compare, so 1.10 correctly beats 1.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
