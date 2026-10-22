import Foundation
import SwiftData

/// Fills in the outside temperature for readings that carry a location but
/// no temperature yet.
///
/// The watch stamps a reading with where, how high and when; it has no
/// network and needs none. The phone, whenever it next runs with a
/// connection, asks **Open-Meteo** for that hour's air temperature at that
/// spot and writes it onto the entry. One lookup per reading, a dozen at a
/// time, no more than every quarter hour unless a new reading has just
/// arrived; the free allowance is ten thousand calls a day.
///
/// Open-Meteo rather than WeatherKit because it takes an **elevation**:
/// WeatherKit returns the temperature at its model's own terrain height for a
/// grid cell a few kilometres across, which on a mountainside can be a
/// thousand metres below the wrist. Open-Meteo downscales to the height it
/// is given — the fix's altitude when the reading has one, and its own
/// 90-metre elevation model at that coordinate when it does not. It also
/// needs no entitlement, no App Service and no signing step.
///
/// The only thing that ever leaves the phone, and the only network the app
/// uses: a coordinate, a height and a time, to Open-Meteo. Weather data by
/// Open-Meteo.com, CC BY 4.0.
@MainActor
enum WeatherBackfill {

    private static var lastRun: Date?
    private static let minimumInterval: TimeInterval = 15 * 60
    private static let batch = 12

    /// The forecast endpoint serves the last 92 days; anything older comes
    /// from the archive, which runs a few days behind the present.
    private static let forecastReach: TimeInterval = 90 * 24 * 3600
    private static let forecastEndpoint = "https://api.open-meteo.com/v1/forecast"
    private static let archiveEndpoint = "https://archive-api.open-meteo.com/v1/archive"

    /// Look up what is missing. `force` skips the interval — for launch, and
    /// for a reading that has just come across from the watch.
    static func run(in context: ModelContext, force: Bool = false) async {
        if !force, let lastRun, Date.now.timeIntervalSince(lastRun) < minimumInterval { return }
        lastRun = .now

        // Fetched whole and narrowed in Swift, as everywhere else: a predicate
        // that failed at runtime would be swallowed and nothing filled in.
        let all = (try? context.fetch(FetchDescriptor<LogEntry>())) ?? []
        let pending = all
            .filter { $0.kind == .glucose && $0.hasLocation && $0.temperature == nil }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(batch)
        guard !pending.isEmpty else { return }

        var filled = false
        for entry in pending {
            guard let latitude = entry.latitude, let longitude = entry.longitude else { continue }
            guard let celsius = await temperature(latitude: latitude,
                                                  longitude: longitude,
                                                  altitude: entry.altitude,
                                                  at: entry.timestamp) else { continue }
            entry.temperature = celsius
            filled = true
        }
        if filled { try? context.save() }
    }

    // MARK: - Open-Meteo

    /// Air temperature two metres above ground at the hour nearest `date`,
    /// in °C. Nil when offline, when the service has nothing for that hour,
    /// or when the answer does not parse.
    private static func temperature(latitude: Double,
                                    longitude: Double,
                                    altitude: Double?,
                                    at date: Date) async -> Double? {
        guard let url = requestURL(latitude: latitude, longitude: longitude, altitude: altitude, at: date),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { return nil }

        // The hour nearest the reading, among those that carry a value.
        var best: (gap: TimeInterval, value: Double)?
        for (time, value) in zip(reply.hourly.time, reply.hourly.temperature_2m) {
            guard let value else { continue }
            let gap = abs(Date(timeIntervalSince1970: time).timeIntervalSince(date))
            if best == nil || gap < best!.gap { best = (gap, value) }
        }
        // More than an hour and a half away is a different hour's weather,
        // not this reading's.
        guard let best, best.gap <= 90 * 60 else { return nil }
        return best.value
    }

    /// The hour before and after the reading, in UTC, so the nearest hour is
    /// in the answer even across midnight. Unix timestamps back, so no time
    /// zone arithmetic is done on either side.
    private static func requestURL(latitude: Double,
                                   longitude: Double,
                                   altitude: Double?,
                                   at date: Date) -> URL? {
        let endpoint = Date.now.timeIntervalSince(date) < forecastReach ? forecastEndpoint : archiveEndpoint
        var components = URLComponents(string: endpoint)
        var items = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m"),
            URLQueryItem(name: "start_date", value: Self.utcDay.string(from: date.addingTimeInterval(-3600))),
            URLQueryItem(name: "end_date", value: Self.utcDay.string(from: date.addingTimeInterval(3600))),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "UTC"),
        ]
        if let altitude {
            items.append(URLQueryItem(name: "elevation", value: String(format: "%.0f", altitude)))
        }
        components?.queryItems = items
        return components?.url
    }

    private struct Reply: Decodable {
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
        }
        let hourly: Hourly
    }

    private static let utcDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
