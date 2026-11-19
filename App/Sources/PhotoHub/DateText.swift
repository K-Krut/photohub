import Foundation

enum DateText {
    static let locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let region = Locale.current.region?.identifier else { return Locale(identifier: language) }
        return Locale(identifier: language + "_" + region)
    }()

    private static let utc = TimeZone(identifier: "UTC")!

    private static let parser: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = utc
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    private static func formatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = utc
        formatter.dateFormat = format
        return formatter
    }

    private static let monthYear = formatter(format: "LLLL y")
    private static let shortMonthYear = formatter(format: "LLL y")

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = utc
        formatter.setLocalizedDateFormatFromTemplate("d MMM y")
        return formatter
    }()

    private static let interval: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = utc
        formatter.dateTemplate = "d MMM y"
        return formatter
    }()

    static let shortMonths: [String] = {
        let formatter = DateFormatter()
        formatter.locale = locale
        return (formatter.shortStandaloneMonthSymbols ?? []).map(capitalized)
    }()

    static func date(_ text: String) -> Date? { parser.date(from: String(text.prefix(10))) }

    static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }

    static func month(_ month: String, short: Bool) -> String? {
        guard month.count == 7, let date = parser.date(from: month + "-01") else { return nil }
        return capitalized((short ? shortMonthYear : monthYear).string(from: date))
    }

    static func days(_ from: String, _ to: String) -> String? {
        guard let a = date(from), let b = date(to) else { return nil }
        return a == b ? day.string(from: a) : interval.string(from: a, to: b)
    }
}
