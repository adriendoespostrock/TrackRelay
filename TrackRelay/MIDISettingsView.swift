import CoreMIDI
import SwiftUI

struct MIDISettingsView: View {
    @ObservedObject var manager: MIDIControllerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Commandes MIDI")
                        .font(.title2.bold())
                    Text("Assigne un bouton de ton contrôleur à chaque action.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Terminé") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack {
                Picker("Entrée", selection: $manager.selectedSourceID) {
                    Text("Aucune").tag(nil as MIDIUniqueID?)

                    if let selectedSourceID = manager.selectedSourceID,
                       !manager.sources.contains(where: { $0.id == selectedSourceID }) {
                        Text("Entrée mémorisée indisponible")
                            .tag(Optional(selectedSourceID))
                    }

                    ForEach(manager.sources) { source in
                        Text(source.name).tag(Optional(source.id))
                    }
                }
                .frame(maxWidth: .infinity)

                Button {
                    manager.refreshSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Actualiser les entrées MIDI")
            }

            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(MIDIAction.allCases.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { Divider() }
                        bindingRow(action)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Label(manager.status, systemImage: manager.isConnected ? "cable.connector" : "info.circle")
                Text("Dernier signal : \(manager.lastMessage)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Text("Messages acceptés : Note On, Control Change (CC) et Program Change (PC). Les messages de relâchement sont ignorés.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 610)
        .onAppear { manager.refreshSources() }
    }

    private func bindingRow(_ action: MIDIAction) -> some View {
        HStack(spacing: 12) {
            Label(action.title, systemImage: action.systemImage)
                .frame(width: 150, alignment: .leading)

            Text(manager.bindings[action]?.description ?? "Non assigné")
                .foregroundStyle(manager.bindings[action] == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if manager.learningAction == action {
                ProgressView()
                    .controlSize(.small)
                Button("Annuler") { manager.cancelLearning() }
            } else {
                Button("Apprendre") { manager.beginLearning(action) }
                    .disabled(!manager.isConnected || manager.learningAction != nil)

                Button {
                    manager.clearBinding(for: action)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Effacer cette assignation")
                .disabled(manager.bindings[action] == nil)
            }
        }
        .padding(.vertical, 10)
    }
}

