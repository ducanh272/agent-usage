import Foundation

/// Display values shared by the usage panel and menu bar.
public enum UsagePresentation {
    public static func remainingPercent(for window: QuotaWindow) -> Double? {
        guard window.usedPercent.isFinite else { return nil }
        return max(0, min(100, 100 - window.usedPercent))
    }

    public static func quotaTitles(for windows: [QuotaWindow]) -> [String] {
        let names = windows.map(baseQuotaTitle)
        let counts = names.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return zip(windows, names).map { window, name in
            counts[name, default: 0] > 1 ? "\(window.limitID) · \(name)" : name
        }
    }

    public static func planLabel(_ plan: String?) -> String {
        guard let plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Codex account"
        }
        let words = plan.split { $0 == "_" || $0 == "-" || $0 == " " }.map { $0.capitalized }
        return "ChatGPT \(words.joined(separator: " "))"
    }

    public static func compactTokens(_ value: Int64, locale: Locale = .current) -> String {
        let magnitude = Double(value.magnitude)
        let scales: [(Double, String)] = [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        var scaleIndex = scales.firstIndex { magnitude >= $0.0 }
        if let index = scaleIndex {
            let rounded = (magnitude / scales[index].0 * 100).rounded() / 100
            if rounded >= 1_000, index > 0 { scaleIndex = index - 1 }
        }
        guard let index = scaleIndex else { return fullTokens(value, locale: locale) }
        let number = NumberFormatter()
        number.locale = locale
        number.numberStyle = .decimal
        number.minimumFractionDigits = 0
        number.maximumFractionDigits = 2
        let scaled = Double(value) / scales[index].0
        return (number.string(from: NSNumber(value: scaled)) ?? "\(scaled)") + scales[index].1
    }

    public static func fullTokens(_ value: Int64, locale: Locale = .current) -> String {
        let number = NumberFormatter()
        number.locale = locale
        number.numberStyle = .decimal
        number.maximumFractionDigits = 0
        return number.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func shortDate(_ raw: String, locale: Locale = .current) -> String {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard raw.count == 10, parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return raw
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components) else { return raw }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            return raw
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    public static func resetLabel(_ reset: Date, observedAt: Date, now: Date) -> String {
        if observedAt >= reset { return "Reset time passed · latest quota checked after reset" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset time passed · awaiting refresh" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "Resets in \(minutes)m" }
        if minutes < 1_440 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        let hours = Int(ceil(Double(minutes) / 60))
        return "Resets in \(hours / 24)d \(hours % 24)h"
    }

    public static func updatedLabel(_ updated: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(updated))
        if seconds < 60 { return "Updated just now" }
        if seconds < 3_600 { return "Updated \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "Updated \(Int(seconds / 3_600))h ago" }
        return "Updated \(Int(seconds / 86_400))d ago"
    }

    private static func baseQuotaTitle(_ window: QuotaWindow) -> String {
        if window.kind == .primary, window.durationMinutes == 300 { return "5-hour limit" }
        if window.kind == .secondary, window.durationMinutes == 10_080 { return "Weekly limit" }
        let kind = window.kind == .primary ? "Primary" : "Secondary"
        guard let minutes = window.durationMinutes, minutes > 0 else { return "\(kind) limit" }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080)-week \(kind.lowercased()) limit" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day \(kind.lowercased()) limit" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour \(kind.lowercased()) limit" }
        return "\(minutes)-minute \(kind.lowercased()) limit"
    }
}
