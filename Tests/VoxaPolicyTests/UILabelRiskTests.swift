import Foundation
import Testing
@testable import VoxaPolicy

@Suite("UILabelRisk")
struct UILabelRiskTests {
    @Test("labels that delete, send, spend, grant or power off are flagged", arguments: [
        "Delete", "Delete Account…", "Remove", "Erase", "Uninstall", "Discard Changes", "Empty Trash…", "Move to Trash",
        "Don't Save", "Don’t Save", "Clear History", "Send", "Send Message", "Post", "Publish", "Submit Order", "Upload",
        "Buy Now", "Purchase", "Place Order", "Pay", "Checkout", "Subscribe", "Install", "Allow", "Grant Access", "Approve",
        "I Agree", "Accept", "Quit", "Restart…", "Shut Down…", "Log Out", "Sign Out", "Force Quit", "DELETE",
    ])
    func flagged(label: String) {
        #expect(UILabelRisk.concern(in: label) != nil, "“\(label)” should be flagged")
    }

    @Test("ordinary labels, and look-alike words, are not", arguments: [
        "Save", "Cancel", "OK", "Open", "Back", "Forward", "Share", "Format", "Trash", "Reply", "Reply All", "Don't Allow",
        "Sort Order", "Payment Methods", "Clear", "Close", "New Note", "Search", "Bold", "Font", "Spelling and Grammar",
        "Sender", "Postcard", "Deleted Items", "Removed", "Purchased", "",
    ])
    func notFlagged(label: String) {
        #expect(UILabelRisk.concern(in: label) == nil, "“\(label)” should not be flagged")
    }

    @Test("the reason says what kind of thing it is, and quotes the label")
    func explanation() throws {
        let send = try #require(UILabelRisk.concern(in: "Send"))
        #expect(send.contains("sends or publishes") && send.contains("“Send”"))
        let erase = try #require(UILabelRisk.concern(in: "Empty Trash…"))
        #expect(erase.contains("deletes or erases"))
        let quit = try #require(UILabelRisk.concern(in: "Log Out"))
        #expect(quit.contains("quits, restarts or logs out"))
    }

    @Test("a long label is cut short in the reason")
    func longLabel() throws {
        let reason = try #require(UILabelRisk.concern(in: "Delete " + String(repeating: "x", count: 200)))
        #expect(reason.count < 160)
        #expect(reason.contains("…"))
    }

    @Test("a menu path is flagged when any step of it is")
    func paths() {
        #expect(UILabelRisk.concern(inPath: ["File", "Move to Trash"]) != nil)
        #expect(UILabelRisk.concern(inPath: ["Finder", "Empty Trash…"]) != nil)
        #expect(UILabelRisk.concern(inPath: ["File", "Save As…"]) == nil)
        #expect(UILabelRisk.concern(inPath: ["Format", "Font", "Bold"]) == nil)
        #expect(UILabelRisk.concern(inPath: []) == nil)
    }

    @Test("apostrophes of both kinds are dropped, so the same words match")
    func apostrophes() {
        #expect(UILabelRisk.tokens("Don't Save") == ["dont", "save"])
        #expect(UILabelRisk.tokens("Don’t Save") == ["dont", "save"])
        #expect(UILabelRisk.tokens("Save & Close — now") == ["save", "close", "now"])
    }
}
