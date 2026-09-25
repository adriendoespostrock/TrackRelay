import AppKit
import Foundation
import SwiftUI

struct NamedSetlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var songs: [SongItem]
    var selectedSongID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        songs: [SongItem],
        selectedSongID: UUID?
    ) {
        self.id = id
        self.name = name
        self.songs = songs
        self.selectedSongID = selectedSongID
    }
}

@MainActor
final class SetlistViewModel: ObservableObject {
    @Published var songs: [SongItem] = [] {
        didSet { updateActiveSetlistAndSave() }
    }
    @Published var selectedSongID: SongItem.ID? {
        didSet { updateActiveSetlistAndSave() }
    }
    @Published private(set) var namedSetlists: [NamedSetlist] = []
    @Published private(set) var activeSetlistID: UUID?
    @Published private(set) var openedSongID: SongItem.ID?
    @Published private(set) var isOpening = false
    @Published private(set) var isReadingDurations = false
    @Published private(set) var cycleEnabled = false
    @Published var status = "Choisis un dossier contenant tes projets Logic."
    @Published var showingError = false
    @Published var errorMessage = ""

    private let legacyPersistenceKey = "trackrelay.legacy.state.v1"
    private let persistenceKey = "trackrelay.setlists.v2"
    private let logic = LogicController()
    private var isApplyingSetlist = false

    private struct LegacySavedState: Codable {
        var songs: [SongItem]
        var selectedSongID: UUID?
    }

    private struct SavedSetlistLibrary: Codable {
        var setlists: [NamedSetlist]
        var activeSetlistID: UUID?
    }

    init() {
        restore()
        if !songs.isEmpty {
            refreshDurations()
        }
    }

    var selectedSong: SongItem? {
        guard let selectedSongID else { return nil }
        return songs.first(where: { $0.id == selectedSongID })
    }

    var activeSetlistName: String {
        namedSetlists.first(where: { $0.id == activeSetlistID })?.name ?? "Set principal"
    }

    var selectedIndex: Int? {
        guard let selectedSongID else { return nil }
        return songs.firstIndex(where: { $0.id == selectedSongID })
    }

    var openedSong: SongItem? {
        guard let openedSongID else { return nil }
        return songs.first(where: { $0.id == openedSongID })
    }

    var setlistSongs: [SongItem] {
        songs.filter(\.isIncluded)
    }

    var performanceSong: SongItem? {
        if let openedSong, openedSong.isIncluded { return openedSong }
        if let selectedSong, selectedSong.isIncluded { return selectedSong }
        return setlistSongs.first
    }

    private var navigationIndex: Int? {
        if let openedSongID,
           let index = songs.firstIndex(where: { $0.id == openedSongID && $0.isIncluded }) {
            return index
        }
        if let selectedSongID,
           let index = songs.firstIndex(where: { $0.id == selectedSongID && $0.isIncluded }) {
            return index
        }
        guard let firstIncludedID = setlistSongs.first?.id else { return nil }
        return songs.firstIndex(where: { $0.id == firstIncludedID })
    }

    var canOpenPrevious: Bool {
        guard let index = navigationIndex, index > songs.startIndex else { return false }
        return songs[..<index].contains(where: \.isIncluded)
    }

    var canOpenNext: Bool {
        guard let index = navigationIndex, index + 1 < songs.endIndex else { return false }
        return songs[(index + 1)...].contains(where: \.isIncluded)
    }

    var totalDuration: TimeInterval {
        setlistSongs.compactMap(\.duration).reduce(0, +)
    }

    var totalDurationText: String {
        DurationText.format(totalDuration)
    }

    func totalDurationText(automaticEndMarkerEnabled: Bool) -> String {
        let total = setlistSongs.compactMap {
            $0.playbackDuration(automaticEndMarkerEnabled: automaticEndMarkerEnabled)
        }.reduce(0, +)
        return DurationText.format(total)
    }

    var missingDurationCount: Int {
        setlistSongs.filter { $0.duration == nil }.count
    }

    func activateSetlist(_ setlistID: UUID) {
        guard !isOpening,
              !isReadingDurations,
              setlistID != activeSetlistID,
              let setlist = namedSetlists.first(where: { $0.id == setlistID }) else { return }

        apply(setlist)
        saveLibrary()
        status = "Setlist « \(setlist.name) » chargée."
    }

