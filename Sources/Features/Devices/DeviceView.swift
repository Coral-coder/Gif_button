import CoreBluetooth
import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    @EnvironmentObject private var queue: SendQueue
    @State private var showQueue = false

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Bluetooth", value: stateText)
                    LabeledContent("Connection", value: connectionText)
                    if let name = bluetooth.connectedName {
                        LabeledContent("Badge", value: name)
                    }
                    if let type = bluetooth.detectedBadgeName {
                        LabeledContent("Protocol", value: type)
                    }
                    if bluetooth.detectedBadgeName != nil && !bluetooth.badgeSupported {
                        Label("Detected, but sending to this badge isn't supported yet.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let space = bluetooth.freeSpaceKB {
                        LabeledContent("Free space", value: "\(space) KB")
                    }
                    if let message = bluetooth.lastMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(GlassRow())

                Section {
                    if bluetooth.isConnected {
                        Button(role: .destructive) { bluetooth.disconnect() } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                    } else {
                        Button {
                            bluetooth.isScanning ? bluetooth.stopScan() : bluetooth.startScan()
                        } label: {
                            Label(bluetooth.isScanning ? "Stop scanning" : "Scan for badge",
                                  systemImage: bluetooth.isScanning ? "stop.circle" : "antenna.radiowaves.left.and.right")
                        }
                    }
                }
                .listRowBackground(GlassRow())

                Section("Queue") {
                    if queue.isDraining {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(queue.currentLabel ?? "Sending…").font(.caption)
                            ProgressView(value: bluetooth.uploadProgress)
                        }
                    }
                    Button { showQueue = true } label: {
                        Label(queue.jobs.isEmpty ? "Show queue" : "Show queue (\(queue.jobs.count))",
                              systemImage: "tray.full")
                    }
                }
                .listRowBackground(GlassRow())

                if !bluetooth.discovered.isEmpty && !bluetooth.isConnected {
                    Section("Devices") {
                        ForEach(bluetooth.discovered) { device in
                            Button { bluetooth.connect(device) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(device.name).foregroundStyle(.primary)
                                        if device.isBadge {
                                            Text("Badge").font(.caption2).foregroundStyle(.green)
                                        }
                                    }
                                    Spacer()
                                    if device.rssi != 0 {
                                        Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(GlassRow())
                }

                if !bluetooth.services.isEmpty {
                    Section("GATT (advanced / reverse-engineering)") {
                        ForEach(bluetooth.services) { service in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Service \(service.uuid)").font(.caption.bold())
                                ForEach(service.characteristics) { ch in
                                    Text("• \(ch.uuid) [\(ch.properties.joined(separator: ","))]")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listRowBackground(GlassRow())
                }

                if !bluetooth.debugLog.isEmpty {
                    Section("Debug log (newest first)") {
                        ForEach(Array(bluetooth.debugLog.suffix(40).reversed().enumerated()), id: \.offset) { item in
                            Text(item.element)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .listRowBackground(GlassRow())
                }
            }
            .navigationTitle("Badge")
            .aeroScreen()
            .sheet(isPresented: $showQueue) { QueueView() }
        }
    }

    private var stateText: String {
        switch bluetooth.state {
        case .poweredOn: return "On"
        case .poweredOff: return "Off"
        case .unauthorized: return "Not allowed"
        case .unsupported: return "Unsupported"
        case .resetting: return "Resetting"
        default: return "Unknown"
        }
    }

    private var connectionText: String {
        switch bluetooth.status {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .sending: return "Sending…"
        case .disconnected: return "Disconnected"
        }
    }
}
