//
//  ContentView.swift
//  swift test
//
//  Created by Eleonora Kurowska on 21/01/2026.
//
//

import SwiftUI
import CoreAudio
import AudioToolbox
import Combine

@main
struct SwiftTestApp: App {
    var body: some Scene {
        MenuBarExtra("Audio Devices", systemImage: "speaker.wave.2") {
            ContentView()
        }
    }
}

struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
}

class AudioDeviceManager: ObservableObject {
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInput: AudioDevice? = nil
    @Published var selectedOutput: AudioDevice? = nil

    init() {
        loadDevices()
    }

    func loadDevices() {
        inputDevices = fetchDevices(isInput: true)
        outputDevices = fetchDevices(isInput: false)

        selectedInput = inputDevices.first(where: { $0.id == getDefaultDeviceID(isInput: true) })
        selectedOutput = outputDevices.first(where: { $0.id == getDefaultDeviceID(isInput: false) })
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
        loadDevices() // Refresh selections
    }
}

struct ContentView: View {
    @StateObject private var deviceManager = AudioDeviceManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Default Audio Device Selector")
                .font(.title2)
                .bold()
            Group {
                Text("Output Device:")
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
                Text("Input Device:")
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
            Spacer()
        }
        .padding(30)
        .frame(minWidth: 340, minHeight: 300)
    }
}

#Preview {
    ContentView()
}
