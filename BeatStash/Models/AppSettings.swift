import Foundation
import SwiftUI

/// User preferences. Backed by UserDefaults + @AppStorage in views.
/// Destination default: `~/Music/BeatStash/<Playlist>/`
public struct AppSettings: Sendable {
    public static var defaultDestination: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        return music.appendingPathComponent("BeatStash", isDirectory: true)
    }

    public static var destinationRoot: URL {
        if let bm = UserDefaults.standard.string(forKey: "destinationRoot"), !bm.isEmpty {
            return URL(fileURLWithPath: bm)
        }
        return defaultDestination
    }

    public static func batchDirectory(playlistTitle: String?) -> URL {
        let root = destinationRoot
        guard let t = playlistTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return root
        }
        return root.appendingPathComponent(sanitized(t), isDirectory: true)
    }

    public static func sanitized(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }
}
