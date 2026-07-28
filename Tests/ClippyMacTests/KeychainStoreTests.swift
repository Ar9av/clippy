import XCTest
@testable import ClippyCore

final class KeychainStoreTests: XCTestCase {
    // A dedicated account name so this never collides with a real
    // provider's stored key.
    private let account = "com.ar9av.clippy.tests.keychain-store"

    override func tearDown() {
        KeychainStore.delete(account: account)
        super.tearDown()
    }

    func testReadReturnsNilWhenNothingWasEverSaved() {
        XCTAssertNil(KeychainStore.read(account: account))
    }

    func testSaveThenReadRoundTrips() throws {
        try KeychainStore.save("sk-test-12345", account: account)
        XCTAssertEqual(KeychainStore.read(account: account), "sk-test-12345")
    }

    func testSaveOverwritesAPreviousValue() throws {
        try KeychainStore.save("first-value", account: account)
        try KeychainStore.save("second-value", account: account)
        XCTAssertEqual(KeychainStore.read(account: account), "second-value")
    }

    func testDeleteRemovesTheStoredValue() throws {
        try KeychainStore.save("to-be-deleted", account: account)
        KeychainStore.delete(account: account)
        XCTAssertNil(KeychainStore.read(account: account))
    }

    func testDeleteOnAnAccountThatWasNeverSavedDoesNotThrow() {
        KeychainStore.delete(account: account)
    }

    func testDifferentAccountsAreIsolated() throws {
        let otherAccount = account + ".other"
        try KeychainStore.save("value-a", account: account)
        try KeychainStore.save("value-b", account: otherAccount)
        XCTAssertEqual(KeychainStore.read(account: account), "value-a")
        XCTAssertEqual(KeychainStore.read(account: otherAccount), "value-b")
        KeychainStore.delete(account: otherAccount)
    }
}
