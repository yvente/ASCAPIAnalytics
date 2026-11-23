import Foundation

/// A calendar date without time-of-day or time-zone information.
///
/// Apple's reports identify days by calendar date: the Analytics Reports API
/// uses ISO `YYYY-MM-DD` values (event dates, processing dates), while the
/// Sales and Trends Summary Sales report uses `MM/DD/YYYY` for its Begin
/// Date and End Date. This type models those days exactly as reported —
/// deliberately time-zone-free — because a report day is *not* the same as a
/// UTC interval, and conflating the two silently shifts data across day
/// boundaries.
public struct ASCCalendarDate:
    Comparable,
    Hashable,
    Codable,
    Sendable,
    CustomStringConvertible
{
    /// Gregorian year, for example `2024`.
    public let year: Int
    /// Month in `1...12`.
    public let month: Int
    /// Day in `1...31` (validated against the actual month length).
    public let day: Int

    /// Creates a validated calendar date.
    /// - Returns `nil` when the combination does not form a real
    ///   Gregorian calendar date.
    public init?(year: Int, month: Int, day: Int) {
        guard month >= 1, month <= 12, day >= 1 else { return nil }
        guard let lastDay = ASCCalendarDate.daysInMonth(year: year, month: month),
              day <= lastDay
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses an ISO `YYYY-MM-DD` date, the format used by the Analytics
    /// Reports API for event dates and processing dates.
    public init?(iso8601Day: String) {
        let parts = iso8601Day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), parts[0].count == 4,
              let month = Int(parts[1]), parts[1].count == 2,
              let day = Int(parts[2]), parts[2].count == 2,
              let date = ASCCalendarDate(year: year, month: month, day: day)
        else { return nil }
        self = date
    }

    /// Parses an Apple Sales and Trends `MM/DD/YYYY` date.
    ///
    /// Apple documents the Summary Sales report Begin Date and End Date as
    /// "Date in MM/DD/YYYY"; leading zeros are optional for month and day.
    public init?(salesReportDate: String) {
        let parts = salesReportDate.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let month = Int(parts[0]), parts[0].count <= 2,
              let day = Int(parts[1]), parts[1].count <= 2,
              let year = Int(parts[2]), parts[2].count == 4,
              let date = ASCCalendarDate(year: year, month: month, day: day)
        else { return nil }
        self = date
    }

    /// ISO `YYYY-MM-DD` representation, the canonical stored form.
    public var iso8601Day: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { iso8601Day }

    /// The Monday-based week start (Apple's weekly report instances cover
    /// Monday through Sunday and use the Monday as their Date column value).
    public var startOfWeek: ASCCalendarDate {
        let weekday = gregorianWeekday // 1 = Sunday ... 7 = Saturday
        let backDays = (weekday + 5) % 7 // Monday offset: Sunday(1)->6 ... Monday(2)->0
        return adding(days: -backDays)
    }

    /// The first day of this date's month (Apple's monthly report instances
    /// use the first day of the month as their Date column value).
    public var startOfMonth: ASCCalendarDate {
        ASCCalendarDate(year: year, month: month, day: 1)!
    }

    /// Returns the date shifted by the given number of days.
    public func adding(days: Int) -> ASCCalendarDate {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day + days
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        var resolved = calendar.dateComponents(
            [.year, .month, .day], from: date
        )
        // Guard against clock arithmetic quirks by re-normalizing at noon.
        if resolved.day != nil,
           let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) {
            resolved = calendar.dateComponents([.year, .month, .day], from: noon)
        }
        return ASCCalendarDate(
            year: resolved.year ?? year,
            month: resolved.month ?? month,
            day: resolved.day ?? day
        ) ?? self
    }

    /// Gregorian weekday, `1` = Sunday … `7` = Saturday.
    private var gregorianWeekday: Int {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return 1 }
        let weekdayIndex = calendar.component(.weekday, from: date)
        return weekdayIndex
    }

    private static func daysInMonth(year: Int, month: Int) -> Int? {
        guard year > 0 else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        let calendar = Calendar(identifier: .gregorian)
        guard let interval = calendar.range(
            of: .day, in: .month, for: calendar.date(from: components) ?? Date()
        ) else { return nil }
        return interval.count
    }

    public static func < (lhs: ASCCalendarDate, rhs: ASCCalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// An inclusive range of calendar days.
public struct ASCDateRange:
    Hashable,
    Codable,
    Sendable,
    CustomStringConvertible
{
    /// First day of the range (inclusive).
    public let start: ASCCalendarDate
    /// Last day of the range (inclusive).
    public let end: ASCCalendarDate

    /// Creates a range; returns `nil` when `start` is after `end`.
    public init?(start: ASCCalendarDate, end: ASCCalendarDate) {
        guard start <= end else { return nil }
        self.start = start
        self.end = end
    }

    /// A single-day range.
    public static func singleDay(_ date: ASCCalendarDate) -> ASCDateRange {
        ASCDateRange(start: date, end: date)!
    }

    /// Number of days covered, inclusive of both ends.
    public var dayCount: Int {
        var current = start
        var count = 1
        while current < end {
            current = current.adding(days: 1)
            count += 1
        }
        return count
    }

    /// Whether `date` falls inside the range.
    public func contains(_ date: ASCCalendarDate) -> Bool {
        date >= start && date <= end
    }

    /// Whether the range shares at least one day with `other`.
    public func overlaps(_ other: ASCDateRange) -> Bool {
        start <= other.end && other.start <= end
    }

    /// All days in the range. Ranges longer than 10,000 days are rejected by
    /// the initializer of consumers; iterating very long ranges is possible
    /// but unusual, so this returns an array without a synthetic cap beyond
    /// what the range itself declares.
    public var days: [ASCCalendarDate] {
        var result: [ASCCalendarDate] = []
        var current = start
        while current <= end {
            result.append(current)
            guard current < end else { break }
            current = current.adding(days: 1)
        }
        return result
    }

    public var description: String { "\(start.iso8601Day)..\(end.iso8601Day)" }
}

/// Report granularity as used by the Analytics Reports API: daily, weekly,
/// or monthly instances. Weekly instances cover Monday through Sunday;
/// monthly instances cover a calendar month; in both cases the Date column
/// carries the first day of that period.
public enum ASCReportGranularity: String, CaseIterable, Codable, Hashable, Sendable {
    case daily = "DAILY"
    case weekly = "WEEKLY"
    case monthly = "MONTHLY"

    /// The anchor day that identifies a period of this granularity for a
    /// given event date: the day itself for daily reports, the Monday for
    /// weekly reports, and the first of the month for monthly reports.
    public func anchorDate(for date: ASCCalendarDate) -> ASCCalendarDate {
        switch self {
        case .daily: return date
        case .weekly: return date.startOfWeek
        case .monthly: return date.startOfMonth
        }
    }
}

/// Records that carry the event date their metrics belong to: the Sales
/// and Trends `Begin Date` for sales records, or the Analytics `Date`
/// column for Analytics records.
///
/// The two report families use different date bases — Sales records carry
/// Apple's transaction window (`MM/DD/YYYY`), Analytics records carry
/// Apple's UTC-based event day (`YYYY-MM-DD`) — so values from the two
/// families must never be combined without an explicit decision.
public protocol ASCEventDated {
    /// The event date the record contributes to.
    var eventDate: ASCCalendarDate { get }
}

/// Analytics report records that also carry the app they describe.
/// `ASCInstanceSelection` needs the app identifier so that one app's
/// correction can never overwrite another app's data.
public protocol ASCAnalyticsEventRecord: ASCEventDated {
    /// The `App Apple Identifier` of the record.
    var appAppleIdentifier: String { get }
}

/// A parsed record together with the provenance of the report file it came
/// from. Storage persists these; aggregation reads them.
public struct ASCProvenancedRecord<Record>:
    Hashable,
    Codable,
    Sendable
where Record: Hashable & Codable & Sendable {
    /// The parsed record.
    public let record: Record
    /// Provenance of the source file (report identity, instance and
    /// segment, processing date, schema fingerprint, content checksum).
    public let provenance: ASCReportProvenance

    public init(record: Record, provenance: ASCReportProvenance) {
        self.record = record
        self.provenance = provenance
    }
}
