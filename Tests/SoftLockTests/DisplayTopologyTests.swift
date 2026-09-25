import Testing
import SoftLockCore

@Test func connectedDisplayIsAdded() {
    let delta = DisplayTopology.delta(existing: [1], current: [1, 2])

    #expect(delta.added == [2])
    #expect(delta.removed.isEmpty)
    #expect(delta.retained == [1])
}

@Test func disconnectedDisplayIsRemoved() {
    let delta = DisplayTopology.delta(existing: [1, 2], current: [2])

    #expect(delta.added.isEmpty)
    #expect(delta.removed == [1])
    #expect(delta.retained == [2])
}

@Test func unchangedTopologyOnlyRetainsDisplays() {
    let delta = DisplayTopology.delta(existing: [1, 2], current: [1, 2])

    #expect(delta.added.isEmpty)
    #expect(delta.removed.isEmpty)
    #expect(delta.retained == [1, 2])
}
