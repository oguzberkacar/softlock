public struct DisplayTopologyDelta: Equatable, Sendable {
    public let added: Set<UInt32>
    public let removed: Set<UInt32>
    public let retained: Set<UInt32>

    public init(added: Set<UInt32>, removed: Set<UInt32>, retained: Set<UInt32>) {
        self.added = added
        self.removed = removed
        self.retained = retained
    }
}

public enum DisplayTopology {
    public static func delta(existing: Set<UInt32>, current: Set<UInt32>) -> DisplayTopologyDelta {
        DisplayTopologyDelta(
            added: current.subtracting(existing),
            removed: existing.subtracting(current),
            retained: existing.intersection(current)
        )
    }
}
