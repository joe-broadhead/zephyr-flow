import CoreFoundation
import Foundation

/// Only the Fn key is encoded, never the surrounding preference domain.
/// Foundation property-list parsing is local. Bounds apply to retained bytes;
/// they do not impose a native allocation/IPC deadline on CFPreferences.
public enum FnPreferenceSnapshotCodec {
    public static let maximumBytes = 65_536
    public enum Failure: Error { case unsupportedValue, invalidSnapshot, missingLegacyValue }

    public static func capture(_ value: Any?) throws -> FnPreferenceSnapshot {
        guard let value else { return .none }
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else { throw Failure.unsupportedValue }
        let bytes = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        guard bytes.count <= maximumBytes else { throw Failure.unsupportedValue }
        let tag = typeTag(value)
        let snapshot = FnPreferenceSnapshot(keyPresent: true, value: nil, cfTypeTag: tag, encodedValue: bytes)
        guard try matches(value, snapshot: snapshot) else { throw Failure.unsupportedValue }
        return snapshot
    }

    public static func materialize(_ snapshot: FnPreferenceSnapshot) throws -> Any? {
        // A stored journal is not authority to mutate arbitrary preferences.
        guard snapshot.suiteName == "com.apple.HIToolbox", snapshot.keyName == "AppleFnUsageType" else {
            throw Failure.invalidSnapshot
        }
        guard snapshot.keyPresent else {
            guard snapshot.encodedValue == nil, snapshot.value == nil, snapshot.cfTypeTag == nil else {
                throw Failure.invalidSnapshot
            }
            return nil
        }
        guard let bytes = snapshot.encodedValue else { throw Failure.missingLegacyValue }
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw Failure.invalidSnapshot }
        let value = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        guard typeTag(value) == snapshot.cfTypeTag else { throw Failure.invalidSnapshot }
        return value
    }

    public static func matches(_ current: Any?, snapshot: FnPreferenceSnapshot) throws -> Bool {
        let expected = try materialize(snapshot)
        switch (current, expected) {
        case (nil, nil): return true
        case (let current?, let expected?): return equal(current, expected)
        default: return false
        }
    }

    private static func typeTag(_ value: Any) -> String {
        let id = CFGetTypeID(value as CFTypeRef)
        switch id {
        case CFBooleanGetTypeID(): return "CFBoolean"
        case CFNumberGetTypeID(): return "CFNumber"
        case CFStringGetTypeID(): return "CFString"
        case CFDataGetTypeID(): return "CFData"
        case CFDateGetTypeID(): return "CFDate"
        case CFArrayGetTypeID(): return "CFArray"
        case CFDictionaryGetTypeID(): return "CFDictionary"
        default: return "unsupported"
        }
    }

    /// CFEqual alone equates Boolean/Number values (including inside arrays).
    /// Compare types recursively, including integral vs floating numbers.
    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        guard typeTag(lhs) == typeTag(rhs) else { return false }
        if let a = lhs as? [String: Any], let b = rhs as? [String: Any] {
            return a.keys.count == b.keys.count
                && a.allSatisfy { key, value in
                    guard let other = b[key] else { return false }
                    return equal(value, other)
                }
        }
        if let a = lhs as? [Any], let b = rhs as? [Any] {
            return a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
        }
        if typeTag(lhs) == "CFNumber", let a = lhs as? NSNumber, let b = rhs as? NSNumber {
            let aFloat = ["f", "d"].contains(String(cString: a.objCType))
            let bFloat = ["f", "d"].contains(String(cString: b.objCType))
            guard aFloat == bFloat else { return false }
            return aFloat ? a.doubleValue.bitPattern == b.doubleValue.bitPattern : a.stringValue == b.stringValue
        }
        return CFEqual(lhs as CFTypeRef, rhs as CFTypeRef)
    }
}
