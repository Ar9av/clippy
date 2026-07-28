import XCTest
@testable import ClippyMac

final class AutomationSafetyTests: XCTestCase {

    // MARK: isFinalAction

    func testFinalActionMatchesWholeWords() {
        let positives = [
            "Send", "Send message", "Submit", "Publish", "Post", "Buy now",
            "Purchase", "Pay now", "Delete", "Remove", "Accept", "Agree",
            "Place order", "Transfer funds", "Password", "Passcode", "Confirm",
            "Checkout", "Sign out", "Log out"
        ]
        for label in positives {
            XCTAssertTrue(AutomationSafety.isFinalAction(label), "expected '\(label)' to be a final action")
        }
    }

    func testFinalActionDoesNotFalsePositiveOnSubstrings() {
        let negatives = ["Sender name", "Repost count", "Postcode", "Assignee", "Compose", "Comment"]
        for label in negatives {
            XCTAssertFalse(AutomationSafety.isFinalAction(label), "did not expect '\(label)' to be a final action")
        }
    }

    // MARK: isSecureField

    func testIsSecureField() {
        XCTAssertTrue(AutomationSafety.isSecureField(role: "AXSecureTextField", subrole: ""))
        XCTAssertTrue(AutomationSafety.isSecureField(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertFalse(AutomationSafety.isSecureField(role: "AXTextField", subrole: ""))
    }

    // MARK: isSafeAddressBarSubmit

    func testSafeAddressBarSubmitAcceptsBrowserChrome() {
        XCTAssertTrue(AutomationSafety.isSafeAddressBarSubmit(target: "Address and Search", text: "swift concurrency"))
        XCTAssertTrue(AutomationSafety.isSafeAddressBarSubmit(target: "Address Bar", text: "https://example.com"))
        XCTAssertTrue(AutomationSafety.isSafeAddressBarSubmit(target: "Search or type URL", text: "hello"))
        XCTAssertTrue(AutomationSafety.isSafeAddressBarSubmit(target: "Omnibox", text: "hello"))
        XCTAssertTrue(AutomationSafety.isSafeAddressBarSubmit(target: "URL", text: "example.com"))
    }

    func testSafeAddressBarSubmitRejectsFormFields() {
        XCTAssertFalse(AutomationSafety.isSafeAddressBarSubmit(target: "Email address", text: "me@example.com"))
        XCTAssertFalse(AutomationSafety.isSafeAddressBarSubmit(target: "Billing address", text: "123 Main St"))
        XCTAssertFalse(AutomationSafety.isSafeAddressBarSubmit(target: "Shipping address line 1", text: "123 Main St"))
        XCTAssertFalse(AutomationSafety.isSafeAddressBarSubmit(target: "Home address", text: "123 Main St"))
        XCTAssertFalse(AutomationSafety.isSafeAddressBarSubmit(target: "Mailing address", text: "123 Main St"))
        XCTAssertFalse(AutomationSafety.isSafeAddressBarSubmit(target: "Contact address", text: "123 Main St"))
    }

    func testSafeAddressBarSubmitRejectsBareAddressWord() {
        XCTAssertFalse(AutomationSafety.isSafeAddressBarSubmit(target: "Address", text: "hello"))
    }

    func testSafeAddressBarSubmitRejectsEmptyOrMultilineText() {
        XCTAssertFalse(AutomationSafety.isSafeAddressBarSubmit(target: "Address Bar", text: ""))
        XCTAssertFalse(AutomationSafety.isSafeAddressBarSubmit(target: "Address Bar", text: "   "))
        XCTAssertFalse(AutomationSafety.isSafeAddressBarSubmit(target: "Address Bar", text: "line one\nline two"))
    }

    // MARK: isRestrictedName (unchanged behavior — empty by design)

    func testRestrictedNameIsEmptyByDesign() {
        XCTAssertFalse(AutomationSafety.isRestrictedName("Terminal"))
        XCTAssertFalse(AutomationSafety.isRestrictedName("iTerm2"))
    }
}
