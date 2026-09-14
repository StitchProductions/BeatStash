import Foundation
import Testing
@testable import BeatStash

/// Dotted release versions: stable `2026.08.19`, nightly `2026.08.30.232658`.
/// Longer-is-newer on an equal prefix so nightlies sort after their day.
struct VersionCompareTests {
    @Test func stableOrdering() {
        #expect(BinaryManager.compareVersions("2026.07.04", "2026.08.19") == .orderedAscending)
        #expect(BinaryManager.compareVersions("2026.08.19", "2026.07.04") == .orderedDescending)
        #expect(BinaryManager.compareVersions("2026.08.19", "2026.08.19") == .orderedSame)
    }

    @Test func nightlySortsAfterItsDay() {
        #expect(BinaryManager.compareVersions("2026.08.19", "2026.08.30.232658") == .orderedAscending)
        #expect(BinaryManager.compareVersions("2026.08.30.232657", "2026.08.30.232658") == .orderedAscending)
        #expect(BinaryManager.compareVersions("2026.08.30.232658", "2026.08.30.232658") == .orderedSame)
    }

    @Test func tolerantInput() {
        #expect(BinaryManager.compareVersions("v2026.08.19", "2026.08.19") == .orderedSame)
        #expect(BinaryManager.compareVersions(" 2026.08.19\n", "2026.08.19") == .orderedSame)
    }
}
