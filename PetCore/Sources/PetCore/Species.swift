import Foundation
import Yams

/// Runtime model for a species. `bundleURL` is set by the loader after
/// decoding the YAML wire format; it is intentionally not Codable.
public struct Species: Equatable {
    public let id: String
    public let nameZh: String
    public let nameEn: String
    public let stages: [Stage]
    public let animations: [String: [Int]]
    public let spriteGrid: SpriteGrid
    public let bundleURL: URL

    public struct Stage: Codable, Equatable {
        public let id: String
        public let sprite: String
        public let minXp: Int
        enum CodingKeys: String, CodingKey {
            case id, sprite
            case minXp = "min_xp"
        }
    }

    public struct SpriteGrid: Codable, Equatable {
        public let width: Int
        public let height: Int
        public let cols: Int
        public let rows: Int
    }

    public var maxFrameIndex: Int { spriteGrid.cols * spriteGrid.rows - 1 }
}

/// YAML wire format (no bundleURL, decoded directly from species.yaml).
private struct SpeciesYAML: Decodable {
    let id: String
    let nameZh: String
    let nameEn: String
    let stages: [Species.Stage]
    let animations: [String: [Int]]
    let spriteGrid: Species.SpriteGrid

    enum CodingKeys: String, CodingKey {
        case id
        case nameZh = "name_zh"
        case nameEn = "name_en"
        case stages, animations
        case spriteGrid = "sprite_grid"
    }
}

public struct SpeciesRegistry {
    public let all: [Species]

    public init(all: [Species]) {
        self.all = all
    }

    public static func load(directory: URL) throws -> SpeciesRegistry {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return SpeciesRegistry(all: [])
        }
        var loaded: [Species] = []
        for entry in entries {
            let yamlURL = entry.appendingPathComponent("species.yaml")
            guard fm.fileExists(atPath: yamlURL.path) else { continue }
            let raw = try String(contentsOf: yamlURL)
            let yaml = try YAMLDecoder().decode(SpeciesYAML.self, from: raw)
            let species = Species(
                id: yaml.id, nameZh: yaml.nameZh, nameEn: yaml.nameEn,
                stages: yaml.stages, animations: yaml.animations,
                spriteGrid: yaml.spriteGrid, bundleURL: entry
            )
            try validate(species)
            loaded.append(species)
        }
        return SpeciesRegistry(all: loaded.sorted { $0.id < $1.id })
    }

    private static func validate(_ species: Species) throws {
        for (anim, indices) in species.animations {
            for i in indices where i < 0 || i > species.maxFrameIndex {
                throw SpeciesError.frameOutOfRange(
                    species: species.id, animation: anim,
                    index: i, max: species.maxFrameIndex
                )
            }
        }
    }
}

public enum SpeciesError: Error, Equatable {
    case frameOutOfRange(species: String, animation: String, index: Int, max: Int)
}
