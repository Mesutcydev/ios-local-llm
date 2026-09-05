// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAI
import CoreAIShared
import Metal

/// Fixed-size Metal storage for persistent states used by the pipelined engine.
public final class FixedMTLBufferState {
    public let stateNames: [String]
    public var stateCount: Int { bindings.count }

    private var bindings: [(
        name: String,
        buffer: MTLBuffer,
        scalarType: NDArray.ScalarType,
        shape: [Int],
        strides: [Int]
    )]

    public init(
        states: [(name: String, descriptor: NDArrayDescriptor)],
        device: MTLDevice
    ) throws {
        var bindings: [(String, MTLBuffer, NDArray.ScalarType, [Int], [Int])] = []
        for (name, descriptor) in states {
            guard !descriptor.shape.contains(where: { $0 < 0 }) else {
                throw InferenceRuntimeError.invalidOutputType(
                    "FixedMTLBufferState '\(name)' has dynamic shape \(descriptor.shape)"
                )
            }
            // This handler only accepts descriptors whose dimensions are already
            // concrete. CoreAIRuntime traps (rather than throws) when
            // resolvingDynamicDimensions is called for a static descriptor, so
            // use the descriptor directly for allocation and binding metadata.
            let byteCount = descriptor.minimumByteCount
            guard let buffer = device.makeBuffer(
                length: max(byteCount, 64),
                options: .storageModeShared
            ) else {
                throw InferenceRuntimeError.bufferAllocationFailed("\(name) (\(byteCount) bytes)")
            }
            memset(buffer.contents(), 0, buffer.length)
            bindings.append((
                name,
                buffer,
                descriptor.scalarType,
                descriptor.shape,
                descriptor.preferredStrides
            ))
        }
        self.bindings = bindings
        self.stateNames = states.map(\.name)
    }

    @_lifetime(views: borrow self)
    public func bind(into views: inout InferenceFunction.AsyncMutableViews) {
        for binding in bindings {
            var value = unsafe InferenceFunction.AsyncMutableValue(
                unsafeBuffer: binding.buffer,
                byteOffset: 0,
                scalarType: binding.scalarType,
                shape: binding.shape,
                strides: binding.strides
            )
            views.insert(&value, for: binding.name)
            views = unsafe _overrideLifetime(consume views, borrowing: self)
        }
    }

    public func reset() {
        for (_, buffer, _, _, _) in bindings {
            memset(buffer.contents(), 0, buffer.length)
        }
    }
}
