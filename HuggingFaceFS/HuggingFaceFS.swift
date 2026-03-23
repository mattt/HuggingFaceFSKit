//
//  HuggingFaceFS.swift
//  HuggingFaceFS
//
//  Created by Mattt Zmuda on 3/23/26.
//

import ExtensionFoundation
import Foundation
import FSKit

@main
struct HuggingFaceFS : UnaryFileSystemExtension {
    var fileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
        HuggingFaceFSFileSystem()
    }
}
