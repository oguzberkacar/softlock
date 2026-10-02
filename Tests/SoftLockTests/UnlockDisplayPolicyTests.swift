import Testing
@testable import SoftLockCore

struct UnlockDisplayPolicyTests {
    private let builtIn = UnlockDisplayCandidate(id: 1, name: "Built-in Retina Display", isBuiltIn: true)
    private let studio = UnlockDisplayCandidate(id: 2, name: "Studio Display", isBuiltIn: false)
    private let dell = UnlockDisplayCandidate(id: 3, name: "DELL U2723QE", isBuiltIn: false)

    @Test func noDisplaysMeansNoChoice() {
        let chosen = UnlockDisplayPolicy.choose(
            among: [UnlockDisplayCandidate<Int>](),
            preferredName: "Studio Display",
            faceUnlockUsesBuiltInCamera: true,
            pointerDisplay: 2,
            mainDisplay: 2
        )
        #expect(chosen == nil)
    }

    @Test func chosenDisplayWinsOverEverything() {
        let chosen = UnlockDisplayPolicy.choose(
            among: [builtIn, studio, dell],
            preferredName: "DELL U2723QE",
            faceUnlockUsesBuiltInCamera: true,
            pointerDisplay: 2,
            mainDisplay: 1
        )
        #expect(chosen == 3)
    }

    @Test func disconnectedChoiceFallsThrough() {
        let chosen = UnlockDisplayPolicy.choose(
            among: [builtIn, studio],
            preferredName: "DELL U2723QE",
            faceUnlockUsesBuiltInCamera: false,
            pointerDisplay: 2,
            mainDisplay: 1
        )
        #expect(chosen == 2)
    }

    @Test func builtInCameraPutsFaceUnlockOnTheBuiltInDisplay() {
        let chosen = UnlockDisplayPolicy.choose(
            among: [studio, builtIn],
            preferredName: nil,
            faceUnlockUsesBuiltInCamera: true,
            pointerDisplay: 2,
            mainDisplay: 2
        )
        #expect(chosen == 1)
    }

    @Test func clamshellHasNoBuiltInDisplayToPrefer() {
        let chosen = UnlockDisplayPolicy.choose(
            among: [studio, dell],
            preferredName: nil,
            faceUnlockUsesBuiltInCamera: true,
            pointerDisplay: 3,
            mainDisplay: 2
        )
        #expect(chosen == 3)
    }

    @Test func externalCameraDoesNotPullTheInputToTheLaptop() {
        let chosen = UnlockDisplayPolicy.choose(
            among: [builtIn, studio],
            preferredName: nil,
            faceUnlockUsesBuiltInCamera: false,
            pointerDisplay: 2,
            mainDisplay: 1
        )
        #expect(chosen == 2)
    }

    @Test func pointerDisplayBeatsMainDisplay() {
        let chosen = UnlockDisplayPolicy.choose(
            among: [builtIn, studio],
            preferredName: nil,
            faceUnlockUsesBuiltInCamera: false,
            pointerDisplay: 2,
            mainDisplay: 1
        )
        #expect(chosen == 2)
    }

    @Test func staleOrMissingPointerFallsBackToMainThenFirst() {
        let main = UnlockDisplayPolicy.choose(
            among: [studio, builtIn],
            preferredName: nil,
            faceUnlockUsesBuiltInCamera: false,
            pointerDisplay: 99,
            mainDisplay: 1
        )
        #expect(main == 1)

        let first = UnlockDisplayPolicy.choose(
            among: [studio, builtIn],
            preferredName: nil,
            faceUnlockUsesBuiltInCamera: false,
            pointerDisplay: nil,
            mainDisplay: nil
        )
        #expect(first == 2)
    }
}
