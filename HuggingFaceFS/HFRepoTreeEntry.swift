import Foundation

struct HFRepoTreeEntry: Decodable {
    struct LFS: Decodable {
        let size: UInt64
    }

    struct LastCommit: Decodable {
        let date: Date?

        private enum CodingKeys: String, CodingKey {
            case date
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let timestamp = try? container.decode(String.self, forKey: .date) else {
                date = try container.decodeIfPresent(Date.self, forKey: .date)
                return
            }

            let format = Date.ISO8601FormatStyle(includingFractionalSeconds: timestamp.contains("."))
            guard let parsedDate = try? format.parse(timestamp) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .date, in: container, debugDescription: "Expected an ISO 8601 timestamp."
                )
            }
            date = parsedDate
        }
    }

    let path: String
    let entryType: String
    let size: UInt64?
    let lfs: LFS?
    let xetHash: String?
    let lastCommit: LastCommit?

    var realSize: UInt64 {
        lfs?.size ?? size ?? 0
    }

    var commitDate: Date? {
        lastCommit?.date
    }

    enum CodingKeys: String, CodingKey {
        case path
        case entryType = "type"
        case size
        case lfs
        case xetHash
        case xet_hash
        case lastCommit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        entryType = try container.decode(String.self, forKey: .entryType)
        size = try container.decodeIfPresent(UInt64.self, forKey: .size)
        lfs = try container.decodeIfPresent(LFS.self, forKey: .lfs)
        xetHash =
            try container.decodeIfPresent(String.self, forKey: .xetHash)
            ?? container.decodeIfPresent(String.self, forKey: .xet_hash)
        lastCommit = try container.decodeIfPresent(LastCommit.self, forKey: .lastCommit)
    }
}
