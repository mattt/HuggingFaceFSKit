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
    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        replyHandler(.notRecognized, nil)
    }
    
    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        replyHandler(FSVolume(volumeID: .init(uuid: UUID()), volumeName: FSFileName(string: "My Volume")), nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
    }
}
