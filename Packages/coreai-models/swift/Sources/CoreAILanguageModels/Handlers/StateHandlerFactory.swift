// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreAI
import CoreAIShared

public enum StateKind: String, Codable, Sendable {
    case kvCache = "kv_cache"
    case slidingCache = "sliding_cache"
    case fixed
}

struct SyncStateHandlerSet {
    var kvCache: any SyncStateHandler
    var additionalStates: FixedNDArrayState?
    var hasNonTruncatableStates: Bool
}

enum StateHandlerFactory {
    static func classifyStates(
        descriptor: InferenceFunctionDescriptor,
        stateKinds: [String: StateKind]? = nil,
        verbose: Bool = false
    ) -> [(name: String, kind: StateKind)] {
        let names = descriptor.stateNames
        if let stateKinds {
            return names.map { name in
                (name, stateKinds[name] ?? inferKind(name: name, descriptor: descriptor))
            }
        }

        if names.count == 2 {
            return names.map { ($0, .kvCache) }
        }

        let classified = names.map { name in
            (name, inferKind(name: name, descriptor: descriptor))
        }
        if verbose {
            CLILogger.log("State classification (heuristic):", component: "StateHandlerFactory")
            for (name, kind) in classified {
                guard case .ndArray(let stateDescriptor) = descriptor.stateDescriptor(of: name) else {
                    continue
                }
                let shape = stateDescriptor.shape
                    .map { $0 < 0 ? "?" : "\($0)" }
                    .joined(separator: "×")
                CLILogger.log(
                    "  \(name): \(kind.rawValue) (\(shape))",
                    component: "StateHandlerFactory"
                )
            }
        } else if names.count > 2 {
            CLILogger.log(
                "StateHandlerFactory: \(names.count) states classified by heuristic.",
                component: "StateHandlerFactory"
            )
        }
        return classified
    }

    private static func inferKind(
        name: String,
        descriptor: InferenceFunctionDescriptor
    ) -> StateKind {
        guard case .ndArray(let stateDescriptor) = descriptor.stateDescriptor(of: name) else {
            return .fixed
        }
        if stateDescriptor.shape.contains(where: { $0 < 0 }) {
            return .kvCache
        }
        let normalizedName = name.lowercased()
        if normalizedName.contains("cache") || normalizedName.contains("kv") {
            return .slidingCache
        }
        return .fixed
    }

    static func createSyncHandlers(
        descriptor: InferenceFunctionDescriptor,
        maxContextLength: Int,
        stateKinds: [String: StateKind]? = nil,
        options: EngineOptions = EngineOptions(),
        verbose: Bool = false
    ) throws -> SyncStateHandlerSet {
        guard !descriptor.stateNames.isEmpty else {
            throw InferenceRuntimeError.invalidOutputType("Expected states but found none")
        }

        let classified = classifyStates(
            descriptor: descriptor,
            stateKinds: stateKinds,
            verbose: verbose
        )
        var growingStates: [(name: String, descriptor: NDArrayDescriptor)] = []
        var fixedStates: [(name: String, descriptor: NDArrayDescriptor)] = []
        var hasNonTruncatableStates = false

        for (name, kind) in classified {
            guard case .ndArray(let stateDescriptor) = descriptor.stateDescriptor(of: name) else {
                throw InferenceRuntimeError.invalidOutputType(
                    "Cannot get state descriptor for '\(name)'"
                )
            }
            switch kind {
            case .kvCache:
                growingStates.append((name, stateDescriptor))
            case .slidingCache:
                fixedStates.append((name, stateDescriptor))
            case .fixed:
                fixedStates.append((name, stateDescriptor))
                hasNonTruncatableStates = true
            }
        }

        let kvCache: any SyncStateHandler
        if !growingStates.isEmpty {
            if options.kvCacheStrategy == .fixedSize {
                let resolved = growingStates.map { name, descriptor in
                    let resolvedDescriptor = descriptor.resolvingDynamicDimensions(
                        descriptor.shape.map { $0 < 0 ? maxContextLength : $0 })
                    return (name, resolvedDescriptor)
                }
                kvCache = FixedNDArrayState(states: resolved)
            } else {
                kvCache = GrowingNDArrayState(
                    states: growingStates,
                    initialCapacity: min(256, maxContextLength),
                    maxCapacity: maxContextLength
                )
            }
        } else {
            kvCache = FixedNDArrayState(states: fixedStates)
            fixedStates = []
        }

        let additionalStates = fixedStates.isEmpty
            ? nil
            : FixedNDArrayState(states: fixedStates)
        return SyncStateHandlerSet(
            kvCache: kvCache,
            additionalStates: additionalStates,
            hasNonTruncatableStates: hasNonTruncatableStates
        )
    }
}
