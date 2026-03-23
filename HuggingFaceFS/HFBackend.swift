import Foundation
import FSKit
import Security
import Xet

enum HFRepoType: String {
    case model
    case dataset
    case space

    var treePrefix: String {
        switch self {
        case .model: "models"
        case .dataset: "datasets"
        case .space: "spaces"
        }
    }
}

struct HFRepositorySpec: Sendable {
    let repoType: HFRepoType
    let repoID: String
    let revision: String

    var repoName: String {
        repoID.split(separator: "/").last.map(String.init) ?? repoID
    }

    var cacheKey: String {
        "\(repoType.rawValue):\(repoID):\(revision)"
    }

    var treeURL: URL {
        URL(string: "https://huggingface.co/api/\(repoType.treePrefix)/\(repoID)/tree/\(revision)?expand=true&recursive=true")!
    }

    var refreshURL: URL {
        URL(string: "https://huggingface.co/api/\(repoType.treePrefix)/\(repoID)/xet-read-token/\(revision)")!
    }

    func resolveURL(path: String) -> URL {
        URL(string: "https://huggingface.co/\(repoType.treePrefix)/\(repoID)/resolve/\(revision)/\(path)")!
    }

    static func from(resource: FSResource) -> HFRepositorySpec? {
        guard let object = resource as? NSObject else {
            return nil
        }
        guard object.responds(to: Selector(("url"))) else {
            return nil
        }
        guard let value = object.value(forKey: "url") as? URL else {
            return nil
        }
        return from(url: value)
    }

    static func from(url: URL) -> HFRepositorySpec? {
        let revision = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { ["rev", "revision"].contains($0.name) })?
            .value ?? "main"

        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard components.count >= 2 else {
            return nil
        }

        if components.first == "datasets", components.count >= 3 {
            return HFRepositorySpec(repoType: .dataset, repoID: components[1...2].joined(separator: "/"), revision: revision)
        }
        if components.first == "models", components.count >= 3 {
            return HFRepositorySpec(repoType: .model, repoID: components[1...2].joined(separator: "/"), revision: revision)
        }
        if components.first == "spaces", components.count >= 3 {
            return HFRepositorySpec(repoType: .space, repoID: components[1...2].joined(separator: "/"), revision: revision)
        }

        return HFRepositorySpec(repoType: .model, repoID: components[0...1].joined(separator: "/"), revision: revision)
    }
}

struct HFNode: Sendable {
    let id: UInt64
    let parentID: UInt64
    let name: String
    let path: String
    let type: FSItem.ItemType
    let size: UInt64
    let mtime: Date
    let xetHash: String?
}

