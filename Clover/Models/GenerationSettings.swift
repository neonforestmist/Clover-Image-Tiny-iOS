import Foundation

struct GenerationSettings: Codable, Equatable, Sendable {
    enum Scheduler: String, Codable, CaseIterable, Identifiable, Sendable {
        case pndm
        case dpmSolver

        var id: Self { self }

        var title: String {
            switch self {
            case .pndm: "PNDM"
            case .dpmSolver: "DPM-Solver++"
            }
        }

        var detail: String {
            switch self {
            case .pndm: "Validated default"
            case .dpmSolver: "Fast multistep sampler"
            }
        }
    }

    enum RandomGenerator: String, Codable, CaseIterable, Identifiable, Sendable {
        case numpy
        case torch

        var id: Self { self }

        var title: String {
            switch self {
            case .numpy: "NumPy"
            case .torch: "PyTorch"
            }
        }
    }

    enum ComputeTarget: String, Codable, CaseIterable, Identifiable, Sendable {
        case neuralEngine
        case automatic
        case gpu

        var id: Self { self }

        var title: String {
            switch self {
            case .neuralEngine: "Neural Engine"
            case .automatic: "Automatic"
            case .gpu: "GPU"
            }
        }

        var systemImage: String {
            switch self {
            case .neuralEngine: "cpu"
            case .automatic: "wand.and.rays"
            case .gpu: "display"
            }
        }
    }

    var prompt = ""
    var negativePrompt = "blurry, distorted, low detail"
    var stepCount = 30
    var guidanceScale = 7.5
    var seed: UInt32 = 1337
    var imageCount = 1
    var scheduler = Scheduler.pndm
    var randomGenerator = RandomGenerator.numpy
    var computeTarget = ComputeTarget.neuralEngine
    var modelID = "base"
    var styleIDs: [String] = []
    var styleStrengths: [String: Double] = [:]
    var livePreviewEnabled = false
    var previewInterval = 5

    static let defaultsKey = "generation-settings"
    static let maximumStyleCount = 3

    enum CodingKeys: String, CodingKey {
        case prompt
        case negativePrompt
        case stepCount
        case guidanceScale
        case seed
        case imageCount
        case scheduler
        case randomGenerator
        case computeTarget
        case modelID
        case styleIDs
        case styleStrengths
        case livePreviewEnabled
        case previewInterval
    }

    init() {}

    static var inpaintingDefaults: Self {
        var settings = Self()
        settings.stepCount = 20
        settings.guidanceScale = 6.0
        settings.scheduler = .dpmSolver
        settings.livePreviewEnabled = true
        settings.previewInterval = 5
        return settings
    }

