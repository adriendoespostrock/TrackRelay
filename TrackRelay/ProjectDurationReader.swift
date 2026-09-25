import AVFoundation
import AudioToolbox
import Foundation

struct ProjectMetadata: Sendable {
    let duration: TimeInterval?
    let sections: [SongSection]
}

enum SongEndMarker {
    private static let names: Set<String> = [
        "end", "fin", "song end", "songend", "end of song", "end of project",
        "fin du morceau", "fin de chanson", "fin du projet"
    ]

    static func matches(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return names.contains(normalized)
    }
}

enum ProjectDurationReader {
    private static let supportedExtensions: Set<String> = [
        "aif", "aiff", "caf", "flac", "m4a", "mp3", "wav"
    ]

    /// Retourne la durée du fichier audio le plus long du dossier Audio Files
    /// du projet. Les ressources internes de Logic, comme le clic du métronome,
    /// ne font pas partie des fichiers audio de la chanson.
    static func duration(of projectURL: URL) async -> TimeInterval? {
        await metadata(of: projectURL).duration
    }

    /// Lit la durée et les marqueurs des fichiers audio du projet.
    /// Logic peut inscrire sa liste de marqueurs dans ce fichier audio via
    /// Navigation > Autre > Exporter les marqueurs vers le fichier audio.
    static func metadata(of projectURL: URL) async -> ProjectMetadata {
        let audioFilesDirectory = projectURL
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent("Audio Files", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: audioFilesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ProjectMetadata(duration: nil, sections: [])
        }

        let audioFiles = enumerator.compactMap { $0 as? URL }
            .filter { url in
                guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                    return false
                }
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }

        var longestDuration: TimeInterval?
        var allSections: [SongSection] = []

        for audioURL in audioFiles {
            let audioMarkers = AudioMarkerReader.sections(
                in: audioURL,
                maximumDuration: nil
            )
            allSections.append(contentsOf: audioMarkers.filter { !SongEndMarker.matches($0.name) })

            let asset = AVURLAsset(url: audioURL)
            guard let time = try? await asset.load(.duration) else { continue }
            let seconds = CMTimeGetSeconds(time)

            guard seconds.isFinite, seconds > 0 else { continue }
            if seconds > (longestDuration ?? 0) {
                longestDuration = seconds
            }

        }

        let sections = allSections
            .filter { section in
                guard let longestDuration else { return true }
                return section.startTime <= longestDuration
            }
            .sorted { $0.startTime < $1.startTime }
            .reduce(into: [SongSection]()) { result, section in
                guard !result.contains(where: {
                    abs($0.startTime - section.startTime) < 0.01 && $0.name == section.name
                }) else { return }
                result.append(section)
            }
        return ProjectMetadata(
            duration: longestDuration,
            sections: sections
        )
    }
}

private enum AudioMarkerReader {
    static func sections(in audioURL: URL, maximumDuration: TimeInterval?) -> [SongSection] {
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(audioURL as CFURL, .readPermission, 0, &audioFile) == noErr,
              let audioFile else {
            return []
        }
        defer { AudioFileClose(audioFile) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyDataFormat,
            &formatSize,
            &format
        ) == noErr, format.mSampleRate > 0 else {
            return []
        }

        var markerListSize: UInt32 = 0
        guard AudioFileGetPropertyInfo(
            audioFile,
            kAudioFilePropertyMarkerList,
            &markerListSize,
            nil
        ) == noErr, markerListSize > 0 else {
            return []
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(markerListSize),
            alignment: MemoryLayout<AudioFileMarkerList>.alignment
        )
        defer { rawBuffer.deallocate() }

        guard AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyMarkerList,
            &markerListSize,
            rawBuffer
        ) == noErr else {
            return []
        }

        let markerList = rawBuffer.assumingMemoryBound(to: AudioFileMarkerList.self)
        let markerCount = Int(markerList.pointee.mNumberMarkers)
        var sections: [SongSection] = []

        withUnsafePointer(to: &markerList.pointee.mMarkers) { firstMarker in
            let markers = UnsafeRawPointer(firstMarker).assumingMemoryBound(to: AudioFileMarker.self)
            for index in 0..<markerCount {
                let marker = markers[index]
                let time = marker.mFramePosition / format.mSampleRate
                let rawName = marker.mName?.takeRetainedValue() as String?
                let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "Section \(index + 1)"

                guard time.isFinite, time >= 0 else { continue }
                guard !isTechnicalMarkerType(marker.mType) else { continue }
                guard !isTechnicalMarker(
                    name,
                    at: time,
                    in: audioURL
                ) else { continue }
                if let maximumDuration, time > maximumDuration { continue }
                sections.append(SongSection(name: name, startTime: time))
            }
        }

        return sections
            .sorted { $0.startTime < $1.startTime }
            .reduce(into: [SongSection]()) { result, section in
                guard !result.contains(where: {
                    abs($0.startTime - section.startTime) < 0.01 && $0.name == section.name
                }) else { return }
                result.append(section)
            }
    }

    private static func isTechnicalMarker(
        _ name: String,
        at time: TimeInterval,
        in audioURL: URL
    ) -> Bool {
        let normalizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        let normalizedFileName = audioURL
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        guard !normalizedName.isEmpty else { return true }

        // Logic exporte aussi des métadonnées techniques dans certains formats
        // audio. Le nom de la région source peut notamment être ajouté à 0:00
        // avec le même texte que le nom du fichier audio.
        return normalizedName == "region"
            || normalizedName.hasPrefix("timestamp:")
            || normalizedName.hasPrefix("tempo")
            || (time <= 0.01 && normalizedName == normalizedFileName)
    }

    private static func isTechnicalMarkerType(_ type: UInt32) -> Bool {
        // Les débuts/fins de région ou de piste décrivent la structure du
        // fichier audio, pas les sections musicales exportées depuis Logic.
        switch type {
        case kCAFMarkerType_RegionStart,
             kCAFMarkerType_RegionEnd,
             kCAFMarkerType_RegionSyncPoint,
             kCAFMarkerType_TrackStart,
             kCAFMarkerType_TrackEnd:
            return true
        default:
            return false
        }
    }
}
