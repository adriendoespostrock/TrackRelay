import CoreMIDI
import Combine
import Foundation

enum MIDIAction: String, CaseIterable, Codable, Identifiable {
    case previous
    case next
    case beginning
    case stop
    case playPause
    case cycle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previous: "Précédent"
        case .next: "Suivant"
        case .beginning: "Début"
        case .stop: "Stop"
        case .playPause: "Lecture / Pause"
        case .cycle: "Boucle"
        }
    }

    var systemImage: String {
        switch self {
        case .previous: "backward.end.fill"
        case .next: "forward.end.fill"
        case .beginning: "backward.end"
        case .stop: "stop.fill"
        case .playPause: "playpause.fill"
        case .cycle: "repeat"
        }
    }
}

enum MIDIMessageKind: String, Codable {
    case note
    case controlChange
    case programChange

    var shortName: String {
        switch self {
        case .note: "Note"
        case .controlChange: "CC"
        case .programChange: "PC"
        }
    }
}

struct MIDIBinding: Codable, Equatable {
    let kind: MIDIMessageKind
    let channel: Int
    let number: Int

    var description: String {
        "\(kind.shortName) \(number) · canal \(channel)"
    }
}

struct MIDIInputSource: Identifiable, Hashable {
    let id: MIDIUniqueID
    let endpoint: MIDIEndpointRef
    let name: String
}

private struct IncomingMIDIMessage {
    let binding: MIDIBinding
    let value: Int

    var description: String {
        "\(binding.description) · valeur \(value)"
    }
}

@MainActor
final class MIDIControllerManager: ObservableObject {
    @Published private(set) var sources: [MIDIInputSource] = []
    @Published var selectedSourceID: MIDIUniqueID? {
        didSet {
            guard selectedSourceID != oldValue else { return }
            saveSelectedSource()
            connectSelectedSource()
        }
    }
    @Published private(set) var connectedSourceID: MIDIUniqueID?
    @Published private(set) var bindings: [MIDIAction: MIDIBinding] = [:]
    @Published var learningAction: MIDIAction?
    @Published private(set) var lastMessage = "Aucun message MIDI reçu."
    @Published private(set) var status = "Choisis une entrée MIDI."

    var onAction: ((MIDIAction) -> Void)?

    var isConnected: Bool { connectedSourceID != nil }

    private let selectedSourceKey = "trackrelay.midi.selected-source.v1"
    private let bindingsKey = "trackrelay.midi.bindings.v1"
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedEndpoint = MIDIEndpointRef()

    init() {
        if UserDefaults.standard.object(forKey: selectedSourceKey) != nil {
            selectedSourceID = MIDIUniqueID(UserDefaults.standard.integer(forKey: selectedSourceKey))
        }
        if
            let data = UserDefaults.standard.data(forKey: bindingsKey),
            let savedBindings = try? JSONDecoder().decode([MIDIAction: MIDIBinding].self, from: data)
        {
            bindings = savedBindings
        }

        setupMIDI()
        refreshSources()
    }

    deinit {
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    func refreshSources() {
        var availableSources: [MIDIInputSource] = []

        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }

            var uniqueID = MIDIUniqueID()
            guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID) == noErr else {
                continue
            }

