import Foundation
import SisyphusCore

/// Saved rides, one JSON file each in Application Support, newest first.
@MainActor
final class RideStore: ObservableObject {
    @Published private(set) var rides: [RideLog] = []
    let directory: URL

    init(directory: URL = RideStore.defaultDirectory) {
        self.directory = directory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard var ride = try? JSONDecoder().decode(RideLog.self, from: Data(contentsOf: file)) else { continue }
            // Nothing is recording yet, so an unended ride was cut short by a crash or power loss.
            // Keep what the last autosave captured.
            if ride.end == nil {
                guard !ride.samples.isEmpty else { try? FileManager.default.removeItem(at: file); continue }
                ride.end = ride.finish
                try? write(ride)
            }
            rides.append(ride)
        }
        rides.sort { $0.start > $1.start }
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sisyphus/Rides", isDirectory: true)
    }

    func ride(_ id: UUID) -> RideLog? { rides.first { $0.id == id } }

    /// Saves and lists a ride.
    func save(_ ride: RideLog) throws {
        try write(ride)
        if let index = rides.firstIndex(where: { $0.id == ride.id }) { rides[index] = ride }
        else { rides.append(ride); rides.sort { $0.start > $1.start } }
    }

    /// Saves without listing: the in-progress autosave, which only surfaces if the app never ends it.
    func write(_ ride: RideLog) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(ride).write(to: file(for: ride.id), options: .atomic)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
        rides.removeAll { $0.id == id }
    }

    private func file(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}
