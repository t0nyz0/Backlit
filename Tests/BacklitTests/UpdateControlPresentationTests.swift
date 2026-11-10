import XCTest
@testable import Backlit

final class UpdateControlPresentationTests: XCTestCase {
    private func configuration() -> [String: Any] {
        ["SUFeedURL": "https://t0nyz.com/backlit/appcast.xml",
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
         "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true,
         "SUSignedFeedFailureExpirationInterval": 0, "SUEnableAutomaticChecks": false,
         "SUAllowsAutomaticUpdates": false, "SUAutomaticallyUpdate": false,
         "SUEnableSystemProfiling": false]
    }

    private func assertManualDownload(_ presentation: UpdateControlPresentation,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(presentation.canUpdateInApp, file: file, line: line)
        XCTAssertTrue(presentation.canDownload, file: file, line: line)
        XCTAssertEqual(presentation.primaryTitle, "Download Latest Version", file: file, line: line)
        XCTAssertEqual(presentation.guidance,
                       "Download the app, then quit Backlit and replace it in Applications.",
                       file: file, line: line)
    }

    func testMissingConfigurationUsesManualDownloadWithoutAnInternalError() {
        assertManualDownload(UpdateControlPresentation(info: [:], preview: false))
        let valid = configuration()
        for key in valid.keys {
            var missing = valid
            missing.removeValue(forKey: key)
            assertManualDownload(UpdateControlPresentation(info: missing, preview: false))
        }
    }

    func testMalformedFeedOrPublicKeyUsesManualDownload() {
        for url in ["", "http://t0nyz.com/backlit/appcast.xml", "file:///tmp/appcast.xml",
                    "https://user:fixture@t0nyz.com/feed", "https://t0nyz.com/feed?fixture=1"] {
            var info = configuration()
            info["SUFeedURL"] = url
            assertManualDownload(UpdateControlPresentation(info: info, preview: false))
        }
        for key in ["", "invalid", Data(repeating: 0, count: 32).base64EncodedString(),
                    Data(repeating: 1, count: 31).base64EncodedString()] {
            var info = configuration()
            info["SUPublicEDKey"] = key
            assertManualDownload(UpdateControlPresentation(info: info, preview: false))
        }
    }

    func testWeakenedVerificationOrAutomaticPoliciesUseManualDownload() {
        for key in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] {
            var info = configuration()
            info[key] = false
            assertManualDownload(UpdateControlPresentation(info: info, preview: false))
        }
        for key in ["SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates",
                    "SUAutomaticallyUpdate", "SUEnableSystemProfiling"] {
            var info = configuration()
            info[key] = true
            assertManualDownload(UpdateControlPresentation(info: info, preview: false))
        }
        var info = configuration()
        info["SUSignedFeedFailureExpirationInterval"] = 1
        assertManualDownload(UpdateControlPresentation(info: info, preview: false))
    }

    func testStrictConfigurationOffersInAppCheckWithoutManualGuidance() {
        let presentation = UpdateControlPresentation(info: configuration(), preview: false)
        XCTAssertTrue(presentation.canUpdateInApp)
        XCTAssertTrue(presentation.canDownload)
        XCTAssertEqual(presentation.primaryTitle, "Check for Updates")
        XCTAssertNil(presentation.guidance)
    }

    func testPreviewNeverOffersUpdatesOrEnabledDownloadsEvenWithValidConfiguration() {
        for info in [[String: Any](), configuration()] {
            let presentation = UpdateControlPresentation(info: info, preview: true)
            XCTAssertFalse(presentation.canUpdateInApp)
            XCTAssertFalse(presentation.canDownload)
            XCTAssertEqual(presentation.primaryTitle, "Download Latest Version")
            XCTAssertEqual(presentation.guidance, "Downloads are disabled in preview.")
        }
    }

    func testDownloadDestinationAndManualCopyArePublicFacing() {
        XCTAssertEqual(UpdateControlPresentation.downloadURL.absoluteString, "https://t0nyz.com/backlit/install")
        let presentation = UpdateControlPresentation(info: [:], preview: false)
        let copy = (presentation.primaryTitle + " " + (presentation.guidance ?? "")).lowercased()
        for word in ["publisher", "key", "feed", "signing", "trust", "configuration", "sparkle"] {
            XCTAssertFalse(copy.contains(word), "Manual update controls should not expose \(word) diagnostics.")
        }
    }
}