            let name = Self.stringProperty(of: endpoint, property: kMIDIPropertyDisplayName)
                ?? Self.stringProperty(of: endpoint, property: kMIDIPropertyName)
                ?? "Entrée MIDI \(index + 1)"
            availableSources.append(MIDIInputSource(id: uniqueID, endpoint: endpoint, name: name))
        }

        sources = availableSources.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        if selectedSourceID == nil, sources.count == 1 {
            selectedSourceID = sources[0].id
        } else {
            connectSelectedSource()
        }

        if sources.isEmpty {
            status = "Aucune entrée MIDI détectée."
        } else if let connectedSourceID,
                  let source = sources.first(where: { $0.id == connectedSourceID }) {
            status = "Connecté à \(source.name)."
        } else if let selectedSourceID,
                  !sources.contains(where: { $0.id == selectedSourceID }) {
            status = "L’entrée MIDI mémorisée n’est pas disponible."
        }
    }

    func beginLearning(_ action: MIDIAction) {
        learningAction = action
        status = "Appuie sur le contrôle MIDI pour « \(action.title) »."
    }

    func cancelLearning() {
        learningAction = nil
        updateConnectionStatus()
    }

    func clearBinding(for action: MIDIAction) {
        bindings.removeValue(forKey: action)
        saveBindings()
    }

    private func setupMIDI() {
        let clientStatus = MIDIClientCreate("TrackRelay MIDI" as CFString, nil, nil, &client)
        guard clientStatus == noErr else {
            status = "Impossible d’initialiser CoreMIDI (erreur \(clientStatus))."
            return
        }

        let portStatus = MIDIInputPortCreateWithBlock(
            client,
            "TrackRelay MIDI Input" as CFString,
            &inputPort
        ) { [weak self] packetList, _ in
            let messages = Self.parse(packetList: packetList)
            guard !messages.isEmpty else { return }

            Task { @MainActor [weak self] in
                for message in messages {
                    self?.receive(message)
                }
            }
        }

        if portStatus != noErr {
            status = "Impossible de créer l’entrée MIDI (erreur \(portStatus))."
        }
    }

    private func connectSelectedSource() {
        guard inputPort != 0 else { return }

        if connectedEndpoint != 0 {
            MIDIPortDisconnectSource(inputPort, connectedEndpoint)
            connectedEndpoint = 0
            connectedSourceID = nil
        }

        guard
            let selectedSourceID,
            let source = sources.first(where: { $0.id == selectedSourceID })
        else {
            updateConnectionStatus()
            return
        }

        let result = MIDIPortConnectSource(inputPort, source.endpoint, nil)
        if result == noErr {
            connectedEndpoint = source.endpoint
            connectedSourceID = source.id
            status = "Connecté à \(source.name)."
        } else {
            status = "Connexion MIDI impossible (erreur \(result))."
        }
    }

    private func receive(_ message: IncomingMIDIMessage) {
        lastMessage = message.description

        if let learningAction {
            bindings = bindings.filter { action, binding in
                action == learningAction || binding != message.binding
            }
            bindings[learningAction] = message.binding
            self.learningAction = nil
            saveBindings()
            status = "« \(learningAction.title) » est assigné à \(message.binding.description)."
            return
        }

        guard let action = bindings.first(where: { $0.value == message.binding })?.key else {
            return
        }
        status = "Commande MIDI : \(action.title)."
        onAction?(action)
    }

    private func updateConnectionStatus() {
        if let connectedSourceID,
           let source = sources.first(where: { $0.id == connectedSourceID }) {
            status = "Connecté à \(source.name)."
        } else if sources.isEmpty {
            status = "Aucune entrée MIDI détectée."
        } else {
            status = "Choisis une entrée MIDI."
        }
    }

    private func saveSelectedSource() {
        if let selectedSourceID {
            UserDefaults.standard.set(Int(selectedSourceID), forKey: selectedSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedSourceKey)
        }
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: bindingsKey)
    }

    private static func stringProperty(
        of object: MIDIObjectRef,
        property: CFString
    ) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    nonisolated private static func parse(
        packetList: UnsafePointer<MIDIPacketList>
    ) -> [IncomingMIDIMessage] {
        var bytes: [UInt8] = []

        for packetPointer in packetList.unsafeSequence() {
            bytes.append(contentsOf: packetPointer.bytes())
        }
        return parse(bytes: bytes)
    }

    nonisolated private static func parse(bytes: [UInt8]) -> [IncomingMIDIMessage] {
        var messages: [IncomingMIDIMessage] = []
        var index = 0
        var runningStatus: UInt8?

        while index < bytes.count {
            let byte = bytes[index]

            if byte >= 0xF8 {
                index += 1
                continue
            }

            let status: UInt8
            if byte & 0x80 != 0 {
                guard byte < 0xF0 else { break }
                status = byte
                runningStatus = byte
                index += 1
            } else if let currentStatus = runningStatus {
                status = currentStatus
            } else {
                index += 1
                continue
            }

            let command = status & 0xF0
            let channel = Int(status & 0x0F) + 1

            if command == 0xC0 {
                guard index < bytes.count else { break }
                let number = Int(bytes[index])
                index += 1
                messages.append(IncomingMIDIMessage(
                    binding: MIDIBinding(kind: .programChange, channel: channel, number: number),
                    value: number
                ))
                continue
            }

            if command == 0xD0 {
                guard index < bytes.count else { break }
                index += 1
                continue
            }

            guard index + 1 < bytes.count else { break }
            let number = Int(bytes[index])
            let value = Int(bytes[index + 1])
            index += 2

            switch command {
            case 0x90 where value > 0:
                messages.append(IncomingMIDIMessage(
                    binding: MIDIBinding(kind: .note, channel: channel, number: number),
                    value: value
                ))
            case 0xB0 where value > 0:
                messages.append(IncomingMIDIMessage(
                    binding: MIDIBinding(kind: .controlChange, channel: channel, number: number),
                    value: value
                ))
            default:
                break
            }
        }

        return messages
    }
}
