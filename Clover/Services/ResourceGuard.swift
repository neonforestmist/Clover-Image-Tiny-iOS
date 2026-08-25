import Foundation

struct ResourceGuard: Sendable {
    enum Verdict: Sendable, Equatable {
        case ok
        case tightOnSpace(freeBytes: Int64)
        case insufficientSpace(needBytes: Int64, freeBytes: Int64)
        case thermallyThrottled(ProcessInfo.ThermalState)
        case lowPowerMode

        var advisoryText: String? {
            switch self {
            case .ok:
                nil
            case let .tightOnSpace(freeBytes):
                "Storage is getting tight (\(ResourceGuard.format(freeBytes)) free). Generation may fail if the device runs out of space."
            case let .insufficientSpace(needBytes, freeBytes):
                "Need \(ResourceGuard.format(needBytes)) free. This device has \(ResourceGuard.format(freeBytes))."
            case let .thermallyThrottled(state):
                "This \(ResourceGuard.thermalLabel(state)) may run slower until the device cools down."
            case .lowPowerMode:
                "Low Power Mode is on — generation may run slower."
            }
        }

        var blocksDownload: Bool {
            if case .insufficientSpace = self { return true }
            return false
        }
    }

    func availableBytes() -> Int64 {
        let url = ModelStorage.rootURL
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func check(requiredBytes: Int64) -> Verdict {
        let free = availableBytes()
        let paddedNeed = requiredBytes + 64_000_000
        if free > 0, free < paddedNeed {
            return .insufficientSpace(needBytes: paddedNeed, freeBytes: free)
        }
        if free > 0, free < paddedNeed + 500_000_000 {
            return .tightOnSpace(freeBytes: free)
        }
        return .ok
    }

    func generationAdvisory() -> Verdict? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled {
            return .lowPowerMode
        }
        if info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return .thermallyThrottled(info.thermalState)
        }
        return nil
    }

    fileprivate static func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .memory))
    }

    fileprivate static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .fair: "device is warm"
        case .serious: "device is hot"
        case .critical: "device is very hot"
        default: "device"
        }
    }
}
