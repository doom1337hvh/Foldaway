import Foundation
import IOKit.hid

/// The MacBook's lid angle sensor: an Apple HID sensor (usage page 0x20, usage 0x8A, named
/// "las") that reports the angle between the screen and the keyboard. It needs no permission.
/// Desktop Macs, and MacBooks without one, have nothing to read.
@MainActor
final class LidSensor {
    /// Each angle the sensor sends by itself: about once a second while the lid is still.
    var onReport: ((Double) -> Void)?

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var isListening = false

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first
        else { return nil }
        self.device = device
        guard read() != nil else { return nil }
    }

    /// The lid's angle now, in degrees: about 0 shut, about 120 open as usual. Takes under a
    /// millisecond. The sensor itself only updates about ten times a second.
    func read() -> Double? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        // Report 7 has hundredths of a degree; report 1, whole degrees.
        if IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 7, &report, &length) == kIOReturnSuccess,
           length >= 3 {
            return Double(Int(report[1]) | Int(report[2]) << 8) / 100
        }
        length = CFIndex(report.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess,
              length >= 3
        else { return nil }
        return Self.angle(report)
    }

    func startListening() {
        guard !isListening else { return }
        isListening = true
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, { context, _, _, _, _, report, length in
            guard let context, length >= 3 else { return }
            let sensor = Unmanaged<LidSensor>.fromOpaque(context).takeUnretainedValue()
            let angle = LidSensor.angle(UnsafeBufferPointer(start: report, count: length))
            MainActor.assumeIsolated { sensor.onReport?(angle) }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    /// Report 1: the report's ID, then the angle as a little-endian 16-bit number.
    private nonisolated static func angle<Bytes: Collection<UInt8>>(_ report: Bytes) -> Double where Bytes.Index == Int {
        let start = report.startIndex
        return Double(Int(report[start + 1]) | Int(report[start + 2]) << 8)
    }
}
