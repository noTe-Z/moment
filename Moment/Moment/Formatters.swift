import Foundation

enum TimeFormatter {
    private static let componentFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    static func display(for interval: TimeInterval) -> String {
        componentFormatter.string(from: interval) ?? "--:--"
    }
}

enum TimestampFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 a h:mm"
        return formatter
    }()

    static func display(for date: Date) -> String {
        formatter.string(from: date)
    }
}

enum WeekSectionFormatter {
    static func title(for date: Date, today: Date = Date(), calendar: Calendar = .current) -> String {
        guard
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start,
            let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start
        else {
            return TimestampFormatter.display(for: date)
        }

        let difference = calendar.dateComponents([.weekOfYear], from: weekStart, to: currentWeekStart).weekOfYear ?? 0

        switch difference {
        case 0:
            return "本周"
        case 1:
            return "上周"
        default:
            let month = calendar.component(.month, from: weekStart)
            let weekOfMonth = calendar.component(.weekOfMonth, from: weekStart)
            let year = calendar.component(.year, from: weekStart)
            let currentYear = calendar.component(.year, from: today)
            let yearPrefix = year == currentYear ? "" : "\(year)年"
            return "\(yearPrefix)\(month)月第\(weekOfMonth)周"
        }
    }
}
