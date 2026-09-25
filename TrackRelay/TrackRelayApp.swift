import Foundation
import SwiftUI

@main
struct TrackRelayApp: App {
    init() {
        TrackRelayMigration.migrateLegacyPreferencesIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

/// Récupère une seule fois les réglages créés par les anciennes versions
/// distribuées sous l'identité LogicSetMVP. La migration garde notamment
/// l'identifiant unique de la destination MTC afin que les projets Logic déjà
/// configurés continuent de reconnaître le port virtuel renommé.
private enum TrackRelayMigration {
    private static let legacyBundleIdentifier = "com.adrien.logicsetmvp"
    private static let migrationMarker = "trackrelay.migration.logicset.v1"

    private static let migratedKeys: [(legacy: String, current: String)] = [
        ("logicset.mvp.setlists.v2", "trackrelay.setlists.v2"),
        ("logicset.mvp.state.v1", "trackrelay.legacy.state.v1"),
        ("logicset.midi.selected-source.v1", "trackrelay.midi.selected-source.v1"),
        ("logicset.midi.bindings.v1", "trackrelay.midi.bindings.v1"),
        ("logicset.mtc.virtualDestinationUniqueID.v1", "trackrelay.mtc.virtualDestinationUniqueID.v1"),
        ("logicset.autoOpenNextProject", "trackrelay.autoOpenNextProject")
    ]

    static func migrateLegacyPreferencesIfNeeded() {
        let currentDefaults = UserDefaults.standard
        guard !currentDefaults.bool(forKey: migrationMarker) else { return }

        if let legacyDefaults = UserDefaults(suiteName: legacyBundleIdentifier) {
            for keyPair in migratedKeys where currentDefaults.object(forKey: keyPair.current) == nil {
                if let value = legacyDefaults.object(forKey: keyPair.legacy) {
                    currentDefaults.set(value, forKey: keyPair.current)
                }
            }
        }

        currentDefaults.set(true, forKey: migrationMarker)
    }
}
