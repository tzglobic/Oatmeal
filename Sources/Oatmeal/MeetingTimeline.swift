import Foundation

enum MeetingTimeline {
    static func groups<Element>(_ meetings: [Element], date: KeyPath<Element, Date>, searching: Bool = false,
                       now: Date = Date(), calendar: Calendar = .current)
        -> [(title: String, meetings: [Element])] {
        if searching { return [("Search results", meetings)] }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let buckets = Dictionary(grouping: meetings) { meeting -> Int in
            if calendar.isDate(meeting[keyPath: date], inSameDayAs: now) { return 0 }
            if let week, week.contains(meeting[keyPath: date]) { return 1 }
            return 2
        }
        return ["Today", "This week", "Earlier"].enumerated().compactMap { index, title in
            guard let items = buckets[index], !items.isEmpty else { return nil }
            return (title, items.sorted { $0[keyPath: date] > $1[keyPath: date] })
        }
    }
}
