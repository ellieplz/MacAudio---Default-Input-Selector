//
//  ContentView.swift
//  swift test
//
//  Created by Eleonora Kurowska on 21/01/2026.
//
// to do:
// add a setting to "lock" the input and output devices, so that when anything changes the setting outside the app, snap it to last selected one

import SwiftUI
import CoreAudio
import AudioToolbox
import Combine
import AppKit
import ServiceManagement
import AVFoundation

class LaunchAtLoginManager: ObservableObject {
    @Published var isEnabled: Bool = false
    init() {
        isEnabled = LaunchAtLoginManager.isLoginItemEnabled()
    }
    static func isLoginItemEnabled() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = LaunchAtLoginManager.isLoginItemEnabled()
        } catch {
            // optionally handle error
        }
    }
}

class DockIconManager: ObservableObject {
    @Published var hideDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(hideDockIcon, forKey: "HideDockIconPreference")
            applyActivationPolicy()
        }
    }

    init() {
        let saved = UserDefaults.standard.object(forKey: "HideDockIconPreference") as? Bool ?? false
        self.hideDockIcon = saved
        // Apply on startup
        DispatchQueue.main.async { [weak self] in
            self?.applyActivationPolicy()
        }
    }

    func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = hideDockIcon ? .accessory : .regular
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: false)
        }
    }
}

@main
struct SwiftTestApp: App {
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager()
    @StateObject private var dockIconManager = DockIconManager()
    var body: some Scene {
        MenuBarExtra("MacAudio", systemImage: "speaker.wave.2") {
            // Keep a minimal, always-present header to ensure the menu builds
            Label("MacAudio", systemImage: "speaker.wave.2")
            Divider()
            ContentView()
            Toggle(isOn: $launchAtLoginManager.isEnabled) {
                Text("Launch on Login")
            }
            .toggleStyle(.checkbox)
            .onChange(of: launchAtLoginManager.isEnabled) { oldValue, newValue in
                launchAtLoginManager.setLaunchAtLogin(newValue)
            }
            .onAppear {
                launchAtLoginManager.isEnabled = LaunchAtLoginManager.isLoginItemEnabled()
            }
            Toggle(isOn: $dockIconManager.hideDockIcon) {
                Text("Hide Dock Icon")
            }
            .toggleStyle(.checkbox)
            .onAppear {
                dockIconManager.applyActivationPolicy()
            }
            Divider()
            Button("Quit", systemImage: "xmark.circle") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
}

struct VideoDevice: Identifiable, Equatable, Hashable {
    let id: String  // Use AVCaptureDevice.uniqueID
    let name: String
}

class VideoDeviceManager: ObservableObject {
    @Published var videoDevices: [VideoDevice] = []
    @Published var selectedVideo: VideoDevice? = nil {
        didSet {
            if let id = selectedVideo?.id {
                UserDefaults.standard.set(id, forKey: "PreferredVideoDeviceUniqueID")
            } else {
                UserDefaults.standard.removeObject(forKey: "PreferredVideoDeviceUniqueID")
            }
        }
    }

    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        loadDevices()
        startObservingDeviceNotifications()
    }

    func loadDevices() {
        // Ensure authorization status allows discovery; request if not determined
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.refreshDevices()
                }
            }
        } else {
            refreshDevices()
        }
    }

    private func startObservingDeviceNotifications() {
        let center = NotificationCenter.default
        let connected = center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDevices()
        }
        let disconnected = center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDevices()
        }
        notificationObservers.append(contentsOf: [connected, disconnected])
    }

    deinit {
        let center = NotificationCenter.default
        for token in notificationObservers {
            center.removeObserver(token)
        }
    }

    private func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified)
        let devices = discovery.devices
        self.videoDevices = devices.map { VideoDevice(id: $0.uniqueID, name: $0.localizedName) }
        // Determine preferred ID (saved or current selection) and try to keep it if still present
        let savedID = UserDefaults.standard.string(forKey: "PreferredVideoDeviceUniqueID")
        let preferredID = savedID ?? self.selectedVideo?.id
        if let preferredID, let match = self.videoDevices.first(where: { $0.id == preferredID }) {
            self.selectedVideo = match
        } else {
            self.selectedVideo = self.videoDevices.first
        }
    }
}

