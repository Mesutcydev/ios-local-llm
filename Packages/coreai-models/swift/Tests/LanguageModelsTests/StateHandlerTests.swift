// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Testing

@testable import CoreAILanguageModels

@Suite("Hybrid model state handling")
struct StateHandlerTests {
    @Test("Static S=1 descriptors use token-at-a-time execution")
    func staticSingleTokenShapePolicy() {
        #expect(fixedSequenceLength(in: [1, 1]) == 1)
        #expect(fixedSequenceLength(in: [1, 1, 128_000]) == 1)
        #expect(requiresSingleTokenSteps(inputShape: [1, 1]))

        #expect(fixedSequenceLength(in: [1, -1]) == nil)
        #expect(!requiresSingleTokenSteps(inputShape: [1, -1]))
    }

    @Test("Persistent state kinds decode from metadata")
    func stateKindsDecode() throws {
        let data = Data(#"{"key":"kv_cache","window":"sliding_cache","conv":"fixed"}"#.utf8)
        struct Wrapper: Decodable {
            let key: StateKind
            let window: StateKind
            let conv: StateKind
        }
        let decoded = try JSONDecoder().decode(Wrapper.self, from: data)
        #expect(decoded.key == .kvCache)
        #expect(decoded.window == .slidingCache)
        #expect(decoded.conv == .fixed)
    }
}
