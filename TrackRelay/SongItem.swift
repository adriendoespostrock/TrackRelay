import Foundation

struct SongSection: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var startTime: TimeInterval

    var id: String { "\(startTime)-\(name)" }
}

struct SongItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var path: String
    var duration: TimeInterval?
    var sections: [SongSection]
    var isIncluded: Bool

    init(
        id: UUID = UUID(),
        title: String,
        path: String,
        duration: TimeInterval? = nil,
        sections: [SongSection] = [],
        isIncluded: Bool = true
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.duration = duration
        self.sections = sections
        self.isIncluded = isIncluded
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, path, duration, sections, isIncluded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        path = try container.decode(String.self, forKey: .path)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        sections = try container.decodeIfPresent([SongSection].self, forKey: .sections) ?? []
        isIncluded = try container.decodeIfPresent(Bool.self, forKey: .isIncluded) ?? true
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var durationText: String {
        guard let duration else { return "—" }
        return DurationText.format(duration)
    }

    func playbackDuration(automaticEndMarkerEnabled _: Bool) -> TimeInterval? {
        return duration
    }

    func formattedDuration(automaticEndMarkerEnabled: Bool) -> String {
        guard let value = playbackDuration(automaticEndMarkerEnabled: automaticEndMarkerEnabled) else {
            return "—"
        }
        return DurationText.format(value)
    }
}

enum DurationText {
    static func format(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
