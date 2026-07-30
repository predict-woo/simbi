import Foundation
import Testing

@testable import SimbiUI

@Suite struct ChatWindowTabbingTests {
    let note = URL(fileURLWithPath: "/Users/x/Simbi/Standup Notes")

    @Test func identifierIsStablePerNote() {
        #expect(
            ChatWindowTabbing.identifier(for: note) == ChatWindowTabbing.identifier(for: note))
        #expect(!ChatWindowTabbing.identifier(for: note).isEmpty)
    }

    @Test func differentNotesGetDifferentIdentifiers() {
        let other = URL(fileURLWithPath: "/Users/x/Simbi/Other")
        #expect(ChatWindowTabbing.identifier(for: note) != ChatWindowTabbing.identifier(for: other))
    }

    @Test func trailingSlashDoesNotChangeTheIdentifier() {
        let slashed = URL(fileURLWithPath: "/Users/x/Simbi/Standup Notes/")
        #expect(
            ChatWindowTabbing.identifier(for: note) == ChatWindowTabbing.identifier(for: slashed))
    }
}
