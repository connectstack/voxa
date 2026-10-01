import CoreAudio
import Foundation

/// The microphone macOS is using for Voxa right now (the system's default input device), as far as it can be told without opening it.
public struct InputDeviceInfo: Sendable, Equatable {
    public enum Transport: Sendable, Equatable {
        case builtIn
        case bluetooth
        case usb
        /// A loopback or software device (BlackHole, a meeting app's audio driver): what it carries is whatever is routed to it.
        case virtual
        /// The phone or tablet next to the Mac, used as a microphone (Continuity).
        case continuity
        case other
    }

    public var name: String
    public var sampleRate: Double
    /// The device's own input volume, 0...1, or nil when it has none (a phone's microphone, say).
    public var volume: Float?
    public var transport: Transport

    public init(name: String, sampleRate: Double, volume: Float?, transport: Transport) {
        self.name = name
        self.sampleRate = sampleRate
        self.volume = volume
        self.transport = transport
    }
}

/// Reads the default input device. Nothing here opens the microphone, so it needs no permission and shows no orange dot.
public enum InputDevice {
    public static func current() -> InputDeviceInfo? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let device = value(system, kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self)
        guard let device, device != AudioObjectID(kAudioObjectUnknown) else { return nil }

        return InputDeviceInfo(
            name: name(of: device) ?? "",
            sampleRate: value(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0,
            volume: inputVolume(of: device),
            transport: transport(of: device)
        )
    }

    // MARK: Reading

    private static func inputVolume(of device: AudioObjectID) -> Float? {
        // Most devices have one volume for the whole device; some only one per channel.
        for element in [kAudioObjectPropertyElementMain, 1] {
            if let volume = value(
                device, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element, as: Float32.self
            ) {
                return min(max(volume, 0), 1)
            }
        }
        return nil
    }

    private static func transport(of device: AudioObjectID) -> InputDeviceInfo.Transport {
        guard let code = value(device, kAudioDevicePropertyTransportType, as: UInt32.self) else { return .other }
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return .virtual
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return .continuity
        default: return .other
        }
    }

    private static func name(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        as type: T.Type
    ) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }
}
