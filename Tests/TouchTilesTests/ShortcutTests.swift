import AppKit
import Carbon
import XCTest
@testable import TouchTiles

final class ShortcutTests: XCTestCase {
    private func event(code: Int, flags: NSEvent.ModifierFlags, text: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                       timestamp: 0, windowNumber: 0, context: nil, characters: text,
                                       charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code)))
    }

    func testCommonCommandShortcutsAreKeptAvailable() throws {
        for (code, text) in [(kVK_ANSI_T, "t"), (kVK_ANSI_F, "f")] {
            let input = try event(code: code, flags: .command, text: text)
            XCTAssertThrowsError(try KeyBinding(recording: input))
        }
        let nativeFullScreen = try event(code: kVK_ANSI_F, flags: [.control, .command], text: "f")
        XCTAssertThrowsError(try KeyBinding(recording: nativeFullScreen))
    }

    func testRecordedShortcutUsesThePhysicalKeyAndRoundTripsThroughPreferences() throws {
        let input = try event(code: kVK_LeftArrow, flags: [.command, .option], text: "←")
        let binding = try KeyBinding(recording: input)
        XCTAssertEqual(binding.code, UInt32(kVK_LeftArrow))
        XCTAssertEqual(binding.display, "⌥⌘←")
        XCTAssertEqual(try JSONDecoder().decode(KeyBinding.self, from: JSONEncoder().encode(binding)), binding)
    }

    func testOptionAloneRecordsBothDefaultWindowShortcuts() throws {
        for (action, code, text) in [(WindowAction.float, kVK_ANSI_T, "t"), (.fullscreen, kVK_ANSI_F, "f")] {
            let input = try event(code: code, flags: .option, text: text)
            let binding = try KeyBinding(recording: input)
            XCTAssertEqual(binding, action.defaultBinding)
            XCTAssertEqual(binding.display, "⌥" + text.uppercased())
        }
    }

    func testPlainTypingAndOtherSingleModifiersCannotBeReserved() throws {
        for flags: NSEvent.ModifierFlags in [[], .shift, .command, .control] {
            let input = try event(code: kVK_ANSI_A, flags: flags, text: "a")
            XCTAssertThrowsError(try KeyBinding(recording: input))
        }
    }
}
