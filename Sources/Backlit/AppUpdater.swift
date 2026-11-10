import AppKit
import Combine
import SwiftUI
import Sparkle

/// Trust is provisioned in the signed app bundle, never learned from a feed,
/// preferences, a downloaded checksum, or an environment variable at runtime.
struct UpdateConfiguration {
    let feed: URL
    init(info: [String: Any], preview: Bool) throws {
        guard !preview,
              let raw = info["SUFeedURL"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32, bytes.contains(where: { $0 != 0 }),
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue == 0,
              info["SUEnableAutomaticChecks"] as? Bool == false,
              info["SUAllowsAutomaticUpdates"] as? Bool == false,
              info["SUAutomaticallyUpdate"] as? Bool == false,
              info["SUEnableSystemProfiling"] as? Bool == false else {
            throw RuntimeServices.failure(preview ? "Updates are unavailable in preview." : "In-app updates aren’t enabled for this build yet. A trusted update feed and signing key must be included by the publisher.")
        }
        feed = url
    }
    static func validateAsset(_ url: URL?, build: String, current: String, architecture: String) throws {
        guard let url, url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/t0nyz0/Backlit/releases/download/"),
              url.lastPathComponent.hasSuffix("-macOS-\(architecture).zip"),
              let next = UInt64(build), let installed = UInt64(current), next > installed else {
            throw RuntimeServices.failure("This update is incompatible with this build or Mac.")
        }
    }
}

/// A resumed or automatic install must receive a fresh explicit choice.
struct UpdateConsent {
    private(set) var armed = false
    private(set) var approved = false
    mutating func arm() { armed = true }
    mutating func approve() { approved = true }
    mutating func reset() { self = UpdateConsent() }
    var allowsTermination: Bool { !armed || approved }
}

/// A failed logo restoration never hands control to the installer. The user
/// can retry after resolving the existing restoration/quit prompt.
@MainActor final class UpdateInstallGate {
    private var pending: (() -> Void)?
    private(set) var prepared = false
    var prepare: (() -> Bool)?
    var paused: Bool { pending != nil }
    func postpone(_ install: @escaping () -> Void) -> Bool {
        guard prepare?() == true else { pending = install; return true }
        prepared = true
        return false
    }
    func retry() {
        guard let install = pending, prepare?() == true else { return }
        pending = nil
        prepared = true
        install()
    }
    func clear() { pending = nil; prepared = false }
}

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var message: String?
    @Published private(set) var canCheck = true
    @Published private(set) var installPaused = false
    let installGate = UpdateInstallGate()
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    var recoverAfterFailure: (() -> Void)?
    private(set) var consent = UpdateConsent()

    func check(preview: Bool) {
        do {
            _ = try UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:], preview: preview)
            if controller == nil {
                let next = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
                // Manual-only policy also overrides persisted Sparkle auto-update settings.
                next.updater.automaticallyChecksForUpdates = false
                next.updater.automaticallyDownloadsUpdates = false
                next.updater.sendsSystemProfile = false
                try next.updater.start()
                controller = next
                observation = next.updater.publisher(for: \.canCheckForUpdates)
                    .receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }
            }
            guard let controller, controller.updater.canCheckForUpdates, !controller.updater.sessionInProgress else { return }
            message = nil
            controller.checkForUpdates(nil)
        } catch { message = error.localizedDescription }
    }
    func retryInstall() { consent.approve(); installGate.retry(); installPaused = installGate.paused }
    func allowsTermination() -> Bool {
        if !consent.allowsTermination { message = "An update is waiting. Choose Install Update and Relaunch, or dismiss it in the update window before quitting." }
        return consent.allowsTermination
    }
    func showProgress() { controller?.checkForUpdates(nil) }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .install { consent.approve() }
        else { consent.reset() }
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { consent.arm() }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates else { throw RuntimeServices.failure("Start update checks from Settings.") }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        try UpdateConfiguration.validateAsset(item.fileURL, build: item.versionString,
            current: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", architecture: arch)
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        consent.arm()
        let originalPreparation = installGate.prepare
        installGate.prepare = { [weak self] in
            guard let self, self.consent.approved else { return false }
            return originalPreparation?() == true
        }
        let postponed = installGate.postpone(installHandler)
        installPaused = postponed
        if postponed { message = "Update paused. Finish restoring the light, then retry installation." }
        return postponed
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        // False declines taking over the continuation; it is NOT a veto.
        // applicationShouldTerminate is the final consent/restoration guard.
        consent.arm()
        return false
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if installGate.prepared { recoverAfterFailure?() }
        installGate.clear(); consent.reset(); installPaused = false; message = error.localizedDescription
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if !installGate.paused { installPaused = false }
    }
}

struct UpdateControls: View {
    @ObservedObject var updater: AppUpdater
    let preview: Bool
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button("Check for Updates") { updater.check(preview: preview) }.disabled(!updater.canCheck)
            if updater.installPaused { Button("Install Update and Relaunch") { updater.retryInstall() } }
            if !updater.canCheck { Button("Show Update Progress") { updater.showProgress() } }
            if let message = updater.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
