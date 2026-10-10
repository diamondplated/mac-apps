import Combine
import Foundation
import Sparkle
import SwiftUI

struct UpdateConfiguration {
    static func trustedHTTPSURL(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }

    static func unavailableReason(bundleURL: URL, info: [String: Any]) -> String? {
        guard bundleURL.pathExtension == "app", info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleIdentifier"] as? String == "com.andrew.mactools",
              info["CFBundleExecutable"] as? String == "MacTools" else {
            return "Updates are available in the packaged Mac Tools app."
        }
        guard let version = info["CFBundleVersion"] as? String, let build = UInt64(version), build > 0,
              let release = info["CFBundleShortVersionString"] as? String, !release.isEmpty,
              release.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return "This build has no valid release version. Install a published Mac Tools release to receive updates."
        }
        guard trustedHTTPSURL(info["SUFeedURL"]) != nil,
              let publicKey = info["SUPublicEDKey"] as? String,
              let decodedKey = Data(base64Encoded: publicKey), decodedKey.count == 32,
              decodedKey.contains(where: { $0 != 0 }),
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUSignedFeedFailureExpirationInterval"] as? Int == 0 else {
            return "This build is missing trusted update configuration. Install a published Mac Tools release to receive updates."
        }
        return nil
    }
}

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    let unavailableReason: String?
    let releasesURL: URL?
    private let controller: SPUStandardUpdaterController?

    var isConfigured: Bool { controller != nil }

    init(bundle: Bundle = .main) {
        releasesURL = UpdateConfiguration.trustedHTTPSURL(bundle.object(forInfoDictionaryKey: "MacToolsReleasesURL"))
        unavailableReason = UpdateConfiguration.unavailableReason(bundleURL: bundle.bundleURL, info: bundle.infoDictionary ?? [:])
        guard unavailableReason == nil else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        // Sparkle persists these preferences itself. KVO also reflects changes made in
        // its native update window, without resetting the user's choices at launch.
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyDownloadsUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main).assign(to: &$lastUpdateCheckDate)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }
}

struct ManagerUpdatesView: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Mac Tools Updates", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Keep the manager and its collection up to date.").foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Automatically check for updates daily", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticallyChecksForUpdates))
                    Toggle("Automatically download and install Mac Tools updates", isOn: Binding(
                        get: { updater.automaticallyDownloadsUpdates }, set: updater.setAutomaticallyDownloadsUpdates))
                        .disabled(!updater.automaticallyChecksForUpdates)
                    Text("Updates are checked against the release signing key before they are opened.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(!updater.isConfigured)
            Text("New releases include updated versions of your apps and built-in utilities. Choose Update in Overview when you’re ready to update installed apps.")
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .buttonStyle(.borderedProminent).disabled(!updater.canCheckForUpdates)
                if let url = updater.releasesURL { Link("View Releases", destination: url) }
            }
            if let date = updater.lastUpdateCheckDate {
                Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reason = updater.unavailableReason {
                Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
