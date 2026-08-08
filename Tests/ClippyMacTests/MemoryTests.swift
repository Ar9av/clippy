import XCTest
@testable import ClippyCore
@testable import ClippyMac

final class MemoryMarkerTests: XCTestCase {
    func testExtractsTheFactAndStripsTheMarker() {
        let result = AIService.extractMemory(
            from: "Swift it is.\n[[CLIPPY_REMEMBER: Arnav is building a macOS assistant in Swift]]"
        )
        XCTAssertEqual(result.fact, "Arnav is building a macOS assistant in Swift")
        XCTAssertEqual(result.response, "Swift it is.")
    }

    func testLeavesAnOrdinaryReplyAlone() {
        let result = AIService.extractMemory(from: "Swift it is.")
        XCTAssertNil(result.fact)
        XCTAssertEqual(result.response, "Swift it is.")
    }

    /// The marker is an instruction to Clippy, not text for a human — an
    /// empty or malformed one must still never reach the balloon, the
    /// transcript, speech, or a field Clippy types into.
    func testStripsTheMarkerEvenWhenTheFactIsEmpty() {
        let result = AIService.extractMemory(from: "Noted.\n[[CLIPPY_REMEMBER: ]]")
        XCTAssertNil(result.fact)
        XCTAssertEqual(result.response, "Noted.")
    }

    func testStripsEveryOccurrence() {
        let result = AIService.extractMemory(
            from: "[[CLIPPY_REMEMBER: one]] Middle. [[CLIPPY_REMEMBER: two]]"
        )
        XCTAssertEqual(result.fact, "one")
        XCTAssertFalse(result.response.contains("CLIPPY_REMEMBER"))
    }
}

final class MemoryStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MemoryStore.forgetAll()
    }

    override func tearDown() {
        MemoryStore.forgetAll()
        super.tearDown()
    }

    func testRemembersAcrossLoads() {
        MemoryStore.remember("Arnav prefers short answers")
        XCTAssertEqual(MemoryStore.load().map(\.text), ["Arnav prefers short answers"])
    }

    /// The model is told not to repeat what it already knows and does it
    /// anyway over a long session; forty copies of the same fact would crowd
    /// out everything else in the prompt.
    func testIgnoresAFactItAlreadyKnows() {
        MemoryStore.remember("Arnav prefers short answers")
        MemoryStore.remember("arnav prefers short answers.")
        XCTAssertEqual(MemoryStore.load().count, 1)
    }

    func testIgnoresBlankFacts() {
        MemoryStore.remember("   ")
        XCTAssertTrue(MemoryStore.load().isEmpty)
    }

    func testForgettingRemovesOnlyThatFact() {
        MemoryStore.remember("first")
        let facts = MemoryStore.remember("second")
        let remaining = MemoryStore.forget(id: facts[0].id)
        XCTAssertEqual(remaining.map(\.text), ["second"])
    }

    func testDropsTheOldestPastTheLimit() {
        for index in 0..<45 { MemoryStore.remember("fact \(index)") }
        let facts = MemoryStore.load()
        XCTAssertEqual(facts.count, 40)
        XCTAssertEqual(facts.first?.text, "fact 5")
        XCTAssertEqual(facts.last?.text, "fact 44")
    }

    /// An empty header would tell the model "you know nothing about this
    /// user", which is a different and less useful claim than saying nothing.
    func testProducesNoPromptBlockWhenNothingIsKnown() {
        XCTAssertTrue(MemoryStore.promptBlock([]).isEmpty)
    }

    func testListsKnownFactsInThePromptBlock() {
        let block = MemoryStore.promptBlock([MemoryFact(text: "Arnav uses Swift")])
        XCTAssertTrue(block.contains("- Arnav uses Swift"))
    }
}
