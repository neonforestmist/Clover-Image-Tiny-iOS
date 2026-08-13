// For licensing see accompanying LICENSE.md file.

import CoreML
import Foundation

/// A Diffusers safetensors LoRA that can populate an adapter-aware Core ML
/// model's mutable state buffers.
@available(iOS 18.0, macOS 15.0, *)
public struct LoRAAdapter: @unchecked Sendable {
    private struct Schema: Decodable {
        let schemaVersion: Int
        let maxAdapterCount: Int?
        let states: [StateMapping]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case maxAdapterCount = "max_adapter_count"
            case states
        }
    }

    private struct StateMapping: Decodable {
        let sourceKey: String
        let stateName: String
        let shape: [Int]
        let stateShape: [Int]?
        let elementCount: Int

        enum CodingKeys: String, CodingKey {
            case sourceKey = "source_key"
            case stateName = "state_name"
            case shape
            case stateShape = "state_shape"
            case elementCount = "element_count"
        }

        var resolvedStateShape: [Int] {
            stateShape ?? shape
        }
    }

    private struct TensorDescriptor: Sendable {
        let dtype: String
        let shape: [Int]
        let start: Int
        let end: Int

        var elementCount: Int {
            shape.reduce(1, *)
        }
    }

    private struct Component: Sendable {
        let weights: Data
        let tensors: [String: TensorDescriptor]
        let scale: Float
    }

    public struct WeightedWeights: Sendable {
        public let url: URL
        public let scale: Float

        public init(url: URL, scale: Float = 1) {
            self.url = url
            self.scale = scale
        }
    }

    public enum AdapterError: LocalizedError {
        case malformedWeights
        case unsupportedSchema(Int)
        case missingTensor(String)
        case unsupportedTensorType(String)
        case incompatibleTensor(String)
        case incompatibleState(String)
        case tooManyAdapters(maximum: Int)

        public var errorDescription: String? {
            switch self {
            case .malformedWeights:
                "The LoRA safetensors file is malformed."
            case let .unsupportedSchema(version):
                "LoRA adapter schema \(version) is not supported."
            case let .missingTensor(name):
                "The LoRA is missing tensor \(name)."
            case let .unsupportedTensorType(dtype):
                "LoRA tensor type \(dtype) is not supported."
            case let .incompatibleTensor(name):
                "LoRA tensor \(name) has an incompatible shape or size."
            case let .incompatibleState(name):
                "Core ML adapter state \(name) is incompatible."
            case let .tooManyAdapters(maximum):
                "This Clover model supports up to \(maximum) simultaneous styles."
            }
        }
    }

    private let components: [Component]
    private let mappings: [StateMapping]

    public let fileSize: Int
    public let maxAdapterCount: Int
    public var tensorCount: Int {
        components.reduce(0) { $0 + $1.tensors.count }
    }

    public init(weightsAt weightsURL: URL, schemaAt schemaURL: URL) throws {
        try self.init(
            weightedWeights: [WeightedWeights(url: weightsURL)],
            schemaAt: schemaURL
        )
    }

    public init(
        weightedWeights: [WeightedWeights],
        schemaAt schemaURL: URL
    ) throws {
        guard !weightedWeights.isEmpty else {
            throw AdapterError.malformedWeights
        }
        let schema = try JSONDecoder().decode(
            Schema.self,
            from: Data(contentsOf: schemaURL)
        )
        guard schema.schemaVersion == 1 || schema.schemaVersion == 2 else {
            throw AdapterError.unsupportedSchema(schema.schemaVersion)
        }
        let maxAdapterCount = schema.schemaVersion == 1
            ? 1
            : max(schema.maxAdapterCount ?? 0, 0)
        guard maxAdapterCount > 0 else {
            throw AdapterError.unsupportedSchema(schema.schemaVersion)
        }
        guard weightedWeights.count <= maxAdapterCount else {
            throw AdapterError.tooManyAdapters(maximum: maxAdapterCount)
        }
        let components = try weightedWeights.map { selection in
            let weights = try Data(
                contentsOf: selection.url,
                options: .mappedIfSafe
            )
            return Component(
                weights: weights,
                tensors: try Self.parseHeader(weights),
                scale: selection.scale
            )
        }

        for mapping in schema.states {
            guard mapping.shape.reduce(1, *) == mapping.elementCount,
                  Self.isCompatible(
                      sourceShape: mapping.shape,
                      stateShape: mapping.resolvedStateShape,
                      sourceKey: mapping.sourceKey,
                      maxAdapterCount: maxAdapterCount
                  ) else {
                throw AdapterError.incompatibleTensor(mapping.sourceKey)
            }
            for component in components {
                guard let tensor = component.tensors[mapping.sourceKey] else {
                    throw AdapterError.missingTensor(mapping.sourceKey)
                }
                guard tensor.elementCount == mapping.elementCount,
                      Self.shapesAreEquivalent(
                          tensor.shape,
                          mapping.shape
                      ) else {
                    throw AdapterError.incompatibleTensor(mapping.sourceKey)
                }
            }
        }

        self.components = components
        self.mappings = schema.states
        self.maxAdapterCount = maxAdapterCount
        fileSize = components.reduce(0) { $0 + $1.weights.count }
    }

    public func populate(_ state: MLState) throws {
        for mapping in mappings {
            try state.withMultiArray(for: mapping.stateName) { destination in
                guard destination.dataType == .float16,
                      destination.count == mapping.resolvedStateShape.reduce(1, *) else {
                    throw AdapterError.incompatibleState(mapping.stateName)
                }
                try destination.withUnsafeMutableBufferPointer(
                    ofType: Float16.self
                ) { output, _ in
                    output.initialize(repeating: 0)
                    for (slot, component) in components.enumerated() {
                        guard let tensor = component.tensors[mapping.sourceKey] else {
                            throw AdapterError.missingTensor(mapping.sourceKey)
                        }
                        try component.weights.withUnsafeBytes { bytes in
                            for sourceIndex in 0..<mapping.elementCount {
                                let value = try Self.readValue(
                                    bytes: bytes,
                                    tensor: tensor,
                                    index: sourceIndex
                                )
                                let destinationIndex = try Self.destinationIndex(
                                    sourceIndex: sourceIndex,
                                    sourceShape: mapping.shape,
                                    stateShape: mapping.resolvedStateShape,
                                    sourceKey: mapping.sourceKey,
                                    slot: slot
                                )
                                let scale = mapping.sourceKey.contains(".lora.up.")
                                    ? component.scale
                                    : 1
                                output[destinationIndex] = Float16(value * scale)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func isCompatible(
        sourceShape: [Int],
        stateShape: [Int],
        sourceKey: String,
        maxAdapterCount: Int
    ) -> Bool {
        guard sourceShape.count == 4, stateShape.count == 4 else {
            return sourceShape == stateShape && maxAdapterCount == 1
        }
        if sourceKey.contains(".lora.down.") {
            return stateShape[0] == sourceShape[0] * maxAdapterCount
                && stateShape.dropFirst() == sourceShape.dropFirst()
        }
        if sourceKey.contains(".lora.up.") {
            return stateShape[1] == sourceShape[1] * maxAdapterCount
                && stateShape[0] == sourceShape[0]
                && stateShape.dropFirst(2) == sourceShape.dropFirst(2)
        }
        return sourceShape == stateShape && maxAdapterCount == 1
    }

    /// Safetensors stores LoRA linear matrices as 2-D tensors, while Core ML
    /// exposes the same values as 1x1 convolution state with two trailing
    /// singleton dimensions.
    private static func shapesAreEquivalent(
        _ lhs: [Int],
        _ rhs: [Int]
    ) -> Bool {
        func removingTrailingSingletons(_ shape: [Int]) -> [Int] {
            var result = shape
            while result.last == 1 {
                result.removeLast()
            }
            return result
        }
        return removingTrailingSingletons(lhs)
            == removingTrailingSingletons(rhs)
    }

    private static func destinationIndex(
        sourceIndex: Int,
        sourceShape: [Int],
        stateShape: [Int],
        sourceKey: String,
        slot: Int
    ) throws -> Int {
        guard sourceShape.count == 4, stateShape.count == 4 else {
            guard slot == 0 else {
                throw AdapterError.incompatibleTensor(sourceKey)
            }
            return sourceIndex
        }
        if sourceKey.contains(".lora.down.") {
            return slot * sourceShape.reduce(1, *) + sourceIndex
        }
        if sourceKey.contains(".lora.up.") {
            let sourceRank = sourceShape[1]
            let stateRank = stateShape[1]
            let row = sourceIndex / sourceRank
            let column = sourceIndex % sourceRank
            return row * stateRank + slot * sourceRank + column
        }
        guard slot == 0 else {
            throw AdapterError.incompatibleTensor(sourceKey)
        }
        return sourceIndex
    }

    private static func readValue(
        bytes: UnsafeRawBufferPointer,
        tensor: TensorDescriptor,
        index: Int
    ) throws -> Float {
        switch tensor.dtype {
        case "F32":
            let bits = bytes.loadUnaligned(
                fromByteOffset: tensor.start + index * 4,
                as: UInt32.self
            ).littleEndian
            return Float(bitPattern: bits)
        case "F16":
            let bits = bytes.loadUnaligned(
                fromByteOffset: tensor.start + index * 2,
                as: UInt16.self
            ).littleEndian
            return Float(Float16(bitPattern: bits))
        default:
            throw AdapterError.unsupportedTensorType(tensor.dtype)
        }
    }

    private static func parseHeader(
        _ data: Data
    ) throws -> [String: TensorDescriptor] {
        guard data.count >= MemoryLayout<UInt64>.size else {
            throw AdapterError.malformedWeights
        }
        let headerLength = data.withUnsafeBytes {
            Int(
                $0.loadUnaligned(as: UInt64.self).littleEndian
            )
        }
        let dataStart = MemoryLayout<UInt64>.size + headerLength
        guard headerLength > 0, dataStart <= data.count else {
            throw AdapterError.malformedWeights
        }

        let headerData = data.subdata(
            in: MemoryLayout<UInt64>.size..<dataStart
        )
        guard let root = try JSONSerialization.jsonObject(
            with: headerData
        ) as? [String: Any] else {
            throw AdapterError.malformedWeights
        }

        var result: [String: TensorDescriptor] = [:]
        for (name, value) in root where name != "__metadata__" {
            guard let entry = value as? [String: Any],
                  let dtype = entry["dtype"] as? String,
                  let shape = entry["shape"] as? [Int],
                  let offsets = entry["data_offsets"] as? [Int],
                  offsets.count == 2 else {
                throw AdapterError.malformedWeights
            }
            let start = dataStart + offsets[0]
            let end = dataStart + offsets[1]
            guard start >= dataStart, end >= start, end <= data.count else {
                throw AdapterError.malformedWeights
            }
            let bytesPerElement: Int
            switch dtype {
            case "F32": bytesPerElement = 4
            case "F16": bytesPerElement = 2
            default: throw AdapterError.unsupportedTensorType(dtype)
            }
            let descriptor = TensorDescriptor(
                dtype: dtype,
                shape: shape,
                start: start,
                end: end
            )
            guard descriptor.elementCount * bytesPerElement == end - start else {
                throw AdapterError.incompatibleTensor(name)
            }
            result[name] = descriptor
        }
        return result
    }
}
