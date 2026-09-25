import SwiftUI

struct PerformanceView: View {
    @ObservedObject var model: SetlistViewModel
    @ObservedObject var sync: LogicSyncManager
    @Binding var autoOpenNextProject: Bool
    let onTransportAction: (MIDIAction) -> Void
    let close: () -> Void

    private var song: SongItem? {
        model.performanceSong
    }

    private var currentSection: SongSection? {
        guard let song else { return nil }
        if let reachedSection = song.sections.last(where: { $0.startTime <= sync.position }) {
            return reachedSection
        }

        // L’export des marqueurs audio peut décaler « Intro » de quelques
        // images après 0:00. On le considère comme actif au démarrage lorsque
        // ce décalage reste inférieur à une seconde.
        guard let firstSection = song.sections.first,
              firstSection.startTime <= 1 else { return nil }
        return firstSection
    }

    private var nextSong: SongItem? {
        guard let currentID = song?.id,
              let index = model.setlistSongs.firstIndex(where: { $0.id == currentID }),
              index + 1 < model.setlistSongs.count else { return nil }
        return model.setlistSongs[index + 1]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider().overlay(Color.white.opacity(0.15))

                if let song {
                    HStack(alignment: .top, spacing: 28) {
                        performanceArea(song)
                        setlistPanel(currentSong: song)
                    }
                    .padding(28)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                        Text("Aucune chanson")
                            .font(.title2.bold())
                        Text("Charge une setlist pour utiliser le mode scène.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button(action: close) {
                Label("Setlist", systemImage: "chevron.left")
            }

            Text("v\(AppVersion.current)")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                Circle()
                    .fill(sync.isPlaying ? Color.green : (sync.hasReceivedTimecode ? Color.orange : Color.red))
                    .frame(width: 9, height: 9)
                Text(sync.isPlaying ? "LECTURE" : (sync.hasReceivedTimecode ? "PAUSE" : "MTC EN ATTENTE"))
                    .font(.caption.bold())
            }

            Label(
                model.cycleEnabled ? "BOUCLE ON" : "BOUCLE OFF",
                systemImage: "repeat"
            )
            .font(.caption.bold())
            .foregroundStyle(model.cycleEnabled ? Color.yellow : Color.secondary)

            Button {
                autoOpenNextProject.toggle()
            } label: {
                Label(
                    autoOpenNextProject ? "SUIVANT AUTO" : "SUIVANT MANUEL",
                    systemImage: "forward.end"
                )
                .font(.caption.bold())
                .foregroundStyle(autoOpenNextProject ? Color.cyan : Color.secondary)
            }
            .help("Ouvrir automatiquement le projet suivant à la fin de la chanson")

            Spacer()

            if let nextSong {
                Text("ENSUITE")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(nextSong.title)
                    .font(.headline)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }

    private func performanceArea(_ song: SongItem) -> some View {
        let playbackDuration = song.playbackDuration(
            automaticEndMarkerEnabled: autoOpenNextProject
        )

        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Text(currentSection?.name ?? (song.sections.isEmpty ? "Aucune section" : "Avant le premier marqueur"))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
            }

            TimelineProgressView(
                position: sync.position,
                duration: playbackDuration,
                sections: song.sections
            )
            .frame(height: 74)

            HStack {
                timeBlock("ÉCOULÉ", value: DurationText.format(sync.position))
                Spacer()
                timeBlock(
                    "RESTANT",
                    value: playbackDuration.map { "−" + DurationText.format(max(0, $0 - sync.position)) } ?? "—"
                )
            }

            if !sync.hasReceivedTimecode {
                syncInstructions
            }

            Spacer(minLength: 12)
            transportControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func setlistPanel(currentSong: SongItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.activeSetlistName.uppercased())
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.setlistSongs.count) chanson\(model.setlistSongs.count > 1 ? "s" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(Array(model.setlistSongs.enumerated()), id: \.element.id) { index, setlistSong in
                            setlistRow(
                                setlistSong,
                                index: index,
                                isCurrent: setlistSong.id == currentSong.id,
                                isPast: index < (model.setlistSongs.firstIndex(where: { $0.id == currentSong.id }) ?? 0)
                            )
                            .id(setlistSong.id)
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo(currentSong.id, anchor: .center)
                }
                .onChange(of: currentSong.id) { songID in
                    withAnimation { proxy.scrollTo(songID, anchor: .center) }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
                .overlay(Color.white.opacity(0.12))

            HStack(alignment: .lastTextBaseline) {
                Text("TEMPS TOTAL DU SET")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Spacer()

                Text(model.totalDurationText(automaticEndMarkerEnabled: autoOpenNextProject))
                    .font(.title2.monospacedDigit().bold())
                    .foregroundStyle(.cyan)
            }
            .padding(.top, 5)
        }
        .padding(18)
        .frame(width: 315)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func setlistRow(
        _ setlistSong: SongItem,
        index: Int,
        isCurrent: Bool,
        isPast: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(isCurrent ? Color.cyan : Color.secondary)
                .frame(width: 24, alignment: .trailing)

            Capsule()
                .fill(isCurrent ? Color.cyan : Color.white.opacity(0.18))
                .frame(width: 4, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(setlistSong.title)
                    .fontWeight(isCurrent ? .bold : .regular)
                    .lineLimit(1)

                if isCurrent {
                    Text("EN COURS")
                        .font(.caption2.bold())
                        .foregroundStyle(.cyan)
                } else {
                    Text(setlistSong.formattedDuration(automaticEndMarkerEnabled: autoOpenNextProject))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if !isCurrent && !isPast {
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isCurrent ? Color.cyan.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .opacity(isPast ? 0.42 : 1)
    }

    private var syncInstructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Active le timecode MIDI dans Logic", systemImage: "waveform.path.ecg")
                .font(.headline)
            Text("Fichier > Réglages du projet > Synchronisation > MIDI : choisis « \(sync.virtualPortName) » comme destination et coche MTC. Ce réglage est enregistré dans chaque projet Logic.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35)))
    }

    private var transportControls: some View {
        HStack(spacing: 14) {
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
                onTransportAction(.stop)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }

            Button {
                onTransportAction(.playPause)
            } label: {
                Label("Lecture / Pause", systemImage: "playpause.fill")
            }
            .buttonStyle(.borderedProminent)

            Button {
                model.toggleCycle()
            } label: {
                Label(
                    model.cycleEnabled ? "Boucle ON" : "Boucle OFF",
                    systemImage: "repeat"
                )
                .foregroundStyle(model.cycleEnabled ? Color.yellow : Color.primary)
            }

            Spacer()

            Button {
                model.nextAndOpen()
            } label: {
                Label("Suivant", systemImage: "forward.end.fill")
            }
            .disabled(!model.canOpenNext || model.isOpening)
        }
        .controlSize(.large)
    }

    private func timeBlock(_ label: String, value: String) -> some View {
        VStack(alignment: label == "ÉCOULÉ" ? .leading : .trailing, spacing: 2) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
        }
    }
}

private struct TimelineProgressView: View {
    let position: TimeInterval
    let duration: TimeInterval?
    let sections: [SongSection]

    private var progress: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(0.13))

                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * progress)

                if let duration, duration > 0 {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        let markerProgress = min(max(section.startTime / duration, 0), 1)
                        let nextStart = index + 1 < sections.count
                            ? sections[index + 1].startTime
                            : duration
                        let nextProgress = min(max(nextStart / duration, 0), 1)
                        let segmentWidth = geometry.size.width * max(0, nextProgress - markerProgress)

                        Rectangle()
                            .fill(Color.white.opacity(0.75))
                            .frame(width: 2, height: geometry.size.height)
                            .position(
                                x: geometry.size.width * markerProgress,
                                y: geometry.size.height / 2
                            )

                        Text(section.name)
                            .font(.caption2.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 2)
                            .frame(width: max(0, segmentWidth - 10))
                            .position(
                                x: geometry.size.width * markerProgress + segmentWidth / 2,
                                y: geometry.size.height / 2
                            )
                    }
                }
            }
        }
    }
}
