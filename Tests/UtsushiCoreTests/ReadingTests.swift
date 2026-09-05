import XCTest

// Reading と EditGate はこのアプリの安全性の中核なので、
// 「通ってはいけないものが通らない」ことを重点的に固定する。
final class ReadingTests: XCTestCase {

    func testHomophonesShareKey() {
        XCTAssertEqual(Reading.key("機構"), Reading.key("気候"))
        XCTAssertEqual(Reading.key("以外"), Reading.key("意外"))
        XCTAssertEqual(Reading.key("シュウショク活動"), Reading.key("就職活動"))
    }

    func testDifferentWordsDifferentKey() {
        XCTAssertNotEqual(Reading.key("株式会社新小物"), Reading.key("株式会社BeeX"))
        XCTAssertNotEqual(Reading.key("御社"), Reading.key("貴社"))
    }

    func testPunctuationDoesNotAffectKey() {
        XCTAssertEqual(Reading.key("弊社の対応"), Reading.key("弊社の、対応。"))
        XCTAssertEqual(Reading.key("これはテストです"), Reading.key("これは、テストです！"))
    }

    func testEmptyAndSymbolOnly() {
        XCTAssertEqual(Reading.key(""), "")
        XCTAssertTrue(Reading.isUsable(""))
        XCTAssertTrue(Reading.isUsable("こんにちは"))
    }
}

final class EditGateTests: XCTestCase {
    private let gate = EditGate()

    func testAcceptsHomophoneFix() {
        XCTAssertTrue(gate.evaluate(original: "機構変動が激しい", proposed: "気候変動が激しい").isAccepted)
    }

    func testAcceptsPunctuationInsertion() {
        XCTAssertTrue(gate.evaluate(original: "本日はお集まりいただきありがとうございます",
                                    proposed: "本日は、お集まりいただきありがとうございます。").isAccepted)
    }

    func testRejectsReadingChange() {
        let v = gate.evaluate(original: "株式会社新小物という会社です",
                              proposed: "株式会社BeeXという会社です")
        XCTAssertEqual(v, .reject(.newLatinToken))
    }

    func testRejectsSemanticSwap() {
        let v = gate.evaluate(original: "御社を志望した理由は", proposed: "貴社を志望した理由は")
        XCTAssertEqual(v, .reject(.readingChanged))
    }

    func testRejectsInventedContent() {
        let v = gate.evaluate(original: "本日はありがとうございました",
                              proposed: "本日は貴重なお時間をいただき誠にありがとうございました")
        if case .reject = v {} else { XCTFail("水増しが通ってはいけない: \(v)") }
    }

    func testRejectsEmptying() {
        XCTAssertEqual(gate.evaluate(original: "はい", proposed: ""), .reject(.emptyResult))
    }

    func testRejectsNewLatinToken() {
        let v = gate.evaluate(original: "エスエーピーの導入支援", proposed: "SAPの導入支援")
        XCTAssertEqual(v, .reject(.newLatinToken))
    }

    func testDictionaryAllowsRegisteredReplacement() {
        let dict = UserDictionary(entries: [
            .init(surface: "BeeX", reading: "びーえっくす", misspellings: ["新小物"])
        ])
        let g = EditGate(policy: EditGate.Policy(), dictionary: dict)
        XCTAssertTrue(g.evaluate(original: "株式会社新小物です", proposed: "株式会社BeeXです").isAccepted)
    }

    func testIdenticalIsAccepted() {
        XCTAssertTrue(gate.evaluate(original: "変更なし", proposed: "変更なし").isAccepted)
    }

    func testLevenshtein() {
        XCTAssertEqual(TextDistance.levenshtein(Array("kitten"), Array("sitting")), 3)
        XCTAssertEqual(TextDistance.levenshtein(Array(""), Array("abc")), 3)
    }
}
