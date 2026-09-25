import AppKit
import ApplicationServices
import Foundation

@MainActor
final class LogicController {
    enum LogicError: LocalizedError {
        case fileMissing(String)
        case openFailed(String)
        case shortcutFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileMissing(let path):
                return "Fichier introuvable : \(path)"
            case .openFailed(let message):
                return "Impossible d’ouvrir le projet : \(message)"
            case .shortcutFailed(let message):
                return "Commande refusée par macOS : \(message)"
            }
        }
    }

    private let logicBundleIdentifier = "com.apple.logic10"
    private var focusGuardTimer: Timer?

    /// Ouvre le projet demandé puis attend que sa fenêtre soit réellement active
    /// avant de replacer la tête de lecture au début.
    /// - Returns: `true` si le retour au début a bien été envoyé à Logic.
    func openProject(_ song: SongItem) async throws -> Bool {
        let fileURL = song.url
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LogicError.fileMissing(fileURL.path)
        }

        // Logic peut tenter de passer au premier plan plusieurs fois pendant
        // la restauration d’un projet. Le garde-fou maintient TrackRelay devant
        // tout en laissant la méthode d’ouverture fiable de cette version.
        beginTrackRelayFocusGuard()
        defer { endTrackRelayFocusGuard() }

        guard let logicURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: logicBundleIdentifier) else {
            // Le système peut encore connaître une autre application associée aux .logicx.
            if NSWorkspace.shared.open(fileURL) {
                return await waitForProjectAndReturnToBeginning(song)
            }
            throw LogicError.openFailed("Logic Pro n’est pas installé ou n’est pas associé aux fichiers .logicx.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                [fileURL],
                withApplicationAt: logicURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: LogicError.openFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        return await waitForProjectAndReturnToBeginning(song)
    }

    func playPause() throws {
        try sendLogicKey(code: 49) // Barre espace avec les raccourcis Logic par défaut.
    }

    func stop() throws {
        try sendLogicKey(code: 82) // 0 du pavé numérique avec les raccourcis Logic par défaut.
    }

    func returnToBeginning() throws {
        try sendLogicKey(code: 36) // Retour/Entrée avec les raccourcis Logic par défaut.
    }

    func toggleCycle() throws {
        try sendLogicKey(code: 8) // Touche C : active/désactive le mode Cycle dans Logic.
    }

    private func sendLogicKey(code: Int) throws {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            throw LogicError.shortcutFailed(
                "Autorise TrackRelay dans Confidentialité et sécurité > Accessibilité, puis relance l’application."
            )
        }

        guard let logicApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: logicBundleIdentifier
        ).first(where: { !$0.isTerminated }) else {
            throw LogicError.shortcutFailed("Logic Pro n’est pas lancé.")
        }

        // L’activation très brève conserve le comportement fiable de la
        // version stable pour les raccourcis Logic. Le focus revient à
        // TrackRelay dès que les événements ont été transmis au PID de Logic.
        logicApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        defer { restoreTrackRelayFocus() }

        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(code),
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(code),
                keyDown: false
            )
        else {
            throw LogicError.shortcutFailed("Impossible de créer l’événement clavier.")
        }

        // L’événement est envoyé directement au PID de Logic : il ne peut plus
        // être capturé par la fenêtre de TrackRelay ou une autre application.
        keyDown.postToPid(logicApp.processIdentifier)
        keyUp.postToPid(logicApp.processIdentifier)
    }

    private func beginTrackRelayFocusGuard() {
        focusGuardTimer?.invalidate()
        restoreTrackRelayFocus()

        focusGuardTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restoreTrackRelayFocus()
            }
        }
    }

    private func endTrackRelayFocusGuard() {
        focusGuardTimer?.invalidate()
        focusGuardTimer = nil
        restoreTrackRelayFocus()
    }

    private func restoreTrackRelayFocus() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                != NSRunningApplication.current.processIdentifier else { return }

        NSRunningApplication.current.activate(options: [
            .activateAllWindows,
            .activateIgnoringOtherApps
        ])
    }

    private func waitForProjectAndReturnToBeginning(_ song: SongItem) async -> Bool {
        // Les projets du MVP sont légers, mais NSWorkspace répond avant que
        // Logic ait entièrement restauré la position de lecture mémorisée.
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        var commandWasSent = false

        // Deux envois espacés : le premier couvre les ouvertures rapides, le
        // second intervient après la restauration complète du projet. Revenir
        // deux fois au début est sans effet secondaire.
        for delay in [UInt64(0), UInt64(1_000_000_000)] {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }

            do {
                try sendLogicKey(code: 36)
                commandWasSent = true
            } catch {
                // On tente tout de même le second envoi si le premier échoue.
            }
        }

        return commandWasSent
    }
}
