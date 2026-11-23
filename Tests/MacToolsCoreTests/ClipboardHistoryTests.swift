import XCTest
@testable import MacToolsCore

final class ClipboardHistoryTests: XCTestCase {
    func testDefaultHotkeyIsCommandShiftC() {
        let configuration = UserConfiguration.migratedHammerspoonDefault()
        XCTAssertTrue(configuration.hotkeys.contains {
            $0.action.kind == .showClipboardHistory
                && $0.shortcut == HotkeyShortcut(modifiers: ["command", "shift"], key: "c")
        })
        XCTAssertEqual(configuration.clipboard.historySize, 200)
        XCTAssertTrue(configuration.clipboard.pasteAutomatically)
    }

    func testMissingClipboardDecodesToDefaults() throws {
        let json = """
        {"application":{"terminalBundleIdentifier":"t","finderBundleIdentifier":"f","ignoredWindowApplicationNames":[]},"hotkeys":[],"windowSwitcher":{"enabled":true,"commandTabBehavior":"most-recent-window","sameApplicationBehavior":"cycle-same-application-windows","followFocusedScreen":true,"restorePreviousApplicationWhenNoWindows":true,"width":760,"height":420,"maxVisibleRows":9,"debug":false},"translation":{"enabled":false,"provider":"google_web","endpoint":"http://127.0.0.1","apiKey":"","googleEndpoint":"https://example","googleApiKey":"","googleSourceLanguage":"auto","googleTargetLanguage":"zh-CN","googleTargetLanguageForChinese":"en","googleWebEndpoint":"https://example","googleWebClient":"gtx","model":"m","thinkingEnabled":false,"thinkingLevel":"none","thinkingParameter":"none","contextWindowTokens":1,"outputTokenLimit":1,"requestTokenLimit":0,"promptTemplate":"","systemPrompt":"","copyKeystrokeDelay":0.1,"normalizePDFLineBreaks":true,"nativeWindow":{"id":"t","title":"t","format":"plainText","width":100,"height":100,"pinByDefault":false}}}
        """
        let configuration = try JSONDecoder().decode(UserConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(configuration.clipboard, .default)
    }

    func testMultiTypeIdentityAndPlainPaste() {
        var store = ClipboardHistoryStore()
        let item = ClipboardHistoryItem(representations: [
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("Hello".utf8)),
            ClipboardRepresentation(type: "public.rtf", data: Data([0x7B, 0x5C])),
            ClipboardRepresentation(type: "public.png", data: Data([0x89, 0x50]))
        ], application: "com.example.editor")
        XCTAssertEqual(store.record(item)?.representations.count, 3)
        XCTAssertEqual(store.items.first?.plainTextRepresentations.map(\.type), ["public.utf8-plain-text"])
        XCTAssertEqual(store.items.first?.title, "Hello")

        let duplicate = ClipboardHistoryItem(representations: item.representations)
        XCTAssertEqual(store.record(duplicate)?.id, store.items.first?.id)
        XCTAssertEqual(store.items.count, 1)
    }

    func testIgnoresSecretsEmptyTextAndPinsSurviveTrim() {
        var store = ClipboardHistoryStore(settings: ClipboardSettings(historySize: 10, ignoredApps: ["com.secret.app"], ignoreRegex: ["password=\\d+"]))
        XCTAssertNil(store.record(ClipboardHistoryItem(representations: [
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("   ".utf8))
        ])))
        XCTAssertNil(store.record(ClipboardHistoryItem(representations: [
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("x".utf8)),
            ClipboardRepresentation(type: "org.nspasteboard.ConcealedType", data: Data([1]))
        ])))
        XCTAssertNil(store.record(ClipboardHistoryItem(representations: [
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("ok".utf8))
        ], application: "com.secret.app")))
        XCTAssertNil(store.record(ClipboardHistoryItem(representations: [
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("password=1234".utf8))
        ])))
        let kept = store.record(ClipboardHistoryItem(representations: [
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("keep".utf8)),
            ClipboardRepresentation(type: "dyn.drop", data: Data([9]))
        ]))
        XCTAssertEqual(kept?.representations.map(\.type), ["public.utf8-plain-text"])

        guard let id = kept?.id else { return XCTFail("missing item") }
        store.togglePin(id)
        for index in 0..<12 {
            _ = store.record(ClipboardHistoryItem(representations: [
                ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("n\(index)".utf8))
            ]))
        }
        XCTAssertTrue(store.items.contains { $0.id == id && $0.pinned })
        XCTAssertLessThanOrEqual(store.items.filter { !$0.pinned }.count, 10)
        store.clear(includingPinned: false)
        XCTAssertEqual(store.items.map(\.id), [id])
        store.clear(includingPinned: true)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testSearchAndFileTitle() {
        var store = ClipboardHistoryStore()
        _ = store.record(ClipboardHistoryItem(representations: [
            ClipboardRepresentation(type: "public.file-url", data: Data("file:///tmp/a".utf8)),
            ClipboardRepresentation(type: "public.file-url", data: Data("file:///tmp/b".utf8))
        ]))
        XCTAssertEqual(store.items.first?.title, "2 Files")
        XCTAssertEqual(store.filtered(query: "public.file").count, 1)
        XCTAssertTrue(store.filtered(query: "missing").isEmpty)
    }
}