actor HFBackend {
    private let spec: HFRepositorySpec
    private let session: URLSession
    private var loaded = false
    private var nextID: UInt64 = 3
    private var nodesByID: [UInt64: HFNode] = [:]
    private var idByPath: [String: UInt64] = [:]
    private var childrenByParentID: [UInt64: [String: UInt64]] = [:]

    init(spec: HFRepositorySpec) {
        self.spec = spec
        self.session = URLSession(configuration: .ephemeral)
    }

    func ensureLoaded() async throws {
        guard !loaded else { return }
        try await loadTree()
        loaded = true
    }

    func rootNode() -> HFNode {
        HFNode(
            id: FSItem.Identifier.rootDirectory.rawValue,
            parentID: FSItem.Identifier.parentOfRoot.rawValue,
            name: "",
            path: "",
            type: .directory,
            size: 0,
            mtime: .now,
            xetHash: nil
        )
    }

    func node(for id: UInt64) -> HFNode? {
        if id == FSItem.Identifier.rootDirectory.rawValue {
            return rootNode()
        }
        return nodesByID[id]
    }

    func childNode(named name: String, in parentID: UInt64) -> HFNode? {
        guard let childID = childrenByParentID[parentID]?[name] else { return nil }
        return node(for: childID)
    }

    func children(in parentID: UInt64) -> [HFNode] {
        let ids: [UInt64]
        if let values = childrenByParentID[parentID]?.values {
            ids = Array(values)
        } else {
            ids = []
        }
        return ids.compactMap { node(for: $0) }.sorted { $0.name < $1.name }
    }

    func read(nodeID: UInt64, offset: UInt64, length: Int) async throws -> Data {
        guard let node = node(for: nodeID), node.type == .file else {
            throw fs_errorForPOSIXError(EISDIR)
        }

        guard length > 0 else { return Data() }
        guard offset < node.size else { return Data() }

        let cappedLength = min(UInt64(length), node.size - offset)
        let range = offset..<(offset + cappedLength)
        let fileID = try await fileID(for: node)
        let token = SharedHFTokenStore.readAccessToken()
        return try await Xet.withDownloader(refreshURL: spec.refreshURL, hubToken: token) { downloader in
            try await downloader.data(for: fileID, byteRange: range)
        }
    }

    private func loadTree() async throws {
        var pendingURL = spec.treeURL
        let decoder = JSONDecoder()

        ensureDirectory(path: "", parentID: FSItem.Identifier.parentOfRoot.rawValue, name: "", fixedID: FSItem.Identifier.rootDirectory.rawValue)

        while true {
            let (data, response) = try await session.data(from: pendingURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw fs_errorForPOSIXError(EIO)
            }

            let entries = try decoder.decode([HFRepoTreeEntry].self, from: data)
            for entry in entries {
                ingest(entry: entry)
            }

            guard let next = nextURL(from: http) else { break }
            pendingURL = next
        }
    }

    private func ingest(entry: HFRepoTreeEntry) {
        let components = entry.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }

        var parentID = FSItem.Identifier.rootDirectory.rawValue
        var currentPath = ""
        for index in components.indices {
            let name = components[index]
            currentPath = currentPath.isEmpty ? name : "\(currentPath)/\(name)"
            let isLeaf = index == components.indices.last
            let isDirectory = isLeaf ? (entry.entryType == "directory") : true
            let type: FSItem.ItemType = isDirectory ? .directory : .file
            let size = isDirectory ? 0 : entry.realSize
            let mtime = entry.commitDate ?? .now
            let hash = isDirectory ? nil : entry.xetHash
            parentID = ensureNode(path: currentPath, parentID: parentID, name: name, type: type, size: size, mtime: mtime, xetHash: hash)
        }
    }

    private func ensureNode(
        path: String,
        parentID: UInt64,
        name: String,
        type: FSItem.ItemType,
        size: UInt64,
        mtime: Date,
        xetHash: String?
    ) -> UInt64 {
        if let existing = idByPath[path] {
            if var node = nodesByID[existing], node.type == .file {
                nodesByID[existing] = HFNode(
                    id: node.id,
                    parentID: node.parentID,
                    name: node.name,
                    path: node.path,
                    type: node.type,
                    size: size,
                    mtime: mtime,
                    xetHash: xetHash ?? node.xetHash
                )
            }
            return existing
        }

        let id = nextID
        nextID += 1
        let node = HFNode(
            id: id,
            parentID: parentID,
            name: name,
            path: path,
            type: type,
            size: size,
            mtime: mtime,
            xetHash: xetHash
        )
        nodesByID[id] = node
        idByPath[path] = id
        childrenByParentID[parentID, default: [:]][name] = id
        return id
    }

    private func ensureDirectory(path: String, parentID: UInt64, name: String, fixedID: UInt64? = nil) {
        if let fixedID {
            let node = HFNode(
                id: fixedID,
                parentID: parentID,
                name: name,
                path: path,
                type: .directory,
                size: 0,
                mtime: .now,
                xetHash: nil
            )
            nodesByID[fixedID] = node
            idByPath[path] = fixedID
            childrenByParentID[parentID, default: [:]][name] = fixedID
            return
        }

        _ = ensureNode(
            path: path,
            parentID: parentID,
            name: name,
            type: .directory,
            size: 0,
            mtime: .now,
            xetHash: nil
        )
    }

    private func fileID(for node: HFNode) async throws -> String {
        if let hash = node.xetHash, hash.count == 64 {
            return hash
        }

        var request = URLRequest(url: spec.resolveURL(path: node.path))
        request.httpMethod = "HEAD"
        let delegate = HFNoRedirectDelegate()
        let (_, response) = try await session.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            throw fs_errorForPOSIXError(EIO)
        }

        if let hash = http.value(forHTTPHeaderField: "x-xet-hash"), hash.count == 64 {
            if var existing = nodesByID[node.id] {
                existing = HFNode(
                    id: existing.id,
                    parentID: existing.parentID,
                    name: existing.name,
                    path: existing.path,
                    type: existing.type,
                    size: existing.size,
                    mtime: existing.mtime,
                    xetHash: hash
                )
                nodesByID[node.id] = existing
            }
            return hash
        }
        throw fs_errorForPOSIXError(ENOENT)
    }

    private func nextURL(from response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else {
            return nil
        }
        for segment in link.split(separator: ",") {
            let parts = segment.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, first.hasPrefix("<"), first.hasSuffix(">") else { continue }
            let isNext = parts.contains { $0 == "rel=\"next\"" }
            if isNext {
                return URL(string: String(first.dropFirst().dropLast()))
            }
        }
        return nil
    }
}

private enum SharedHFTokenStore {
    private static let service = "co.dododo.HuggingFaceMount"
    private static let account = "hf_access_token"
    private static let logicalAccessGroupSuffix = ".co.dododo.HuggingFaceMount.shared"

    static func readAccessToken() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let group = accessGroup() {
            query[kSecAttrAccessGroup as String] = group
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func accessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return nil
        }
        guard let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) else {
            return nil
        }
        guard let groups = value as? [String] else {
            return nil
        }
        for group in groups {
            if group.hasSuffix(logicalAccessGroupSuffix) {
                return group
            }
        }
        return groups.first
    }
}

private final class HFNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct HFRepoTreeEntry: Decodable {
    struct LFS: Decodable {
        let size: UInt64
    }

    struct LastCommit: Decodable {
        let date: Date?
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
