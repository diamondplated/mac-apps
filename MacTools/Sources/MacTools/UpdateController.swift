import Combine
import Foundation
import MacToolsCore
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

/// Mac Tools' own settings (⌘,): how it updates itself and where it installs apps.
struct PreferencesView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var updater: UpdateController

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticallyChecksForUpdates))
                Toggle("Install updates automatically", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates }, set: updater.setAutomaticallyDownloadsUpdates))
                    .disabled(!updater.automaticallyChecksForUpdates)
                LabeledContent {
                    HStack(spacing: 12) {
                        if let url = updater.releasesURL { Link("Release Notes", destination: url) }
                        Button("Check Now", action: updater.checkForUpdates).disabled(!updater.canCheckForUpdates)
                    }
                } label: {
                    if let date = updater.lastUpdateCheckDate {
                        Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Not checked yet")
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updater.unavailableReason ?? "A Mac Tools update brings new versions of its apps. Update each one from the Library.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!updater.isConfigured)
            Section {
                Picker("Install new apps for", selection: $library.scope) {
                    Text("All users").tag(InstallScope.system)
                    Text("Only me").tag(InstallScope.user)
                }.disabled(library.isBusy)
            } footer: {
                Text("Updates stay wherever the app already is.").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
