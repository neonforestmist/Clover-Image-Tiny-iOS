// For licensing see accompanying LICENSE.md file.
// Copyright (C) 2022 Apple Inc. All Rights Reserved.

import CoreML

/// A class to manage and gate access to a Core ML model
///
/// It will automatically load a model into memory when needed or requested
/// It allows one to request to unload the model from memory
@available(iOS 16.2, macOS 13.1, *)
public final class ManagedMLModel: ResourceManaging {

    /// The location of the model
    var modelURL: URL

    /// The configuration to be used when the model is loaded
    var configuration: MLModelConfiguration

    /// The loaded model (when loaded)
    var loadedModel: MLModel?

    /// Creates state for models that use iOS 18 mutable Core ML buffers. The
    /// result is type-erased so this package can keep its iOS 16 deployment
    /// target for non-stateful clients.
    var makeLoadedState: ((MLModel) throws -> AnyObject?)?

    /// State belongs to the currently loaded model and is rebuilt after unload.
    var loadedState: AnyObject?

    /// Optional compute backend used when Core ML cannot build an execution
    /// plan with the preferred configuration.
    var fallbackComputeUnits: MLComputeUnits?

    /// Queue to protect access to loaded model
    var queue: DispatchQueue

    /// Create a managed model given its location and desired loaded configuration
    ///
    /// - Parameters:
    ///     - url: The location of the model
    ///     - configuration: The configuration to be used when the model is loaded/used
    /// - Returns: A managed model that has not been loaded
    public init(
        modelAt url: URL,
        configuration: MLModelConfiguration
    ) {
        self.modelURL = url
        self.configuration = configuration
        self.makeLoadedState = nil
        self.loadedModel = nil
        self.loadedState = nil
        self.fallbackComputeUnits = nil
        self.queue = DispatchQueue(label: "managed.\(url.lastPathComponent)")
    }

    /// Create a managed stateful model and optionally populate its LoRA state.
    @available(iOS 18.0, macOS 15.0, *)
    public convenience init(
        modelAt url: URL,
        configuration: MLModelConfiguration,
        loraAdapter: LoRAAdapter?,
        fallbackComputeUnits: MLComputeUnits? = nil
    ) {
        self.init(modelAt: url, configuration: configuration)
        self.fallbackComputeUnits = fallbackComputeUnits
        makeLoadedState = { model in
            guard !model.modelDescription
                .stateDescriptionsByName.isEmpty else {
                return nil
            }
            let state = model.makeState()
            try loraAdapter?.populate(state)
            return state
        }
    }

    /// Instantiation and load model into memory
    public func loadResources() throws {
        try queue.sync {
            try loadModel()
        }
    }

    /// Unload the model if it was loaded
    public func unloadResources() {
        queue.sync {
            loadedState = nil
            loadedModel = nil
        }
    }

    /// Perform an operation with the managed model via a supplied closure.
    ///  The model will be loaded and supplied to the closure and should only be
    ///  used within the closure to ensure all resource management is synchronized
    ///
    /// - Parameters:
    ///     - body: Closure which performs and action on a loaded model
    /// - Returns: The result of the closure
    /// - Throws: An error if the model cannot be loaded or if the closure throws
    public func perform<R>(_ body: (MLModel) throws -> R) throws -> R {
        return try queue.sync {
            try autoreleasepool {
                try loadModel()
                return try body(loadedModel!)
            }
        }
    }

    /// Predict a batch, using the model's persistent LoRA state when present.
    func predictions(from batch: MLBatchProvider) throws -> MLBatchProvider {
        try queue.sync {
            try autoreleasepool {
                try loadModel()
                guard let model = loadedModel else {
                    throw CocoaError(.fileReadUnknown)
                }
                if #available(
                    iOS 18.0,
                    macOS 15.0,
                    tvOS 18.0,
                    watchOS 11.0,
                    *
                ), let state = loadedState as? MLState {
                    let outputs = try (0..<batch.count).map { index in
                        try model.prediction(
                            from: batch.features(at: index),
                            using: state
                        )
                    }
                    return MLArrayBatchProvider(array: outputs)
                }
                return try model.predictions(fromBatch: batch)
            }
        }
    }

    private func loadModel() throws {
        if loadedModel == nil {
            do {
                loadedModel = try loadModel(configuration: configuration)
            } catch {
                guard let fallbackComputeUnits,
                      fallbackComputeUnits != configuration.computeUnits,
                      let fallbackConfiguration = configuration.copy()
                        as? MLModelConfiguration else {
                    throw error
                }
                fallbackConfiguration.computeUnits = fallbackComputeUnits
                loadedModel = try loadModel(
                    configuration: fallbackConfiguration
                )
                configuration = fallbackConfiguration
            }

            if #available(
                iOS 18.0,
                macOS 15.0,
                tvOS 18.0,
                watchOS 11.0,
                *
            ), let model = loadedModel,
               let makeLoadedState {
                loadedState = try makeLoadedState(model)
            }
        }
    }

    private func loadModel(
        configuration: MLModelConfiguration
    ) throws -> MLModel {
        if #available(
            iOS 18.0,
            macOS 15.0,
            tvOS 18.0,
            watchOS 11.0,
            *
        ), configuration.functionName != nil {
            // A multi-function ML Program must be loaded from MLModelAsset.
            // The older synchronous URL initializer rejects functionName.
            let asset = try MLModelAsset(url: modelURL)
            let group = DispatchGroup()
            let lock = NSLock()
            var result: Result<MLModel, Error>?

            group.enter()
            MLModel.load(
                asset,
                configuration: configuration
            ) { model, error in
                lock.withLock {
                    if let model {
                        result = .success(model)
                    } else {
                        result = .failure(
                            error ?? CocoaError(.fileReadUnknown)
                        )
                    }
                }
                group.leave()
            }
            group.wait()
            return try lock.withLock {
                try result!.get()
            }
        } else {
            return try MLModel(
                contentsOf: modelURL,
                configuration: configuration
            )
        }
    }
}

@available(iOS 16.2, macOS 13.1, *)
public extension Array where Element == ManagedMLModel {
    /// Performs batch predictions using an array of `[ManagedMLModel]` instances in a pipeline.
    /// - Parameter batch: Inputs for btached predictions.
    /// - Returns: Final prediction results after processing through all models.
    /// - Throws: Errors if the array is empty, predictions fail, or results can't be combined.
    func predictions(from batch: MLBatchProvider) throws -> MLBatchProvider {
        var results = try self.first!.predictions(from: batch)

        if self.count == 1 {
            return results
        }

        // Manual pipeline batch prediction
        let inputs = batch.arrayOfFeatureValueDictionaries
        for stage in self.dropFirst() {
            // Combine the original inputs with the outputs of the last stage
            let next = try results.arrayOfFeatureValueDictionaries
                .enumerated().map { index, dict in
                    let nextDict = dict.merging(inputs[index]) { out, _ in out }
                    return try MLDictionaryFeatureProvider(dictionary: nextDict)
                }
            let nextBatch = MLArrayBatchProvider(array: next)

            // Predict
            results = try stage.predictions(from: nextBatch)
        }

        return results
    }
}

extension MLFeatureProvider {
    var featureValueDictionary: [String : MLFeatureValue] {
        self.featureNames.reduce(into: [String : MLFeatureValue]()) { result, name in
            result[name] = self.featureValue(for: name)
        }
    }
}

extension MLBatchProvider {
    var arrayOfFeatureValueDictionaries: [[String : MLFeatureValue]] {
        (0..<self.count).map {
            self.features(at: $0).featureValueDictionary
        }
    }
}
