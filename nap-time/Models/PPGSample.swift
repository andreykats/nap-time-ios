import Foundation

/// Raw PPG sample from the Colmi R02 ring.
/// Parsed from 0xA1 notifications with subtype 0x02.
/// All values are 16-bit unsigned little-endian.
struct PPGSample: Sendable {
    let timestamp: Date
    let rawValue: UInt16   // bytes 2-3: instantaneous PPG value
    let max: UInt16        // bytes 4-5: local max
    let min: UInt16        // bytes 6-7: local min
    let diff: UInt16       // bytes 8-9: differential
}
