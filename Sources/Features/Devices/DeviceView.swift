import CoreBluetooth
import SwiftUI
import UIKit

struct DeviceView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    @EnvironmentObject private var queue: SendQueue

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Bluetooth", value: stateText)
                    LabeledContent("Connection", value: connectionText)
                    if let name = bluetooth.connectedName {
                        LabeledContent("Badge", value: name)
                    }
                    if let space = bluetooth.freeSpaceKB {
                        LabeledContent("Free space", value: "\(space) KB")
                    }
                    if let message = bluetooth.lastMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }

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

                if !queue.jobs.isEmpty || queue.isDraining {
                    Section("Queue (\(queue.jobs.count))") {
                        if queue.isDraining {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(queue.currentLabel ?? "Sending…").font(.caption)
                                ProgressView(value: bluetooth.uploadProgress)
                            }
                        }
                        ForEach(queue.jobs) { job in
                            HStack(spacing: 10) {
                                if let preview = job.preview {
                                    Image(uiImage: preview)
                                        .resizable().scaledToFill()
                                        .frame(width: 36, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Image(systemName: "photo")
                                        .frame(width: 36, height: 36)
                                        .foregroundStyle(.secondary)
                                }
                                Text(job.label).lineLimit(1)
                                Spacer()
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { queue.jobs[$0] }.forEach(queue.remove)
                        }
                        Button(role: .destructive) { queue.clear() } label: {
                            Label("Clear queue", systemImage: "trash")
                        }
                    }
                }

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
                }
            }
            .navigationTitle("Badge")
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
