import Foundation
import FSKit

final class HFItem: FSItem {
    let nodeID: UInt64

    init(nodeID: UInt64) {
        self.nodeID = nodeID
        super.init()
    }
}

@objc
final class HFVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, FSVolume.OpenCloseOperations {
    private let backend: HFBackend
    private let capabilities: FSVolume.SupportedCapabilities
    private let stats: FSStatFSResult
    private let lock = NSLock()
    private var itemCache: [UInt64: HFItem] = [:]

    init(volumeID: FSVolume.Identifier, volumeName: FSFileName, backend: HFBackend) {
        self.backend = backend
        self.capabilities = FSVolume.SupportedCapabilities()
        self.stats = FSStatFSResult(fileSystemTypeName: "hfmount")
        super.init(volumeID: volumeID, volumeName: volumeName)

        capabilities.supports64BitObjectIDs = true
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supports2TBFiles = true
        capabilities.caseFormat = .insensitiveCasePreserving
        capabilities.doesNotSupportSettingFilePermissions = true
        capabilities.doesNotSupportImmutableFiles = true
        capabilities.supportsFastStatFS = true
        capabilities.supportsSparseFiles = false
        capabilities.supportsOpenDenyModes = false
        capabilities.supportsHardLinks = false
        capabilities.supportsSymbolicLinks = false
        capabilities.doesNotSupportVolumeSizes = true

        stats.blockSize = 4096
        stats.ioSize = 4096
    }

    // MARK: - FSVolume.PathConfOperations

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64.max }

    // MARK: - FSVolume.Operations required properties

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        capabilities
    }

    var volumeStatistics: FSStatFSResult {
        stats
    }

    // MARK: - FSVolume.Operations lifecycle

    func activate(options: FSTaskOptions, replyHandler reply: @escaping @Sendable (FSItem?, (any Error)?) -> Void) {
        Task {
            do {
                try await backend.ensureLoaded()
                let root = item(for: FSItem.Identifier.rootDirectory.rawValue)
                reply(root, nil)
            } catch {
                reply(nil, fs_errorForPOSIXError(EIO))
            }
        }
    }

    func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        lock.lock()
        itemCache.removeAll()
        lock.unlock()
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping @Sendable () -> Void) {
        lock.lock()
        itemCache.removeAll()
        lock.unlock()
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - FSVolume.Operations attributes

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? HFItem else {
            reply(nil, fs_errorForPOSIXError(ENOENT))
            return
        }

        Task {
            guard let node = await backend.node(for: item.nodeID) else {
                reply(nil, fs_errorForPOSIXError(ENOENT))
                return
            }
            reply(makeAttributes(for: node), nil)
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void) {
        reply(nil, fs_errorForPOSIXError(EROFS))
    }

    // MARK: - FSVolume.Operations item ops

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let dir = directory as? HFItem, let childName = name.string else {
            reply(nil, nil, fs_errorForPOSIXError(ENOENT))
            return
        }

        Task {
            guard let child = await backend.childNode(named: childName, in: dir.nodeID) else {
                reply(nil, nil, fs_errorForPOSIXError(ENOENT))
                return
            }

            reply(item(for: child.id), FSFileName(string: child.name), nil)
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        guard let item = item as? HFItem else {
            reply(nil)
            return
        }
        lock.lock()
        itemCache.removeValue(forKey: item.nodeID)
        lock.unlock()
        reply(nil)
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler reply: @escaping @Sendable (FSDirectoryVerifier, (any Error)?) -> Void) {
        guard let dir = directory as? HFItem else {
            reply(verifier, fs_errorForPOSIXError(ENOENT))
            return
        }

        Task {
            let children = await backend.children(in: dir.nodeID)
            let startIndex = Int(cookie.rawValue)
            if startIndex < 0 || startIndex > children.count {
                reply(verifier, fs_errorForPOSIXError(EINVAL))
                return
            }

            for index in startIndex..<children.count {
                let child = children[index]
                let maybeAttrs = attributes == nil ? nil : makeAttributes(for: child)
                let didPack = packer.packEntry(
                    name: FSFileName(string: child.name),
                    itemType: child.type,
                    itemID: FSItem.Identifier(rawValue: child.id) ?? .invalid,
                    nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                    attributes: maybeAttrs
                )
                if !didPack {
                    break
                }
            }

            reply(FSDirectoryVerifier(1), nil)
        }
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        reply(nil, fs_errorForPOSIXError(ENOTSUP))
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, fs_errorForPOSIXError(EROFS))
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, fs_errorForPOSIXError(EROFS))
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        reply(nil, fs_errorForPOSIXError(EROFS))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(fs_errorForPOSIXError(EROFS))
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        reply(nil, fs_errorForPOSIXError(EROFS))
    }

    // MARK: - FSVolume.ReadWriteOperations

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void) {
        guard let item = item as? HFItem else {
            reply(0, fs_errorForPOSIXError(ENOENT))
            return
        }

        Task {
            guard offset >= 0 else {
                reply(0, fs_errorForPOSIXError(EINVAL))
                return
            }
            do {
                let data = try await backend.read(nodeID: item.nodeID, offset: UInt64(offset), length: length)
                if data.isEmpty {
                    reply(0, nil)
                    return
                }

                let copied = min(data.count, buffer.length)
                _ = try buffer.withUnsafeMutableBytes { rawBuffer in
                    guard let destination = rawBuffer.baseAddress else { return }
                    data.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: copied)
                }
                reply(copied, nil)
            } catch let error as NSError {
                reply(0, error)
            } catch {
                reply(0, fs_errorForPOSIXError(EIO))
            }
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void) {
        reply(0, fs_errorForPOSIXError(EROFS))
    }

    // MARK: - FSVolume.OpenCloseOperations

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        if modes.contains(.write) {
            reply(fs_errorForPOSIXError(EROFS))
            return
        }
        reply(nil)
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Helpers

    private func item(for nodeID: UInt64) -> HFItem {
        lock.lock()
        defer { lock.unlock() }
        if let existing = itemCache[nodeID] {
            return existing
        }
        let created = HFItem(nodeID: nodeID)
        itemCache[nodeID] = created
        return created
    }

    private func makeAttributes(for node: HFNode) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.fileID = FSItem.Identifier(rawValue: node.id) ?? .invalid
        attrs.parentID = FSItem.Identifier(rawValue: node.parentID) ?? .invalid
        attrs.type = node.type
        attrs.mode = node.type == .directory ? 0o40555 : 0o100444
        attrs.linkCount = 1
        attrs.uid = getuid()
        attrs.gid = getgid()
        attrs.size = node.size
        attrs.allocSize = node.size

        let when = node.mtime.timeIntervalSince1970
        let sec = Int(when)
        let nsec = Int((when - Double(sec)) * 1_000_000_000)
        let ts = timespec(tv_sec: sec, tv_nsec: nsec)
        attrs.accessTime = ts
        attrs.modifyTime = ts
        attrs.changeTime = ts
        attrs.birthTime = ts
        return attrs
    }
}
