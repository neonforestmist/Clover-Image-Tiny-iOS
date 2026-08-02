import Foundation

struct GenerationSettings: Codable, Equatable, Sendable {
    enum OutputRatio: String, Codable, CaseIterable, Identifiable, Sendable {
        case square
        case portrait
        case landscape
        case story
        case cinematic

        var id: Self { self }

        var title: String {
            switch self {
            case .square: "Square"
            case .portrait: "Portrait"
            case .landscape: "Landscape"
            case .story: "Story"
            case .cinematic: "Cinematic"
            }
        }

        var dimensions: String {
            switch self {
            case .square: "1:1"
            case .portrait: "4:5"
            case .landscape: "5:4"
            case .story: "9:16"
            case .cinematic: "16:9"
            }
        }

        var widthOverHeight: CGFloat {
            switch self {
            case .square: 1
            case .portrait: 4.0 / 5.0
            case .landscape: 5.0 / 4.0
            case .story: 9.0 / 16.0
            case .cinematic: 16.0 / 9.0
            }
        }

        func croppedSize(from size: CGSize) -> CGSize {
            let sourceRatio = size.width / size.height
            let targetRatio = widthOverHeight
            if targetRatio < sourceRatio {
                return CGSize(
                    width: (size.height * targetRatio).rounded(),
                    height: size.height
                )
            }
            return CGSize(
                width: size.width,
                height: (size.width / targetRatio).rounded()
            )
        }
    }

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
    var outputRatio = OutputRatio.square

    static let defaultsKey = "generation-settings"

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
        case outputRatio
    }

    init() {}

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
        modelID = try container.decodeIfPresent(
            String.self,
            forKey: .modelID
        ) ?? defaults.modelID
        outputRatio = try container.decodeIfPresent(
            OutputRatio.self,
            forKey: .outputRatio
        ) ?? defaults.outputRatio
    }

    static func restored() -> Self {
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return Self()
        }
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let settings = try? JSONDecoder().decode(Self.self, from: data)
        else {
            return Self()
        }
        return settings
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
    let outputRatio: GenerationSettings.OutputRatio?

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
        outputRatio = settings.outputRatio
    }
}
