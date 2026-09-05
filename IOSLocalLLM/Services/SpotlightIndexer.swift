import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

// MARK: - SpotlightIndexer
//
// Indexes local conversations into CoreSpotlight so the user can find a past
// chat straight from the iOS home-screen search and tap to deep-link back into
// it. Index lives on-device; nothing is uploaded. Tap handling is wired in
// IOSLocalLLMApp via `onContinueUserActivity(CSSearchableItemActionType)`.

enum SpotlightIndexer {

    static let domain = "com.mesutcydev.ondevicecore.conversation"

    /// Rebuild the whole index from the current conversation list. Cheap —
    /// runs on a background queue inside CoreSpotlight.
    static func reindexAll(_ conversations: [StoredConversation]) {
        let index = CSSearchableIndex.default()
        let items = conversations.map(searchableItem(for:))
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            guard !items.isEmpty else { return }
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// Upsert a single conversation (called after each save).
    static func index(_ conversation: StoredConversation) {
        CSSearchableIndex.default().indexSearchableItems([searchableItem(for: conversation)]) { _ in }
    }

    static func remove(id: UUID) {
        CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: [id.uuidString]) { _ in }
    }

    private static func searchableItem(for c: StoredConversation) -> CSSearchableItem {
        let attr = CSSearchableItemAttributeSet(contentType: .text)
        attr.title = c.title
        let firstUser = c.messages.first(where: { $0.role == "user" })?.content ?? ""
        attr.contentDescription = String(firstUser.prefix(200))
        attr.keywords = ["chat", "OnDevice", "ai", "conversation", "assistant"]
        attr.contentModificationDate = c.updatedAt
        return CSSearchableItem(
            uniqueIdentifier: c.id.uuidString,
            domainIdentifier: domain,
            attributeSet: attr
        )
    }
}