class AudioDeviceManager: ObservableObject {
    private static let preferredInputKey = "PreferredAudioInputDeviceID"
    private static let preferredOutputKey = "PreferredAudioOutputDeviceID"
    private static let lockDevicesKey = "LockAudioDevices"

    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInput: AudioDevice? = nil
    @Published var selectedOutput: AudioDevice? = nil
    @Published var lockDevices: Bool {
        didSet {
            UserDefaults.standard.set(lockDevices, forKey: Self.lockDevicesKey)
        }
    }

    private let audioQueue = DispatchQueue(label: "AudioDeviceManager.queue")
    private var isRestoringDevice = false

    init() {
        self.lockDevices = UserDefaults.standard.bool(forKey: Self.lockDevicesKey)
        loadDevices()
        startObservingAudioHardware()
    }

    func loadDevices() {
        inputDevices = fetchDevices(isInput: true)
        outputDevices = fetchDevices(isInput: false)

        selectedInput = inputDevices.first(where: { $0.id == getDefaultDeviceID(isInput: true) })
        selectedOutput = outputDevices.first(where: { $0.id == getDefaultDeviceID(isInput: false) })

        restorePreferredSelections()
    }

    private func startObservingAudioHardware() {
        var addressDevices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var addressDefaultInput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var addressDefaultOutput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        AudioObjectAddPropertyListenerBlock(systemObject, &addressDevices, DispatchQueue.main) { (_, _) in
            self.loadDevices()
            self.restorePreferredSelections()
        }

        AudioObjectAddPropertyListenerBlock(systemObject, &addressDefaultInput, DispatchQueue.main) { (_, _) in
            self.handleDefaultInputChange()
        }

        AudioObjectAddPropertyListenerBlock(systemObject, &addressDefaultOutput, DispatchQueue.main) { (_, _) in
            self.handleDefaultOutputChange()
        }
    }

    deinit {
        var addressDevices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var addressDefaultInput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var addressDefaultOutput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(systemObject, &addressDevices, DispatchQueue.main, { (_, _) in })
        AudioObjectRemovePropertyListenerBlock(systemObject, &addressDefaultInput, DispatchQueue.main, { (_, _) in })
        AudioObjectRemovePropertyListenerBlock(systemObject, &addressDefaultOutput, DispatchQueue.main, { (_, _) in })
    }

    private func restorePreferredSelections() {
        // Try to keep previously selected devices by ID
        if let savedInput = UserDefaults.standard.object(forKey: Self.preferredInputKey) as? UInt32,
           let matchIn = inputDevices.first(where: { $0.id == AudioDeviceID(savedInput) }) {
            selectedInput = matchIn
        }
        if let savedOutput = UserDefaults.standard.object(forKey: Self.preferredOutputKey) as? UInt32,
           let matchOut = outputDevices.first(where: { $0.id == AudioDeviceID(savedOutput) }) {
            selectedOutput = matchOut
        }
    }

    private func handleDefaultInputChange() {
        guard !isRestoringDevice else { return }
        loadDevices()
        
        if lockDevices, let preferredID = UserDefaults.standard.object(forKey: Self.preferredInputKey) as? UInt32 {
            let currentDefaultID = getDefaultDeviceID(isInput: true)
            if currentDefaultID != preferredID, let preferredDevice = inputDevices.first(where: { $0.id == AudioDeviceID(preferredID) }) {
                // Device was changed externally, snap it back
                isRestoringDevice = true
                setDefaultDevice(preferredDevice, isInput: true)
                isRestoringDevice = false
            }
        }
        restorePreferredSelections()
    }

    private func handleDefaultOutputChange() {
        guard !isRestoringDevice else { return }
        loadDevices()
        
        if lockDevices, let preferredID = UserDefaults.standard.object(forKey: Self.preferredOutputKey) as? UInt32 {
            let currentDefaultID = getDefaultDeviceID(isInput: false)
            if currentDefaultID != preferredID, let preferredDevice = outputDevices.first(where: { $0.id == AudioDeviceID(preferredID) }) {
                // Device was changed externally, snap it back
                isRestoringDevice = true
                setDefaultDevice(preferredDevice, isInput: false)
                isRestoringDevice = false
            }
        }
        restorePreferredSelections()
    }


