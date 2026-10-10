import Foundation
import CoreFoundation

public struct ScrollSettings: Equatable {
    public var enabled = false
    public var reverseVertical = true
    public var reverseHorizontal = false
    public var speedMultiplier = 1.0
    public init() {}
}

public struct SettingsPatch {
    public let values: [String: Any]
    public init(data: Data) throws {
        guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError.invalid("Expected a JSON object smaller than 64 KB.")
        }
        let booleans: Set<String> = ["enabled", "reverseVertical", "reverseHorizontal", "launchAtLogin"]
        guard Set(object.keys).isSubset(of: booleans.union(["speedMultiplier"])) else { throw SettingsError.invalid("Unknown or read-only setting.") }
        for (key, value) in object {
            guard let number = value as? NSNumber else { throw SettingsError.invalid("Invalid value for \(key).") }
            if booleans.contains(key) {
                guard CFGetTypeID(number) == CFBooleanGetTypeID() else { throw SettingsError.invalid("\(key) must be a Boolean.") }
            } else {
                guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, (0.25...4).contains(number.doubleValue) else {
                    throw SettingsError.invalid("speedMultiplier must be between 0.25 and 4.")
                }
            }
        }
        values = object
    }
}

public enum SettingsError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

/// A continuous event is not a reliable hardware identity: leave it untouched.
public enum WheelClassifier {
    public static func shouldTransform(isContinuous: Bool, enabled: Bool, isOwnEvent: Bool) -> Bool {
        enabled && !isContinuous && !isOwnEvent
    }
}

/// Carry fractional wheel ticks across events rather than rounding each tick away.
public struct WheelAccumulator {
    private var remainder: Double = 0
    private var lastDirection: Double = 0
    public init() {}
    public mutating func reset() { remainder = 0; lastDirection = 0 }
    public mutating func scale(_ input: Int64, factor: Double) -> Int64 {
        guard input != 0 else { return 0 }
        let direction = input > 0 ? 1.0 : -1.0
        if lastDirection != direction { remainder = 0 }
        lastDirection = direction
        let total = Double(input) * factor + remainder
        // CGEvent wheel deltas are 32-bit signed fields. Clamp corrupt/extreme input.
        let bounded = min(Double(Int32.max), max(Double(Int32.min), total))
        let output = Int64(bounded.rounded(.towardZero))
        remainder = bounded - Double(output)
        return output
    }
}