    func createSetlist(named requestedName: String, duplicatingCurrent: Bool) {
        let name = uniqueSetlistName(from: requestedName)
        let sourceName = activeSetlistName
        let newSongs: [SongItem]

        if duplicatingCurrent {
            newSongs = songs
        } else {
            newSongs = songs.map { song in
                var copy = song
                copy.isIncluded = false
                return copy
            }
        }

        let newSetlist = NamedSetlist(
            name: name,
            songs: newSongs,
            selectedSongID: duplicatingCurrent ? selectedSongID : newSongs.first?.id
        )
        namedSetlists.append(newSetlist)
        apply(newSetlist)
        saveLibrary()
        status = duplicatingCurrent
            ? "Setlist « \(name) » créée à partir de \(sourceName)."
            : "Nouvelle setlist « \(name) » créée."
    }

    func renameActiveSetlist(to requestedName: String) {
        guard let activeSetlistID,
              let index = namedSetlists.firstIndex(where: { $0.id == activeSetlistID }) else { return }

        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let name = uniqueSetlistName(from: trimmedName, excluding: activeSetlistID)
        namedSetlists[index].name = name
        saveLibrary()
        status = "Setlist renommée « \(name) »."
    }

    func deleteActiveSetlist() {
        guard namedSetlists.count > 1,
              let activeSetlistID,
              let index = namedSetlists.firstIndex(where: { $0.id == activeSetlistID }) else { return }

        let deletedName = namedSetlists[index].name
        namedSetlists.remove(at: index)
        let replacementIndex = min(index, namedSetlists.count - 1)
        apply(namedSetlists[replacementIndex])
        saveLibrary()
        status = "Setlist « \(deletedName) » supprimée."
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choisir le dossier des chansons"
        panel.prompt = "Créer la setlist"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let folder = panel.url else { return }
        importProjects(from: folder)
    }

