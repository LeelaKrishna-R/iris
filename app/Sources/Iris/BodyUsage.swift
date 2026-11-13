import AppKit

// Iris's body — what the person uses (out of Body.swift): the seconds the person spends in each app and window, by day
// and hour, as she records them for Friday (her usage files).
extension Body {
    /// How the person spends their day at the Mac: active seconds per front app (the person typed,
    /// clicked or moved the mouse in the last 2 minutes), saved under her own
    /// folder by day ("use-2026-10-11.json"), never leaving this Mac.
    func countUse(_ now: Date) {
        guard now.timeIntervalSince(useCountedAt) >= 5 else { return }
        let step = min(10, now.timeIntervalSince(useCountedAt))
        useCountedAt = now
        // the system's own idle clock (any key, click, scroll or mouse move): lastInput starts at
        // launch, so the two minutes after every launch were counted as their (00:00 install)
        let idle = world is RealWorld
            ? CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            : now.timeIntervalSince(lastInput)
        guard idle < 120, let app = world.frontApp, !app.isEmpty,
              app != (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Iris") else { return }
        let day = Body.dayKey(now)
        if day != useDay {
            useDay = day
            use = Store.load([String: Double].self, "use-\(day).json") ?? [:]
            work = Store.load([String: [String: Double]].self, "work-\(day).json") ?? [:]
            Body.pruneUse(before: Body.dayKey(now.addingTimeInterval(-60 * 86400)))
        }
        use[app, default: 0] += step
        // what they were on, by the hour: the window's title with its app, so "what was I
        // working on this afternoon" is the file or page, not just "Code"
        let hour = String(format: "%02d", Calendar.current.component(.hour, from: now))
        let title = String((world.frontTitle ?? "").prefix(120))
        var h = work[hour] ?? [:]
        h["\(app)\t\(title)", default: 0] += step
        if h.count > 40, let least = h.min(by: { $0.value < $1.value }) { h[least.key] = nil }
        work[hour] = h
        if now.timeIntervalSince(useSavedAt) >= 60 {
            useSavedAt = now; Store.save(use, "use-\(day).json"); Store.save(work, "work-\(day).json")
        }
    }

    /// The day files older than 60 days go: their windows aren't kept forever.
    static func pruneUse(before cutoff: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Store.dir.path)) ?? []
        for n in names where n.hasPrefix("use-") || n.hasPrefix("work-") {
            let day = n.replacingOccurrences(of: "use-", with: "").replacingOccurrences(of: "work-", with: "")
                .replacingOccurrences(of: ".json", with: "")
            if day.count == 10 && day < cutoff { try? FileManager.default.removeItem(at: Store.url(n)) }
        }
    }

    /// Her day: the calendar date on their clock, turning at midnight, as Core's days of hers do (core/iris_reflex._day_key
    /// says why).
    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: d)
    }

    /// Today's (or a given day's) active seconds per app.
    func usage(day: String? = nil) -> [String: Double] {
        let d = day ?? Body.dayKey(world.now)
        return d == useDay ? use : (Store.load([String: Double].self, "use-\(d).json") ?? [:])
    }

    /// A day's active seconds by hour, then by "app\ttitle".
    func workHours(day: String? = nil) -> [String: [String: Int]] {
        let d = day ?? Body.dayKey(world.now)
        let w = d == useDay ? work : (Store.load([String: [String: Double]].self, "work-\(d).json") ?? [:])
        return w.mapValues { $0.mapValues { Int($0) } }
    }
}
