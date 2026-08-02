// For licensing see accompanying LICENSE.md file.

import CoreML
import Foundation

/// A Diffusers safetensors LoRA that can populate an adapter-aware Core ML
/// model's mutable state buffers.
@available(iOS 18.0, macOS 15.0, *)
public struct LoRAAdapter: @unchecked Sendable {
    private struct Schema: Decodable {
        let schemaVersion: Int
        let states: [StateMapping]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case states
        }
    }

    private struct StateMapping: Decodable {
        let sourceKey: String
        let stateName: String
        let shape: [Int]
        let elementCount: Int

        enum CodingKeys: String, CodingKey {
            case sourceKey = "source_key"
            case stateName = "state_name"
            case shape
            case elementCount = "element_count"
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

    public enum AdapterError: LocalizedError {
        case malformedWeights
        case unsupportedSchema(Int)
        case missingTensor(String)
        case unsupportedTensorType(String)
        case incompatibleTensor(String)
        case incompatibleState(String)

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
            }
        }
    }

    private let weights: Data
    private let mappings: [StateMapping]
    private let tensors: [String: TensorDescriptor]

    public let fileSize: Int
    public var tensorCount: Int { tensors.count }

    public init(weightsAt weightsURL: URL, schemaAt schemaURL: URL) throws {
        let weights = try Data(contentsOf: weightsURL, options: .mappedIfSafe)
        let schema = try JSONDecoder().decode(
            Schema.self,
            from: Data(contentsOf: schemaURL)
        )
        guard schema.schemaVersion == 1 else {
            throw AdapterError.unsupportedSchema(schema.schemaVersion)
        }
        let tensors = try Self.parseHeader(weights)

        for mapping in schema.states {
            guard let tensor = tensors[mapping.sourceKey] else {
                throw AdapterError.missingTensor(mapping.sourceKey)
            }
            guard tensor.elementCount == mapping.elementCount,
                  mapping.shape.reduce(1, *) == mapping.elementCount else {
                throw AdapterError.incompatibleTensor(mapping.sourceKey)
            }
        }

        self.weights = weights
        self.mappings = schema.states
        self.tensors = tensors
        fileSize = weights.count
    }

    public func populate(_ state: MLState) throws {
        for mapping in mappings {
            guard let tensor = tensors[mapping.sourceKey] else {
                throw AdapterError.missingTensor(mapping.sourceKey)
            }
            try state.withMultiArray(for: mapping.stateName) { destination in
                guard destination.dataType == .float16,
                      destination.count == mapping.elementCount else {
                    throw AdapterError.incompatibleState(mapping.stateName)
                }
                try destination.withUnsafeMutableBufferPointer(
                    ofType: Float16.self
                ) { output, _ in
                    try weights.withUnsafeBytes { bytes in
                        switch tensor.dtype {
                        case "F32":
                            for index in 0..<mapping.elementCount {
                                let bits = bytes.loadUnaligned(
                                    fromByteOffset: tensor.start + index * 4,
                                    as: UInt32.self
                                ).littleEndian
                                output[index] = Float16(
                                    Float(bitPattern: bits)
                                )
                            }
                        case "F16":
                            for index in 0..<mapping.elementCount {
                                let bits = bytes.loadUnaligned(
                                    fromByteOffset: tensor.start + index * 2,
                                    as: UInt16.self
                                ).littleEndian
                                output[index] = Float16(bitPattern: bits)
                            }
                        default:
                            throw AdapterError.unsupportedTensorType(
                                tensor.dtype
                            )
                        }
                    }
                }
            }
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
