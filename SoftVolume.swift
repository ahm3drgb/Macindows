// Copyright (c) 2026 Ahmed Abokhalil. All rights reserved.

import Cocoa
import SwiftUI
import CoreAudio

/// Volume keys for output devices that have no volume control of their own (many USB audio
/// interfaces). macOS shows a "not allowed" symbol for them. When the default output device has
/// no volume, Macindows taps the audio sent to it, mutes the original, and plays it back with
/// its own gain. The volume keys then change that gain.
final class SoftVolume {
    static let shared = SoftVolume()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// Output device the engine runs for, or kAudioObjectUnknown when it is off
    private(set) var activeDevice = AudioObjectID(kAudioObjectUnknown)
    /// [0] target gain, [1] gain applied on the last buffer. Shared with the real-time audio
    /// thread, so it is a raw pointer, not a Swift property.
    private let gain: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        p.initialize(repeating: 0, count: 2)
        return p
    }()
    private var muted = false
    private var keyTap: CFMachPort?
    private let hud = VolumeHUD()

    func start() {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.refresh()
        }
        setupKeyTap()
        refresh()
    }

    /// Starts, stops or moves the engine to match the setting and the current output device.
    func refresh() {
        let device = Self.defaultOutputDevice()
        let wanted = Settings.bool(Settings.softVolume) && device != kAudioObjectUnknown
            && !Self.hasHardwareVolume(device)
        if wanted, device == activeDevice { return }
        stopEngine()
        if wanted, #available(macOS 14.2, *) { startEngine(on: device) }
        if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: activeDevice != kAudioObjectUnknown) }
    }

    func stop() {
        stopEngine()
        if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    /// One line for the settings window.
    var status: String {
        let device = Self.defaultOutputDevice()
        let name = Self.deviceName(device) ?? "The current output"
        if activeDevice != kAudioObjectUnknown { return "Active on \(name)." }
        if device != kAudioObjectUnknown, Self.hasHardwareVolume(device) {
            return "\(name) has its own volume control, so macOS handles the keys."
        }
        if #unavailable(macOS 14.2) { return "Needs macOS 14.2 or later." }
        return Settings.bool(Settings.softVolume) ? "Could not start on \(name)." : "Off."
    }

    // MARK: - Volume

    private var level: Double {
        get { Settings.double(Settings.softVolumeLevel) }
        set { UserDefaults.standard.set(min(1, max(0, newValue)), forKey: Settings.softVolumeLevel) }
    }

    /// Level 0...1 maps to a 50 dB range, which sounds even across the steps. 0 is silent.
    private func applyGain() {
        gain[0] = muted || level <= 0 ? 0 : Float(pow(10, (level - 1) * 2.5))
    }

    private func step(up: Bool, fine: Bool) {
        let size = fine ? 1.0 / 64 : 1.0 / 16
        muted = false
        // Snap to the grid first, so steps stay on even sixteenths like the system volume
        let steps = (level / size).rounded()
        level = (steps + (up ? 1 : -1)) * size
        applyGain()
        hud.show(level: level, muted: muted)
    }

    private func toggleMute() {
        muted.toggle()
        applyGain()
        hud.show(level: level, muted: muted)
    }

    // MARK: - Engine

    @available(macOS 14.2, *)
    private func startEngine(on device: AudioObjectID) {
        guard let uid = Self.deviceUID(device), let me = Self.ownProcessObject() else { return }

        // Tap only the audio headed to this device. Exclude ourselves, or we would tap our own output.
        let desc = CATapDescription(excludingProcesses: [me], deviceUID: uid, stream: 0)
        desc.uuid = UUID()
        desc.name = "Macindows Volume"
        desc.muteBehavior = .muted
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else {
            DTLog("[SoftVolume] tap create FAILED"); return
        }
        tapID = tap

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Macindows Volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &agg) == noErr else {
            DTLog("[SoftVolume] aggregate create FAILED"); stopEngine(); return
        }
        aggregateID = agg

        // The aggregate's input buffers start with the device's own inputs (the interface's
        // microphones), then the tap. Skip the device inputs.
        let skip = Self.inputBufferCount(device)
        applyGain()
        gain[1] = 0   // fade in from silence
        let gain = self.gain
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, input, _, output, _ in
            Self.render(input: input, skip: skip, output: output, gain: gain)
        }
        guard status == noErr, let procID else {
            DTLog("[SoftVolume] IOProc create FAILED"); stopEngine(); return
        }
        ioProcID = procID
        guard AudioDeviceStart(agg, procID) == noErr else {
            DTLog("[SoftVolume] start FAILED"); stopEngine(); return
        }
        activeDevice = device
        DTLog("[SoftVolume] running on \(Self.deviceName(device) ?? uid)")
    }

    private func stopEngine() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        activeDevice = AudioObjectID(kAudioObjectUnknown)
    }

    /// Real-time audio thread: copy tap channel N to output channel N with gain.
    /// No allocation, no locks. Gain ramps across the buffer so changes do not click.
    private static func render(input: UnsafePointer<AudioBufferList>, skip: Int,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               gain: UnsafeMutablePointer<Float>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let from = gain[1], to = gain[0]
        var channelBase = 0
        for ob in outList {
            guard let od = ob.mData?.assumingMemoryBound(to: Float.self), ob.mNumberChannels > 0 else { continue }
            let on = Int(ob.mNumberChannels)
            let frames = Int(ob.mDataByteSize) / (MemoryLayout<Float>.size * on)
            for c in 0..<on {
                // Find tap channel (channelBase + c) across the tap's buffers
                var src: UnsafeMutablePointer<Float>?
                var stride = 1, srcFrames = 0
                var idx = channelBase + c
                var b = skip
                while b < inList.count {
                    let n = Int(inList[b].mNumberChannels)
                    if n > 0, idx < n {
                        src = inList[b].mData?.assumingMemoryBound(to: Float.self).advanced(by: idx)
                        stride = n
                        srcFrames = Int(inList[b].mDataByteSize) / (MemoryLayout<Float>.size * n)
                        break
                    }
                    idx -= n
                    b += 1
                }
                let count = src == nil ? 0 : min(frames, srcFrames)
                let delta = frames > 0 ? (to - from) / Float(frames) : 0
                for f in 0..<frames {
                    od[f * on + c] = f < count ? src![f * stride] * (from + delta * Float(f)) : 0
                }
            }
            channelBase += on
        }
        gain[1] = to
    }

    // MARK: - Volume keys

    private func setupKeyTap() {
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED: media and volume keys
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in SoftVolume.shared.handleKey(type: type, event: event) },
            userInfo: nil
        ) else {
            DTLog("[SoftVolume] key tap create FAILED"); return
        }
        keyTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
    }

    private func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Only re-enable. Disabling the tap sends .tapDisabledByUserInput here, so disabling
            // again from this handler loops forever through WindowServer and drains the battery.
            if let tap = keyTap, activeDevice != kAudioObjectUnknown { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard activeDevice != kAudioObjectUnknown,
              let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0x0A
        let soundUp = 0, soundDown = 1, mute = 7   // NX_KEYTYPE_*
        guard key == soundUp || key == soundDown || key == mute else { return Unmanaged.passUnretained(event) }
        if isDown {
            // ⌥⇧ gives quarter steps, like the system volume
            let fine = ns.modifierFlags.contains([.option, .shift])
            if key == mute { toggleMute() } else { step(up: key == soundUp, fine: fine) }
        }
        return nil   // swallow down and up, so macOS does not show its "not allowed" HUD
    }

    // MARK: - Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// The check macOS makes before the volume keys can change a device: a settable volume on
    /// the main element or on the device's stereo pair.
    static func hasHardwareVolume(_ device: AudioObjectID) -> Bool {
        var elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
        var pairAddr = address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyScopeOutput)
        var pair: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        AudioObjectGetPropertyData(device, &pairAddr, 0, nil, &size, &pair)
        elements += pair
        return elements.contains { element in
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(device, &addr)
                && AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
        }
    }

    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func deviceUID(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    private static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return status == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// Number of input buffers the device itself adds to an IOProc.
    private static func inputBufferCount(_ device: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }
}

// MARK: - On-screen volume indicator

/// Small volume overlay, shown because macOS shows none for software volume.
final class VolumeHUD {
    private var panel: NSPanel?
    private var host: NSHostingView<VolumeHUDView>?
    private var hideWork: DispatchWorkItem?

    func show(level: Double, muted: Bool) {
        let view = VolumeHUDView(level: level, muted: muted)
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let h = NSHostingView(rootView: view)
            p.contentView = h
            panel = p
            host = h
        }
        host?.rootView = view
        guard let panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 12, y: vf.maxY - panel.frame.height - 8))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self?.panel?.animator().alphaValue = 0 },
                                                 completionHandler: { self?.panel?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

struct VolumeHUDView: View {
    let level: Double
    let muted: Bool

    private var symbol: String {
        if muted || level <= 0 { return "speaker.slash.fill" }
        return level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)
            ProgressView(value: muted ? 0 : level)
                .progressViewStyle(.linear)
                .tint(.primary)
        }
        .padding(.horizontal, 16)
        .frame(width: 240, height: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(muted ? "Volume muted" : "Volume \(Int((level * 100).rounded())) percent")
    }
}
