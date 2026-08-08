import XCTest
@testable import ClippyCore

/// The guardrail's own tests. `AutomationSafetyTests` still pins the
/// behaviour callers depend on (and passes unchanged against the policy that
/// replaced the hardcoded lists); these cover the policy layer itself — the
/// parts that could fail silently.
final class PrismorPolicyTests: XCTestCase {
    /// The shipped policy must actually load. If this fails, every screen
    /// action in the built app is being refused.
    func testTheShippedPolicyLoads() {
        XCTAssertFalse(PrismorPolicy.active.isFailClosed)
        XCTAssertFalse(PrismorPolicy.active.activeRuleSummaries.isEmpty)
    }

    /// A rule id that doesn't exist matches nothing, so a typo in
    /// `AutomationSafety.PolicyID` would disable a guardrail without any
    /// error. Assert every identifier the code asks for is really in the
    /// policy.
    func testEveryIdentifierThisCodeAsksForExists() {
        let policy = PrismorPolicy.active
        XCTAssertTrue(policy.matches(ruleID: AutomationSafety.PolicyID.finalAction, value: "Send"))
        XCTAssertTrue(policy.matches(ruleID: AutomationSafety.PolicyID.secureField, value: "AXSecureTextField"))
        XCTAssertTrue(policy.isAllowed(entryID: AutomationSafety.PolicyID.addressBarSubmit, value: "Address and Search"))
        // Disabled in the shipped policy, but present — so `enabled: true`
        // is all it takes to restore it.
        XCTAssertTrue(policy.activeRuleSummaries.joined().contains("gui-return-key"))
    }

    // MARK: - Failing closed

    /// The whole reason the policy is allowed to be a file: losing it must
    /// stop Clippy acting, not stop Clippy checking.
    func testAMissingPolicyRefusesEveryControl() {
        let policy = PrismorPolicy.denyAll
        XCTAssertTrue(policy.isFailClosed)
        XCTAssertFalse(policy.matches(ruleID: "gui-final-action", value: "Send"))
    }

    func testCorruptPolicyDataIsRejectedRatherThanPartiallyApplied() {
        XCTAssertThrowsError(try PrismorPolicy(data: Data("{ not json".utf8)))
    }

    /// A rule with an uncompilable regex would never match — a hole that
    /// looks exactly like a rule that's working. The whole policy is refused
    /// instead.
    func testAnUncompilableRuleRejectsTheWholePolicy() throws {
        let json = """
        {"version":"1.0","rules":[{"id":"broken","severity":"HIGH","category":"x",
        "title":"x","event_types":["ui_action"],"patterns":["[unterminated"],
        "action":"block","mode":"enforce"}]}
        """
        XCTAssertThrowsError(try PrismorPolicy(data: Data(json.utf8)))
    }

    // MARK: - Warden semantics

    func testObserveModeRulesDoNotBlock() throws {
        let policy = try PrismorPolicy(data: Data(Self.policy(mode: "observe").utf8))
        XCTAssertFalse(policy.matches(ruleID: "test-rule", value: "danger"))
    }

    func testEnforceModeRulesBlock() throws {
        let policy = try PrismorPolicy(data: Data(Self.policy(mode: "enforce").utf8))
        XCTAssertTrue(policy.matches(ruleID: "test-rule", value: "danger"))
    }

    func testDisabledRulesMatchNothing() throws {
        let json = Self.policy(mode: "enforce").replacingOccurrences(
            of: "\"action\":\"block\"",
            with: "\"action\":\"block\",\"enabled\":false"
        )
        let policy = try PrismorPolicy(data: Data(json.utf8))
        XCTAssertFalse(policy.matches(ruleID: "test-rule", value: "danger"))
    }

    /// Warden's strengthen-only override semantics.
    func testAddPatternsExtendARule() throws {
        let json = Self.policy(mode: "enforce").replacingOccurrences(
            of: "\"action\":\"block\"",
            with: "\"action\":\"block\",\"add_patterns\":[\"extra\"]"
        )
        let policy = try PrismorPolicy(data: Data(json.utf8))
        XCTAssertTrue(policy.matches(ruleID: "test-rule", value: "extra"))
    }

    func testDisablePatternsRemoveOneByExactString() throws {
        let json = Self.policy(mode: "enforce").replacingOccurrences(
            of: "\"action\":\"block\"",
            with: "\"action\":\"block\",\"disable_patterns\":[\"danger\"]"
        )
        let policy = try PrismorPolicy(data: Data(json.utf8))
        XCTAssertFalse(policy.matches(ruleID: "test-rule", value: "danger"))
    }

    // MARK: - The address-bar exception

    /// The exception exists so Clippy can navigate. It must not leak onto
    /// form fields that merely contain the word "address" — the veto entry
    /// is checked before any permission is granted.
    func testTheAddressBarExceptionNeverReachesFormFields() {
        for target in ["Email address", "Billing address", "Shipping address", "Recipient address"] {
            XCTAssertFalse(
                AutomationSafety.isSafeAddressBarSubmit(target: target, text: "hello"),
                target
            )
        }
    }

    func testTheAddressBarExceptionCoversRealBrowserChrome() {
        for target in ["Address and Search", "Omnibox", "Location bar", "URL"] {
            XCTAssertTrue(
                AutomationSafety.isSafeAddressBarSubmit(target: target, text: "example.com"),
                target
            )
        }
    }

    private static func policy(mode: String) -> String {
        """
        {"version":"1.0","rules":[{"id":"test-rule","severity":"HIGH","category":"x",
        "title":"x","event_types":["ui_action"],"patterns":["danger"],
        "action":"block","mode":"\(mode)"}]}
        """
    }
}
