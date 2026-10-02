//
//  UnlockDisplayPolicy.swift
//
//  Which display should host the passcode when the lock screen goes up (or when the display
//  that hosted it is unplugged). Pure logic so the rule is unit-tested; the app feeds it the
//  connected displays and what it knows about the pointer, the main display and the camera.
//

import Foundation

public struct UnlockDisplayCandidate<ID: Hashable>: Equatable {
    public let id: ID
    public let name: String
    public let isBuiltIn: Bool

    public init(id: ID, name: String, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

public enum UnlockDisplayPolicy {
    /// Picks a display, in this order:
    /// 1. the display the user chose by name in Settings, if it is connected;
    /// 2. the built-in display, when face unlock will look through the built-in camera (so the
    ///    self-view sits where the camera looks from);
    /// 3. the display under the pointer (where the user was working);
    /// 4. the main display; 5. the first display. `nil` only when there are no displays.
    public static func choose<ID: Hashable>(
        among candidates: [UnlockDisplayCandidate<ID>],
        preferredName: String?,
        faceUnlockUsesBuiltInCamera: Bool,
        pointerDisplay: ID?,
        mainDisplay: ID?
    ) -> ID? {
        guard !candidates.isEmpty else { return nil }
        if let preferredName, let chosen = candidates.first(where: { $0.name == preferredName }) {
            return chosen.id
        }
        if faceUnlockUsesBuiltInCamera, let builtIn = candidates.first(where: \.isBuiltIn) {
            return builtIn.id
        }
        if let pointerDisplay, candidates.contains(where: { $0.id == pointerDisplay }) {
            return pointerDisplay
        }
        if let mainDisplay, candidates.contains(where: { $0.id == mainDisplay }) {
            return mainDisplay
        }
        return candidates.first?.id
    }
}
