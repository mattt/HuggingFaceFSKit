//
//  HuggingFaceFSFileSystem.swift
//  HuggingFaceFS
//
//  Created by Mattt Zmuda on 3/23/26.
//

import Foundation
import FSKit

@objc
class HuggingFaceFSFileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
    private var volumesByResourceURL: [String: HFVolume] = [:]

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let spec = HFRepositorySpec.from(resource: resource) else {
            replyHandler(.notRecognized, nil)
            return
        }

        let container = FSContainerIdentifier()
        replyHandler(.usable(name: spec.repoID, containerID: container), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let spec = HFRepositorySpec.from(resource: resource) else {
            replyHandler(nil, fs_errorForPOSIXError(ENOTSUP))
            return
        }

        let backend = HFBackend(spec: spec)
        let volumeName = FSFileName(string: spec.repoName)
        let volumeID = FSVolume.Identifier(uuid: UUID())
        let volume = HFVolume(volumeID: volumeID, volumeName: volumeName, backend: backend)
        volumesByResourceURL[spec.cacheKey] = volume
        replyHandler(volume, nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
        guard let spec = HFRepositorySpec.from(resource: resource) else {
            return
        }
        volumesByResourceURL.removeValue(forKey: spec.cacheKey)
    }
}
