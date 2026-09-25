import Combine
import CoreMIDI
import Foundation

@MainActor
final class LogicSyncManager: ObservableObject {
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var hasReceivedTimecode = false
    @Published private(set) var virtualPortAvailable = false
    @Published private(set) var status = "Initialisation de TrackRelay Sync…"

    let virtualPortName = "TrackRelay Sync"

    private let virtualPortUniqueIDKey = "trackrelay.mtc.virtualDestinationUniqueID.v1"
    private var client = MIDIClientRef()
    private var destination = MIDIEndpointRef()
    private var timer: Timer?
    private var lastQuarterFrameDate: Date?
    private var absoluteOrigin: TimeInterval?
    private var quarterFrameNibbles = [UInt8](repeating: 0, count: 8)
    private var receivedNibbleMask: UInt8 = 0
    private var expectsQuarterFrameData = false
    private var systemExclusiveBytes: [UInt8] = []

    init() {
        setupVirtualDestination()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPlaybackState()
            }
        }
    }

    deinit {
        timer?.invalidate()
        if destination != 0 {
            MIDIEndpointDispose(destination)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    func resetForSong() {
        resetPosition()
    }

    func resetPosition() {
        position = 0
        isPlaying = false
        hasReceivedTimecode = false
        lastQuarterFrameDate = nil
        absoluteOrigin = nil
        receivedNibbleMask = 0
        quarterFrameNibbles = [UInt8](repeating: 0, count: 8)
        status = virtualPortAvailable
            ? "En attente du timecode de Logic Pro…"
            : "Destination MIDI virtuelle indisponible."
    }

    private func setupVirtualDestination() {
        let clientStatus = MIDIClientCreate("TrackRelay Sync Client" as CFString, nil, nil, &client)
        guard clientStatus == noErr else {
            status = "Impossible d’initialiser la synchronisation MTC (erreur \(clientStatus))."
            return
        }

        let destinationStatus = MIDIDestinationCreateWithBlock(
            client,
            virtualPortName as CFString,
            &destination
        ) { [weak self] packetList, _ in
            let bytes = Self.bytes(from: packetList)
            guard !bytes.isEmpty else { return }

            Task { @MainActor [weak self] in
                self?.receive(bytes)
            }
        }

        guard destinationStatus == noErr else {
            status = "Impossible de créer TrackRelay Sync (erreur \(destinationStatus))."
            return
        }

        persistVirtualDestinationIdentity()

        virtualPortAvailable = true
        status = "En attente du timecode de Logic Pro…"
    }

    /// Logic mémorise une destination MIDI avec son `kMIDIPropertyUniqueID`,
    /// pas uniquement avec son nom. Une destination virtuelle reçoit sinon un
    /// nouvel identifiant à chaque lancement, ce qui invalide le réglage MTC
    /// enregistré dans Logic.
    private func persistVirtualDestinationIdentity() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: virtualPortUniqueIDKey) != nil {
            let savedID = MIDIUniqueID(defaults.integer(forKey: virtualPortUniqueIDKey))
            if savedID != 0,
               MIDIObjectSetIntegerProperty(destination, kMIDIPropertyUniqueID, savedID) == noErr {
                return
            }
        }

        var assignedID = MIDIUniqueID()
        if MIDIObjectGetIntegerProperty(
            destination,
            kMIDIPropertyUniqueID,
            &assignedID
        ) == noErr, assignedID != 0 {
            defaults.set(Int(assignedID), forKey: virtualPortUniqueIDKey)
        }
    }

    private func receive(_ bytes: [UInt8]) {
        for byte in bytes {
            if !systemExclusiveBytes.isEmpty {
                if byte >= 0xF8 { continue }
                systemExclusiveBytes.append(byte)
                if byte == 0xF7 {
                    receiveFullFrame(systemExclusiveBytes)
                    systemExclusiveBytes.removeAll(keepingCapacity: true)
                }
                continue
            }

            if byte == 0xF0 {
                systemExclusiveBytes = [byte]
                expectsQuarterFrameData = false
                continue
            }

            if byte == 0xF1 {
                expectsQuarterFrameData = true
                continue
            }

            if expectsQuarterFrameData, byte < 0x80 {
                expectsQuarterFrameData = false
                receiveQuarterFrame(byte)
            }
        }
    }

    private func receiveQuarterFrame(_ data: UInt8) {
        let messageType = Int((data >> 4) & 0x07)
        quarterFrameNibbles[messageType] = data & 0x0F
        receivedNibbleMask |= UInt8(1 << messageType)
        lastQuarterFrameDate = Date()
        isPlaying = true

        guard messageType == 7, receivedNibbleMask == 0xFF else { return }
        receivedNibbleMask = 0

        let frames = Int(quarterFrameNibbles[0]) | (Int(quarterFrameNibbles[1] & 0x01) << 4)
        let seconds = Int(quarterFrameNibbles[2]) | (Int(quarterFrameNibbles[3] & 0x03) << 4)
        let minutes = Int(quarterFrameNibbles[4]) | (Int(quarterFrameNibbles[5] & 0x03) << 4)
        let hours = Int(quarterFrameNibbles[6]) | (Int(quarterFrameNibbles[7] & 0x01) << 4)
        let frameRateCode = Int((quarterFrameNibbles[7] >> 1) & 0x03)
        updatePosition(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: frames,
            framesPerSecond: Self.framesPerSecond(for: frameRateCode)
        )
    }

    private func receiveFullFrame(_ bytes: [UInt8]) {
        guard bytes.count >= 10,
              bytes[0] == 0xF0,
              bytes[1] == 0x7F,
              bytes[3] == 0x01,
              bytes[4] == 0x01,
              bytes.last == 0xF7 else { return }

        let hourAndRate = bytes[5]
        let frameRateCode = Int((hourAndRate >> 5) & 0x03)
        updatePosition(
            hours: Int(hourAndRate & 0x1F),
            minutes: Int(bytes[6]),
            seconds: Int(bytes[7]),
            frames: Int(bytes[8]),
            framesPerSecond: Self.framesPerSecond(for: frameRateCode)
        )
    }

    private func updatePosition(
        hours: Int,
        minutes: Int,
        seconds: Int,
        frames: Int,
        framesPerSecond: Double
    ) {
        let absoluteTime = Double(hours * 3_600 + minutes * 60 + seconds)
            + Double(frames) / framesPerSecond

        if absoluteOrigin == nil || absoluteTime < (absoluteOrigin ?? 0) {
            absoluteOrigin = absoluteTime
        }

        position = max(0, absoluteTime - (absoluteOrigin ?? absoluteTime))
        hasReceivedTimecode = true
        status = "Synchronisé avec Logic Pro."
    }

    private func refreshPlaybackState() {
        guard let lastQuarterFrameDate else {
            isPlaying = false
            return
        }
        isPlaying = Date().timeIntervalSince(lastQuarterFrameDate) < 0.5
    }

    nonisolated private static func framesPerSecond(for code: Int) -> Double {
        switch code {
        case 0: 24
        case 1: 25
        case 2: 29.97
        default: 30
        }
    }

    nonisolated private static func bytes(
        from packetList: UnsafePointer<MIDIPacketList>
    ) -> [UInt8] {
        var result: [UInt8] = []

        // La séquence CoreMIDI conserve les pointeurs dans la MIDIPacketList
        // originale. Ne jamais appeler MIDIPacketNext sur une copie locale du
        // premier paquet : les paquets suivants sont de taille variable.
        for packetPointer in packetList.unsafeSequence() {
            result.append(contentsOf: packetPointer.bytes())
        }
        return result
    }
}