    func importProjects(from folder: URL) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            presentError("Impossible de lire ce dossier.")
            return
        }

        let urls = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "logicx" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !urls.isEmpty else {
            presentError("Aucun fichier .logicx trouvé dans ce dossier.")
            return
        }

        songs = urls.map {
            SongItem(
                title: $0.deletingPathExtension().lastPathComponent,
                path: $0.path
            )
        }
        selectedSongID = songs.first?.id
        openedSongID = nil
        status = "\(songs.count) projet\(songs.count > 1 ? "s" : "") chargé\(songs.count > 1 ? "s" : "") dans la setlist."
        refreshDurations()
    }

    func refreshDurations() {
        guard !songs.isEmpty, !isReadingDurations else { return }

        let snapshot = songs
        isReadingDurations = true
        status = "Lecture des durées et des marqueurs des backtracks…"

        Task {
            let metadata = await Task.detached(priority: .utility) {
                var result: [UUID: ProjectMetadata] = [:]
                for song in snapshot {
                    result[song.id] = await ProjectDurationReader.metadata(of: song.url)
                }
                return result
            }.value

            var updatedSongs = songs
            for index in updatedSongs.indices {
                let songMetadata = metadata[updatedSongs[index].id]
                updatedSongs[index].duration = songMetadata?.duration
                updatedSongs[index].sections = songMetadata?.sections ?? []
            }
            songs = updatedSongs
            isReadingDurations = false

            let unknownCount = songs.filter { $0.duration == nil }.count
            let foundCount = songs.count - unknownCount
            let markerCount = songs.reduce(0) { $0 + $1.sections.count }
            if unknownCount == 0 {
                status = "Durées calculées pour les \(foundCount) chansons · \(markerCount) marqueur\(markerCount > 1 ? "s" : "") trouvé\(markerCount > 1 ? "s" : "")."
            } else {
                status = "\(foundCount) durée\(foundCount > 1 ? "s" : "") trouvée\(foundCount > 1 ? "s" : ""), \(unknownCount) inconnue\(unknownCount > 1 ? "s" : "")."
            }
        }
    }

    func openSelected() {
        guard let song = selectedSong else { return }
        isOpening = true
        cycleEnabled = false
        status = "Ouverture de \(song.title)…"

        Task {
            defer { isOpening = false }
            do {
                let playheadWasReset = try await logic.openProject(song)
                openedSongID = song.id
                if playheadWasReset {
                    status = "\(song.title) est prêt au début du projet."
                } else {
                    status = "\(song.title) est ouvert, mais le retour au début n’a pas pu être confirmé."
                }
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    func previousAndOpen() {
        guard let index = navigationIndex,
              let previousSong = songs[..<index].last(where: \.isIncluded) else { return }
        selectedSongID = previousSong.id
        openSelected()
    }

    func nextAndOpen() {
        guard let index = navigationIndex,
              index + 1 < songs.endIndex,
              let nextSong = songs[(index + 1)...].first(where: \.isIncluded) else { return }
        selectedSongID = nextSong.id
        openSelected()
    }

    func setIncluded(_ songID: SongItem.ID, included: Bool) {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
        songs[index].isIncluded = included
        let action = included ? "ajouté à" : "retiré de"
        status = "\(songs[index].title) a été \(action) la setlist."
    }

    func moveSongs(from offsets: IndexSet, to destination: Int) {
        songs.move(fromOffsets: offsets, toOffset: destination)
    }

    func moveSelectedUp() {
        guard let index = selectedIndex, index > 0 else { return }
        songs.swapAt(index, index - 1)
    }

    func moveSelectedDown() {
        guard let index = selectedIndex, index + 1 < songs.count else { return }
        songs.swapAt(index, index + 1)
    }

    func playPause() {
        runShortcut { try logic.playPause() }
    }

    func stop() {
        runShortcut { try logic.stop() }
    }

    func returnToBeginning() {
        runShortcut { try logic.returnToBeginning() }
    }

    func toggleCycle() {
        do {
            try logic.toggleCycle()
            cycleEnabled.toggle()
            status = cycleEnabled
                ? "Boucle activée dans Logic."
                : "Boucle désactivée dans Logic."
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func performMIDIAction(_ action: MIDIAction) {
        switch action {
        case .previous:
            previousAndOpen()
        case .next:
            nextAndOpen()
        case .beginning:
            returnToBeginning()
        case .stop:
            stop()
        case .playPause:
            playPause()
        case .cycle:
            toggleCycle()
        }
    }

    private func runShortcut(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showingError = true
        status = "Une erreur est survenue."
    }

    private func updateActiveSetlistAndSave() {
        guard !isApplyingSetlist,
              let activeSetlistID,
              let index = namedSetlists.firstIndex(where: { $0.id == activeSetlistID }) else { return }

        namedSetlists[index].songs = songs
        namedSetlists[index].selectedSongID = selectedSongID
        saveLibrary()
    }

    private func saveLibrary() {
        guard !namedSetlists.isEmpty else { return }
        let state = SavedSetlistLibrary(
            setlists: namedSetlists,
            activeSetlistID: activeSetlistID
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func restore() {
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let library = try? JSONDecoder().decode(SavedSetlistLibrary.self, from: data),
           !library.setlists.isEmpty {
            namedSetlists = library.setlists.map(sanitized)
            let restoredID = library.activeSetlistID.flatMap { candidate in
                namedSetlists.contains(where: { $0.id == candidate }) ? candidate : nil
            }
            let setlistID = restoredID ?? namedSetlists[0].id
            if let setlist = namedSetlists.first(where: { $0.id == setlistID }) {
                apply(setlist)
                status = "Setlist « \(setlist.name) » restaurée."
            }
            return
        }

        if let legacyData = UserDefaults.standard.data(forKey: legacyPersistenceKey),
           let legacyState = try? JSONDecoder().decode(LegacySavedState.self, from: legacyData) {
            let migrated = sanitized(
                NamedSetlist(
                    name: "Set principal",
                    songs: legacyState.songs,
                    selectedSongID: legacyState.selectedSongID
                )
            )
            namedSetlists = [migrated]
            apply(migrated)
            saveLibrary()
            UserDefaults.standard.removeObject(forKey: legacyPersistenceKey)
            status = "Setlist précédente migrée vers « Set principal »."
            return
        }

        let initial = NamedSetlist(
            name: "Set principal",
            songs: [],
            selectedSongID: nil
        )
        namedSetlists = [initial]
        apply(initial)
        saveLibrary()
    }

    private func apply(_ setlist: NamedSetlist) {
        isApplyingSetlist = true
        activeSetlistID = setlist.id
        songs = setlist.songs
        selectedSongID = songs.contains(where: { $0.id == setlist.selectedSongID })
            ? setlist.selectedSongID
            : songs.first?.id
        if !songs.contains(where: { $0.id == openedSongID }) {
            openedSongID = nil
        }
        cycleEnabled = false
        isApplyingSetlist = false
    }

    private func sanitized(_ setlist: NamedSetlist) -> NamedSetlist {
        var sanitizedSetlist = setlist
        sanitizedSetlist.songs = setlist.songs.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if !sanitizedSetlist.songs.contains(where: { $0.id == setlist.selectedSongID }) {
            sanitizedSetlist.selectedSongID = sanitizedSetlist.songs.first?.id
        }
        return sanitizedSetlist
    }

    private func uniqueSetlistName(from requestedName: String, excluding excludedID: UUID? = nil) -> String {
        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmedName.isEmpty ? "Nouvelle setlist" : trimmedName
        let existingNames = Set(
            namedSetlists
                .filter { $0.id != excludedID }
                .map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        )

        let normalizedBase = baseName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        guard existingNames.contains(normalizedBase) else { return baseName }

        var suffix = 2
        while existingNames.contains(
            "\(baseName) \(suffix)".folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        ) {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }
}
