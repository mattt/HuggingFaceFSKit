import Foundation

// From the repository root, compile and run this offline check:
// xcrun swiftc HuggingFaceFS/HFRepoTreeEntry.swift Tests/TreeCommitDates.swift -o /tmp/test-tree-commit-dates
// /tmp/test-tree-commit-dates
@main
enum TreeCommitDates {
    static func main() throws {
        let page = #"""
        [
            {"type":"file","path":"whole","lastCommit":{"date":"2024-01-01T00:00:00Z"}},
            {"type":"file","path":"fraction","lastCommit":{"date":"2024-01-01T00:00:00.125Z"}},
            {"type":"file","path":"offset","lastCommit":{"date":"2024-01-01T01:00:00+01:00"}},
            {"type":"file","path":"numeric","lastCommit":{"date":42.5}},
            {"type":"file","path":"null-date","lastCommit":{"date":null}},
            {"type":"file","path":"missing-date","lastCommit":{}},
            {"type":"file","path":"null-commit","lastCommit":null},
            {"type":"directory","path":"missing-commit"}
        ]
        """#
        let entries = try JSONDecoder().decode([HFRepoTreeEntry].self, from: Data(page.utf8))
        let midnight = Date(timeIntervalSince1970: 1_704_067_200)
        let expected: [Date?] = [
            midnight, midnight.addingTimeInterval(0.125), midnight,
            Date(timeIntervalSinceReferenceDate: 42.5), nil, nil, nil, nil,
        ]
        precondition(entries.map(\.commitDate) == expected, "Unexpected tree commit dates")

        let invalid = #"[{"type":"file","path":"invalid","lastCommit":{"date":"yesterday"}}]"#
        do {
            _ = try JSONDecoder().decode([HFRepoTreeEntry].self, from: Data(invalid.utf8))
            preconditionFailure("Accepted an invalid commit date")
        } catch DecodingError.dataCorrupted(let context) {
            precondition(context.codingPath.last?.stringValue == "date")
        }
    }
}
