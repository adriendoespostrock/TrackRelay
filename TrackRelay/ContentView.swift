import SwiftUI
import UniformTypeIdentifiers

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

private enum SetlistNameAction: Equatable {
    case create
    case duplicate
    case rename
}

struct ContentView: View {
    @StateObject private var model = SetlistViewModel()
    @StateObject private var midi = MIDIControllerManager()
    @StateObject private var sync = LogicSyncManager()
    @State private var draggedSongID: UUID?
    @State private var showingMIDISettings = false
    @State private var performanceMode = false
    @State private var playbackStartedForOpenedSong = false
    @State private var suppressAutoAdvanceForNextStop = false
    @State private var setlistNameAction: SetlistNameAction?
    @State private var setlistNameDraft = ""
    @State private var showingDeleteSetlistConfirmation = false
    @AppStorage("trackrelay.autoOpenNextProject") private var autoOpenNextProject = false

    var body: some View {
        Group {
            if performanceMode {
                PerformanceView(
                    model: model,
                    sync: sync,
                    autoOpenNextProject: $autoOpenNextProject,
                    onTransportAction: performTransportAction
                ) {
                    performanceMode = false
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    setlist
                    Divider()
                    controls
                    Divider()
                    statusBar
                }
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .alert("TrackRelay", isPresented: $model.showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.errorMessage)
        }
        .alert(setlistNameDialogTitle, isPresented: setlistNameDialogPresented) {
            TextField("Nom de la setlist", text: $setlistNameDraft)
            Button("Annuler", role: .cancel) {
                setlistNameAction = nil
            }
            Button(setlistNameAction == .rename ? "Renommer" : "Créer") {
                completeSetlistNameAction()
            }
            .disabled(setlistNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(setlistNameDialogMessage)
        }
        .alert("Supprimer cette setlist ?", isPresented: $showingDeleteSetlistConfirmation) {
            Button("Annuler", role: .cancel) { }
            Button("Supprimer", role: .destructive) {
                model.deleteActiveSetlist()
            }
        } message: {
            Text("La setlist « \(model.activeSetlistName) » sera supprimée. Les projets Logic ne seront pas effacés.")
        }
        .sheet(isPresented: $showingMIDISettings) {
            MIDISettingsView(manager: midi)
        }
        .onAppear {
            midi.onAction = { action in
                performTransportAction(action)
            }
        }
        .onChange(of: model.openedSongID) { _ in
            playbackStartedForOpenedSong = false
            suppressAutoAdvanceForNextStop = false
            sync.resetForSong()
        }
        .onChange(of: sync.isPlaying) { isPlaying in
            handlePlaybackStateChange(isPlaying: isPlaying)
        }
        .onChange(of: autoOpenNextProject) { enabled in
            if !enabled {
                playbackStartedForOpenedSong = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("TrackRelay")
                        .font(.title2.bold())
                    Text("v\(AppVersion.current)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                HStack(spacing: 6) {
                    Picker("Setlist", selection: activeSetlistBinding) {
                        ForEach(model.namedSetlists) { setlist in
                            Text(setlist.name).tag(Optional(setlist.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .disabled(model.isOpening || model.isReadingDurations)

                    Menu {
                        Button {
                            presentSetlistNameAction(.create)
                        } label: {
                            Label("Nouvelle setlist", systemImage: "plus")
                        }

                        Button {
                            presentSetlistNameAction(.duplicate)
                        } label: {
                            Label("Dupliquer la setlist", systemImage: "plus.square.on.square")
                        }

                        Divider()

                        Button {
                            presentSetlistNameAction(.rename)
                        } label: {
                            Label("Renommer", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            showingDeleteSetlistConfirmation = true
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                        .disabled(model.namedSetlists.count <= 1)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.isOpening || model.isReadingDurations)
                    .help("Créer, dupliquer, renommer ou supprimer une setlist")
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Durée du set · \(model.setlistSongs.count)/\(model.songs.count) chansons")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text(model.totalDurationText(automaticEndMarkerEnabled: autoOpenNextProject))
                        .font(.headline.monospacedDigit())
                    if model.missingDurationCount > 0 {
                        Text("+ \(model.missingDurationCount) ?")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Certaines durées sont inconnues et ne sont pas incluses dans le total.")
                    }
                }
            }

            Button {
                model.refreshDurations()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Recalculer les durées")
            .disabled(model.songs.isEmpty || model.isReadingDurations)

            Button {
                showingMIDISettings = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(midi.isConnected ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text("MIDI…")
                }
            }
            .help(midi.isConnected ? "Entrée MIDI connectée" : "Configurer les commandes MIDI")

            Button {
                performanceMode = true
            } label: {
                Label("Mode scène", systemImage: "play.rectangle.fill")
            }
            .disabled(model.setlistSongs.isEmpty)

            Button("Choisir un dossier…") {
                model.chooseFolder()
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
        .padding()
    }

    private var setlist: some View {
        List(selection: $model.selectedSongID) {
            ForEach(model.songs) { song in
                let setIndex = model.setlistSongs.firstIndex(where: { $0.id == song.id })
                HStack(spacing: 12) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { song.isIncluded },
                            set: { model.setIncluded(song.id, included: $0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(song.isIncluded ? "Retirer de la setlist" : "Ajouter à la setlist")

                    Text(setIndex.map { String(format: "%02d", $0 + 1) } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .fontWeight(song.id == model.openedSongID ? .semibold : .regular)
                        Text(song.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !song.isIncluded {
                            Text("Hors setlist")
                                .font(.caption2.bold())
                                .foregroundStyle(.orange)
                        }
                    }

                    Spacer()

                    Text(song.formattedDuration(automaticEndMarkerEnabled: autoOpenNextProject))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(song.duration == nil ? .secondary : .primary)
                        .frame(width: 70, alignment: .trailing)

                    if song.id == model.openedSongID {
                        Label("Dans Logic", systemImage: "waveform")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .opacity(song.isIncluded ? 1 : 0.55)
                .tag(song.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    model.selectedSongID = song.id
                    model.openSelected()
                }
                .onDrag {
                    draggedSongID = song.id
                    return NSItemProvider(object: song.id.uuidString as NSString)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: SongDropDelegate(
                        destinationSongID: song.id,
                        songs: $model.songs,
                        draggedSongID: $draggedSongID
                    )
                )
            }
        }
        .overlay {
            if model.songs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Aucune chanson")
                        .font(.headline)
                    Text("Choisis un dossier contenant un fichier .logicx par chanson.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    model.moveSelectedUp()
                } label: {
                    Label("Monter", systemImage: "arrow.up")
                }
                .disabled(model.selectedIndex == nil || model.selectedIndex == 0)

                Button {
                    model.moveSelectedDown()
                } label: {
                    Label("Descendre", systemImage: "arrow.down")
                }
                .disabled(model.selectedIndex == nil || model.selectedIndex == model.songs.count - 1)

                Spacer()

                Button {
                    model.openSelected()
                } label: {
                    Label(model.isOpening ? "Ouverture…" : "Ouvrir dans Logic", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedSong == nil || model.isOpening)

                Toggle("Projet suivant automatique", isOn: $autoOpenNextProject)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Ouvre le projet suivant à l’arrêt du MTC. Stop et Lecture/Pause depuis TrackRelay sont ignorés. Logic ne distingue pas par MTC une fin de projet d’une pause faite directement dans Logic.")
            }

            HStack(spacing: 10) {
                Button {
                    model.previousAndOpen()
                } label: {
                    Label("Précédent", systemImage: "backward.end.fill")
                }
                .disabled(!model.canOpenPrevious || model.isOpening)

                Spacer()

                Button {
                    model.returnToBeginning()
                    sync.resetPosition()
                } label: {
                    Label("Début", systemImage: "backward.end")
                }

                Button {
                    performTransportAction(.stop)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }

                Button {
                    performTransportAction(.playPause)
                } label: {
                    Label("Lecture / Pause", systemImage: "playpause.fill")
                }

                Button {
                    model.toggleCycle()
                } label: {
                    Label(
                        model.cycleEnabled ? "Boucle ON" : "Boucle OFF",
                        systemImage: "repeat"
                    )
                    .foregroundStyle(model.cycleEnabled ? Color.yellow : Color.primary)
                }
                .help("Activer ou désactiver le mode Cycle dans Logic")

                Spacer()

                Button {
                    model.nextAndOpen()
                } label: {
                    Label("Suivant", systemImage: "forward.end.fill")
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!model.canOpenNext || model.isOpening)
            }
        }
        .padding()
    }

    private var statusBar: some View {
        HStack {
            if model.isOpening {
                ProgressView()
                    .controlSize(.small)
            } else if model.isReadingDurations {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
    }

    private func handlePlaybackStateChange(isPlaying: Bool) {
        if isPlaying {
            playbackStartedForOpenedSong = true
            suppressAutoAdvanceForNextStop = false
            return
        }

        guard playbackStartedForOpenedSong else { return }
        playbackStartedForOpenedSong = false

        guard !suppressAutoAdvanceForNextStop else {
            suppressAutoAdvanceForNextStop = false
            return
        }

        guard autoOpenNextProject, !model.isOpening else { return }
        guard model.canOpenNext else { return }
        model.nextAndOpen()
    }

    private func performTransportAction(_ action: MIDIAction) {
        if action == .stop || action == .playPause {
            suppressAutoAdvanceForNextStop = true
        }
        model.performMIDIAction(action)
        if action == .beginning {
            sync.resetPosition()
        }
    }

    private var activeSetlistBinding: Binding<UUID?> {
        Binding(
            get: { model.activeSetlistID },
            set: { newValue in
                if let newValue {
                    model.activateSetlist(newValue)
                }
            }
        )
    }

    private var setlistNameDialogPresented: Binding<Bool> {
        Binding(
            get: { setlistNameAction != nil },
            set: { isPresented in
                if !isPresented {
                    setlistNameAction = nil
                }
            }
        )
    }

    private var setlistNameDialogTitle: String {
        switch setlistNameAction {
        case .create: "Nouvelle setlist"
        case .duplicate: "Dupliquer la setlist"
        case .rename: "Renommer la setlist"
        case nil: "Setlist"
        }
    }

    private var setlistNameDialogMessage: String {
        switch setlistNameAction {
        case .create:
            "Toutes les chansons actuelles seront disponibles, mais décochées."
        case .duplicate:
            "L’ordre et les chansons incluses seront copiés."
        case .rename:
            "Choisis le nouveau nom de cette setlist."
        case nil:
            ""
        }
    }

    private func presentSetlistNameAction(_ action: SetlistNameAction) {
        setlistNameAction = action
        switch action {
        case .create:
            setlistNameDraft = "Nouvelle setlist"
        case .duplicate:
            setlistNameDraft = "\(model.activeSetlistName) copie"
        case .rename:
            setlistNameDraft = model.activeSetlistName
        }
    }

    private func completeSetlistNameAction() {
        guard let action = setlistNameAction else { return }
        let name = setlistNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        switch action {
        case .create:
            model.createSetlist(named: name, duplicatingCurrent: false)
        case .duplicate:
            model.createSetlist(named: name, duplicatingCurrent: true)
        case .rename:
            model.renameActiveSetlist(to: name)
        }
        setlistNameAction = nil
    }
}

private struct SongDropDelegate: DropDelegate {
    let destinationSongID: UUID
    @Binding var songs: [SongItem]
    @Binding var draggedSongID: UUID?

    func dropEntered(info: DropInfo) {
        guard
            let draggedSongID,
            draggedSongID != destinationSongID,
            let sourceIndex = songs.firstIndex(where: { $0.id == draggedSongID }),
            let destinationIndex = songs.firstIndex(where: { $0.id == destinationSongID })
        else { return }

        withAnimation(.easeInOut(duration: 0.15)) {
            songs.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedSongID = nil
        return true
    }
}
