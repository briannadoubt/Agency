import CoreSpotlight
import Foundation

/// Handles NSUserActivity donation for cards to enable Spotlight indexing and Handoff.
enum CardUserActivity {
    static let activityType = "com.briannadoubt.Agency.viewCard"

    /// Create an NSUserActivity for viewing a card.
    static func activity(for card: Card, phase: Phase) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = "\(card.code) \(card.title ?? card.slug)"
        activity.isEligibleForSearch = true
        activity.isEligibleForHandoff = true

        // Store card info for restoration
        activity.userInfo = [
            "cardPath": card.filePath.path,
            "cardCode": card.code,
            "cardTitle": card.title ?? card.slug,
            "phaseNumber": phase.number,
            "phaseLabel": phase.label
        ]

        // Set keywords for Spotlight search
        var keywords = Set<String>()
        keywords.insert(card.code)
        if let title = card.title {
            keywords.formUnion(title.split(separator: " ").map(String.init))
        }
        keywords.insert(card.slug)
        keywords.insert("Phase \(phase.number)")
        keywords.insert(phase.label)
        activity.keywords = keywords

        // Content attributes for richer Spotlight results
        let attributes = activity.contentAttributeSet ?? CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "\(card.code) \(card.title ?? card.slug)"
        attributes.contentDescription = card.summary ?? "Card in Phase \(phase.number) - \(phase.label)"
        attributes.keywords = Array(keywords)
        activity.contentAttributeSet = attributes

        return activity
    }

    /// Donate an activity when viewing a card.
    @MainActor
    static func donate(for card: Card, phase: Phase) {
        let activity = self.activity(for: card, phase: phase)
        activity.becomeCurrent()
    }

    /// Resign the current activity when leaving card view.
    @MainActor
    static func resignCurrent() {
        // The activity will automatically resign when a new one becomes current
        // or when the app moves to background
    }
}