    private func fetchDevices(isInput: Bool) -> [AudioDevice] {
        var propertySize = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sysObjID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sysObjID, &address, 0, nil, &propertySize) == noErr else { return [] }
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(sysObjID, &address, 0, nil, &propertySize, &deviceIDs) == noErr else { return [] }
        var devices: [AudioDevice] = []
        for id in deviceIDs {
            if deviceMatchesDirection(id: id, isInput: isInput), let name = getDeviceName(deviceID: id) {
                devices.append(AudioDevice(id: id, name: name))
            }
        }
        return devices
    }

    private func deviceMatchesDirection(id: AudioDeviceID, isInput: Bool) -> Bool {
        var _: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyDataSize(id, &address, 0, nil, &propertySize) == noErr {
            let streamCount = Int(propertySize) / MemoryLayout<AudioStreamID>.size
            return streamCount > 0
        }
        return false
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertySize = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // First, get the size required
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        guard status == noErr else { return nil }
        // Allocate buffer
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: MemoryLayout<UInt8>.alignment)
        defer { buffer.deallocate() }
        var size = propertySize
        let status2 = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer)
        guard status2 == noErr else { return nil }
        let cfName = buffer.load(as: CFString.self)
        return cfName as String
    }

    private func getDefaultDeviceID(isInput: Bool) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sysObjID = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectGetPropertyData(
            sysObjID,
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    func setDefaultDevice(_ device: AudioDevice, isInput: Bool) {
        var deviceID = device.id
        var address = AudioObjectPropertyAddress(
            mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sysObjID = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectSetPropertyData(
            sysObjID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
        if isInput {
            UserDefaults.standard.set(deviceID, forKey: Self.preferredInputKey)
        } else {
            UserDefaults.standard.set(deviceID, forKey: Self.preferredOutputKey)
        }
        loadDevices() // Refresh selections
    }
}

struct ContentView: View {
    @StateObject private var deviceManager = AudioDeviceManager()
    @StateObject private var videoManager = VideoDeviceManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            //Text("Default Audio Device")
                //.font(.title2)
                //.bold()
            Group {
                Picker("Output Device", selection: Binding(
                    get: { deviceManager.selectedOutput ?? deviceManager.outputDevices.first },
                    set: { if let dev = $0 { deviceManager.setDefaultDevice(dev, isInput: false) } }
                )) {
                    ForEach(deviceManager.outputDevices) { device in
                        Text(device.name).tag(device as AudioDevice?)
                    }
                }
                .pickerStyle(PopUpButtonPickerStyle())
            }
            Group {
                Picker("Input Device", selection: Binding(
                    get: { deviceManager.selectedInput ?? deviceManager.inputDevices.first },
                    set: { if let dev = $0 { deviceManager.setDefaultDevice(dev, isInput: true) } }
                )) {
                    ForEach(deviceManager.inputDevices) { device in
                        Text(device.name).tag(device as AudioDevice?)
                    }
                }
                .pickerStyle(PopUpButtonPickerStyle())
            }
            Group {
                Picker("Default Webcam", selection: Binding(
                    get: { videoManager.selectedVideo ?? videoManager.videoDevices.first },
                    set: { if let dev = $0 { videoManager.selectedVideo = dev } }
                )) {
                    ForEach(videoManager.videoDevices) { device in
                        Text(device.name).tag(device as VideoDevice?)
                    }
                }
                .pickerStyle(PopUpButtonPickerStyle())
            }
            Divider()
            Toggle(isOn: $deviceManager.lockDevices) {
                Text("Lock Audio Devices")
            }
            .toggleStyle(.checkbox)
            .help("When enabled, the app will automatically restore your selected audio devices if they're changed by other apps or system settings")
            Divider()
        }
        .padding(30)
        .frame(minWidth: 340, minHeight: 300)
    }
}

#Preview {
    ContentView()
}

