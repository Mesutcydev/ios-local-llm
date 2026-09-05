// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAI
import CoreAIShared
import Darwin

/// Fixed-size storage for persistent convolution, recurrent, and sliding-cache states.
public struct FixedNDArrayState: SyncStateHandler {
    public let stateNames: [String]
    public let supportsTruncation = false
    public let currentCapacity = Int.max
    public var stateCount: Int { arrays.count }

    private var arrays: [(name: String, array: NDArray)]

    public init(states: [(name: String, descriptor: NDArrayDescriptor)]) {
        var arrays: [(String, NDArray)] = []
        for (name, descriptor) in states {
            var array = NDArray(descriptor: descriptor)
            zeroFillNDArray(&array)
            arrays.append((name, array))
        }
        self.arrays = arrays
        self.stateNames = states.map(\.name)
    }

    public mutating func ensureCapacity(forContextLength contextLength: Int) throws -> Bool {
        false
    }

    public subscript(stateIndex index: Int) -> (name: String, array: NDArray) {
        get { arrays[index] }
        set { arrays[index] = newValue }
    }

    public mutating func reset() {
        for index in arrays.indices {
            zeroFillNDArray(&arrays[index].array)
        }
    }

    public mutating func truncate(to tokenCount: Int) {
        preconditionFailure("truncate(to:) called on non-truncatable FixedNDArrayState")
    }
}

/// Dynamically growing storage for KV-cache state.
public struct GrowingNDArrayState: SyncStateHandler {
    public let stateNames: [String]
    public let supportsTruncation = true
    public private(set) var currentCapacity: Int
    public var stateCount: Int { arrays.count }

    private var arrays: [(name: String, array: NDArray)]
    private let descriptors: [NDArrayDescriptor]
    private let maxCapacity: Int
    private let sequenceDimension: Int

    public init(
        states: [(name: String, descriptor: NDArrayDescriptor)],
        initialCapacity: Int,
        maxCapacity: Int
    ) {
        self.stateNames = states.map(\.name)
        self.descriptors = states.map(\.descriptor)
        self.maxCapacity = maxCapacity

        let firstDescriptor = states[0].descriptor
        self.sequenceDimension = firstDescriptor.shape.firstIndex(where: { $0 < 0 })
            ?? max(0, firstDescriptor.shape.count - 2)

        let capacity = min(initialCapacity, maxCapacity)
        self.currentCapacity = capacity
        self.arrays = states.map { name, descriptor in
            let resolved = descriptor.resolvingDynamicDimensions(
                descriptor.shape.map { $0 < 0 ? capacity : $0 })
            return (name, NDArray(descriptor: resolved))
        }
    }

    public mutating func ensureCapacity(forContextLength contextLength: Int) throws -> Bool {
        guard contextLength > currentCapacity else { return false }
        guard contextLength <= maxCapacity else {
            throw InferenceRuntimeError.invalidState(
                "Context length \(contextLength) exceeds maximum \(maxCapacity)")
        }

        var newCapacity = max(currentCapacity, 1)
        while newCapacity < contextLength {
            newCapacity = min(newCapacity * 2, maxCapacity)
        }

        for index in arrays.indices {
            let descriptor = descriptors[index]
            let resolved = descriptor.resolvingDynamicDimensions(
                descriptor.shape.map { $0 < 0 ? newCapacity : $0 })
            var newArray = NDArray(descriptor: resolved)
            _ = newArray.mutableRawView()
            copyCache(
                from: arrays[index].array,
                to: &newArray,
                sequenceDimension: sequenceDimension
            )
            arrays[index].array = newArray
        }

        currentCapacity = newCapacity
        return true
    }

    public subscript(stateIndex index: Int) -> (name: String, array: NDArray) {
        get { arrays[index] }
        set { arrays[index] = newValue }
    }

    public mutating func reset() {
        for index in arrays.indices {
            zeroFillNDArray(&arrays[index].array)
        }
    }

    public mutating func truncate(to tokenCount: Int) {}

    private func copyCache(
        from source: NDArray,
        to destination: inout NDArray,
        sequenceDimension: Int
    ) {
        let sourceShape = source.shape
        let destinationShape = destination.shape
        guard let headDimension = sourceShape.last else { return }

        let blockCount = sourceShape[..<sequenceDimension].reduce(1, *)
        let copyElementCount = sourceShape[sequenceDimension] * headDimension
        let sourceStride = sourceShape[sequenceDimension...].reduce(1, *)
        let destinationStride = destinationShape[sequenceDimension...].reduce(1, *)

        switch source.scalarType {
        case .float16, .bfloat16:
            source.view(as: Float16.self).withUnsafePointer { sourcePointer, _, _ in
                var destinationView = destination.mutableView(as: Float16.self)
                destinationView.withUnsafeMutablePointer { destinationPointer, _, _ in
                    for block in 0..<blockCount {
                        destinationPointer.advanced(by: block * destinationStride).update(
                            from: sourcePointer.advanced(by: block * sourceStride),
                            count: copyElementCount
                        )
                    }
                }
            }
        case .float32:
            source.view(as: Float.self).withUnsafePointer { sourcePointer, _, _ in
                var destinationView = destination.mutableView(as: Float.self)
                destinationView.withUnsafeMutablePointer { destinationPointer, _, _ in
                    for block in 0..<blockCount {
                        destinationPointer.advanced(by: block * destinationStride).update(
                            from: sourcePointer.advanced(by: block * sourceStride),
                            count: copyElementCount
                        )
                    }
                }
            }
        default:
            preconditionFailure("Unsupported scalar type for state copy: \(source.scalarType)")
        }
    }
}

func zeroFillNDArray(_ array: inout NDArray) {
    let count = array.shape.reduce(1, *)
    switch array.scalarType {
    case .float16, .bfloat16:
        var view = array.mutableView(as: Float16.self)
        view.withUnsafeMutablePointer { pointer, _, _ in
            memset(pointer, 0, count * MemoryLayout<Float16>.size)
        }
    case .float32:
        var view = array.mutableView(as: Float.self)
        view.withUnsafeMutablePointer { pointer, _, _ in
            memset(pointer, 0, count * MemoryLayout<Float>.size)
        }
    default:
        preconditionFailure("Unsupported scalar type for state: \(array.scalarType)")
    }
}
