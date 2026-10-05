import Foundation

struct ProfileStore {
    let directory: URL

    init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("com.lingj.shadowbat", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    }

    func load() throws -> [ServerProfile] {
        let url = directory.appendingPathComponent("profiles.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ServerProfile].self, from: Data(contentsOf: url))
    }

    func save(_ profiles: [ServerProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent("profiles.json")
        try encoder.encode(profiles).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
