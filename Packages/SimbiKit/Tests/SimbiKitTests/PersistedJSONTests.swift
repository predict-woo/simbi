import Foundation
import Testing

@testable import SimbiKit

@Suite("PersistedJSON")
struct PersistedJSONTests {
    private struct Sample: Codable {
        var zebra: Int
        var apple: Int
        var when: Date
    }

    @Test("house style: pretty, key-sorted, ISO 8601 dates")
    func houseStyle() throws {
        let sample = Sample(zebra: 1, apple: 2, when: Date(timeIntervalSince1970: 0))
        let text = String(
            decoding: try PersistedJSON.encoder().encode(sample), as: UTF8.self)
        // Sorted keys: apple before when before zebra.
        let apple = try #require(text.range(of: "apple"))
        let zebra = try #require(text.range(of: "zebra"))
        #expect(apple.lowerBound < zebra.lowerBound)
        // Pretty-printed (multi-line) with an ISO 8601 date.
        #expect(text.contains("\n"))
        #expect(text.contains("1970-01-01T00:00:00Z"))
    }
}
