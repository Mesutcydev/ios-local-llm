// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAI

/// Persistent model state that the engine carries across inference steps.
public protocol SyncStateHandler {
    var stateNames: [String] { get }
    var stateCount: Int { get }
    var currentCapacity: Int { get }
    var supportsTruncation: Bool { get }

    mutating func ensureCapacity(forContextLength contextLength: Int) throws -> Bool
    subscript(stateIndex index: Int) -> (name: String, array: NDArray) { get set }
    mutating func reset()
    mutating func truncate(to tokenCount: Int)
}