    init(from decoder: Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decodeIfPresent(
            String.self,
            forKey: .prompt
        ) ?? defaults.prompt
        negativePrompt = try container.decodeIfPresent(
            String.self,
            forKey: .negativePrompt
        ) ?? defaults.negativePrompt
        stepCount = try container.decodeIfPresent(
            Int.self,
            forKey: .stepCount
        ) ?? defaults.stepCount
        guidanceScale = try container.decodeIfPresent(
            Double.self,
            forKey: .guidanceScale
        ) ?? defaults.guidanceScale
        seed = try container.decodeIfPresent(
            UInt32.self,
            forKey: .seed
        ) ?? defaults.seed
        imageCount = try container.decodeIfPresent(
            Int.self,
            forKey: .imageCount
        ) ?? defaults.imageCount
        scheduler = try container.decodeIfPresent(
            Scheduler.self,
            forKey: .scheduler
        ) ?? defaults.scheduler
        randomGenerator = try container.decodeIfPresent(
            RandomGenerator.self,
            forKey: .randomGenerator
        ) ?? defaults.randomGenerator
        computeTarget = try container.decodeIfPresent(
            ComputeTarget.self,
            forKey: .computeTarget
        ) ?? defaults.computeTarget
        let decodedModelID = try container.decodeIfPresent(
            String.self,
            forKey: .modelID
        ) ?? defaults.modelID
        let decodedStyleIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .styleIDs
        ) ?? (decodedModelID == "base" ? [] : [decodedModelID])
        styleIDs = Array(
            decodedStyleIDs
                .filter { $0 != "base" }
                .uniqued()
                .prefix(Self.maximumStyleCount)
        )
        styleStrengths = try container.decodeIfPresent(
            [String: Double].self,
            forKey: .styleStrengths
        ) ?? [:]
        styleStrengths = styleStrengths.filter { styleIDs.contains($0.key) }
        modelID = "base"
        livePreviewEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .livePreviewEnabled
        ) ?? defaults.livePreviewEnabled
        previewInterval = min(
            10,
            max(
                1,
                try container.decodeIfPresent(
                    Int.self,
                    forKey: .previewInterval
                ) ?? defaults.previewInterval
            )
        )
    }

    static func restored() -> Self {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing-reset") {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return Self()
        }
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let settings = try? JSONDecoder().decode(Self.self, from: data)
        else {
            return Self()
        }
        guard arguments.contains("-ui-testing-real-model") else {
            return settings
        }

        var smokeTestSettings = settings
        smokeTestSettings.stepCount = 4
        smokeTestSettings.imageCount = 1
        smokeTestSettings.computeTarget = .neuralEngine
        return smokeTestSettings
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func applyStyleTrigger(
        _ trigger: String?,
        replacing previousTrigger: String?
    ) {
        applyStyleTriggers(
            trigger.map { [$0] } ?? [],
            replacing: previousTrigger.map { [$0] } ?? []
        )
    }

    mutating func applyStyleTriggers(
        _ triggers: [String],
        replacing previousTriggers: [String]
    ) {
        var content = prompt

        for previousTrigger in previousTriggers where !previousTrigger.isEmpty {
            content = Self.removingTriggerPrefix(
                previousTrigger,
                from: content
            )
        }

        let newTriggers = triggers.filter { !$0.isEmpty }.uniqued()
        guard !newTriggers.isEmpty else {
            prompt = content
            return
        }
        if Self.hasTriggerPrefixes(newTriggers, in: content) {
            prompt = content
            return
        }

        let trimmedContent = content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let prefix = newTriggers.joined(separator: ", ")
        prompt = trimmedContent.isEmpty ? "\(prefix), " : "\(prefix), \(trimmedContent)"
    }

    mutating func setStyleStrength(_ value: Double, for id: String) {
        guard styleIDs.contains(id) else { return }
        styleStrengths[id] = min(max(value, 0), 1.5)
    }

    func styleStrength(for id: String) -> Double {
        min(max(styleStrengths[id] ?? 1, 0), 1.5)
    }

    private static func hasTriggerPrefix(
        _ trigger: String,
        in prompt: String
    ) -> Bool {
        prompt.drop { $0.isWhitespace }.range(
            of: "\(trigger),",
            options: [.anchored, .caseInsensitive]
        ) != nil
    }

    private static func hasTriggerPrefixes(
        _ triggers: [String],
        in prompt: String
    ) -> Bool {
        var remainder = prompt
        for trigger in triggers {
            guard hasTriggerPrefix(trigger, in: remainder) else {
                return false
            }
            remainder = removingTriggerPrefix(trigger, from: remainder)
        }
        return true
    }

    private static func removingTriggerPrefix(
        _ trigger: String,
        from prompt: String
    ) -> String {
        let leadingTrimmed = prompt.drop { $0.isWhitespace }
        guard let range = leadingTrimmed.range(
            of: "\(trigger),",
            options: [.anchored, .caseInsensitive]
        ) else {
            return prompt
        }

        return String(leadingTrimmed[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GenerationSnapshot: Codable, Equatable, Sendable {
    let prompt: String
    let negativePrompt: String
    let stepCount: Int
    let guidanceScale: Double
    let seed: UInt32
    let imageIndex: Int
    let scheduler: GenerationSettings.Scheduler
    let randomGenerator: GenerationSettings.RandomGenerator
    let computeTarget: GenerationSettings.ComputeTarget
    let modelID: String?
    // Optional so artwork saved by releases predating style mixing continues
    // to decode from the on-device library.
    let styleIDs: [String]?
    let styleStrengths: [String: Double]?

    init(settings: GenerationSettings, imageIndex: Int) {
        prompt = settings.trimmedPrompt
        negativePrompt = settings.negativePrompt
        stepCount = settings.stepCount
        guidanceScale = settings.guidanceScale
        seed = settings.seed
        self.imageIndex = imageIndex
        scheduler = settings.scheduler
        randomGenerator = settings.randomGenerator
        computeTarget = settings.computeTarget
        modelID = settings.modelID
        styleIDs = settings.styleIDs
        styleStrengths = settings.styleStrengths
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
