import Foundation
import Testing
@testable import AgentUsageCore

struct UsagePresentationTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let english = Locale(identifier: "en_US")

    @Test func remainingPercentageUsesFiniteClampedValues() {
        #expect(UsagePresentation.remainingPercent(for: window(used: 57)) == 43)
        #expect(UsagePresentation.remainingPercent(for: window(used: -5)) == 100)
        #expect(UsagePresentation.remainingPercent(for: window(used: 110)) == 0)
        #expect(UsagePresentation.remainingPercent(for: window(used: .nan)) == nil)
        #expect(UsagePresentation.remainingPercent(for: window(used: .infinity)) == nil)
    }

    @Test func quotaNamesHandleKnownWindowsAndDuplicateNames() {
        let windows = [
            window(used: 0, duration: 300, kind: .primary),
            window(used: 0, duration: 10_080, kind: .secondary),
            window(used: 0, duration: 300, kind: .primary, id: "other")
        ]
        #expect(UsagePresentation.quotaTitles(for: windows) == [
            "codex · 5-hour limit", "Weekly limit", "other · 5-hour limit"
        ])
        #expect(UsagePresentation.planLabel("plus") == "ChatGPT Plus")
        #expect(UsagePresentation.planLabel(nil) == "Codex account")
    }

    @Test func tokenCountsPromoteAtSuffixBoundaries() {
        #expect(UsagePresentation.compactTokens(430_200, locale: english) == "430.2K")
        #expect(UsagePresentation.compactTokens(15_080_000, locale: english) == "15.08M")
        #expect(UsagePresentation.compactTokens(999_999, locale: english) == "1M")
        #expect(UsagePresentation.compactTokens(999, locale: english) == "999")
        #expect(UsagePresentation.fullTokens(15_080_000, locale: english) == "15,080,000")
    }

    @Test func providerCalendarDateDoesNotShiftWithLocalTimeZone() {
        #expect(UsagePresentation.shortDate("2026-10-10", locale: english) == "Oct 10")
        #expect(UsagePresentation.shortDate("2026-02-30", locale: english) == "2026-02-30")
        #expect(UsagePresentation.shortDate("invalid", locale: english) == "invalid")
    }

    @Test func resetAndUpdateBoundaryLabels() {
        #expect(UsagePresentation.resetLabel(now.addingTimeInterval(79 * 60), observedAt: now, now: now)
                == "Resets in 1h 19m")
        #expect(UsagePresentation.resetLabel(now.addingTimeInterval(6 * 86_400 + 20 * 3_600),
                                             observedAt: now, now: now) == "Resets in 6d 20h")
        #expect(UsagePresentation.resetLabel(now, observedAt: now.addingTimeInterval(-60), now: now)
                == "Reset time passed · awaiting refresh")
        #expect(UsagePresentation.resetLabel(now, observedAt: now, now: now)
                == "Reset time passed · latest quota checked after reset")
        #expect(UsagePresentation.updatedLabel(now, now: now.addingTimeInterval(5 * 60)) == "Updated 5 min ago")
    }

    private func window(used: Double, duration: Int? = nil, kind: QuotaWindow.Kind = .primary,
                        id: String = "codex") -> QuotaWindow {
        QuotaWindow(limitID: id, kind: kind, usedPercent: used, durationMinutes: duration, resetsAt: nil)
    }
}
