import Foundation

/// Shared test scaffolding: temp dirs + JSON fixtures.
/// Every helper is throwing (never `try!`) so a fixture typo fails the test,
/// not the runner. Callers own cleanup via `defer`.
enum TestHelpers {
    /// Fresh `BeatStashTests-<UUID>` dir under `temporaryDirectory`.
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeatStashTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Decode a JSON literal into a `Decodable` model.
    static func decodeJSON<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
