import SwiftUI
import UIKit

/// The send queue, presented as a sheet from anywhere (the GIFs toolbar button,
/// the Badge tab, or the upload popup).
struct QueueView: View {
    @EnvironmentObject private var queue: SendQueue
    @EnvironmentObject private var bluetooth: BluetoothManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if queue.isDraining {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(queue.currentLabel ?? "Sending…").font(.caption)
                            ProgressView(value: bluetooth.uploadProgress)
                        }
                    }
                    .listRowBackground(GlassRow())
                }

                if queue.jobs.isEmpty {
                    Section {
                        Text(queue.isDraining ? "Finishing up…" : "Queue is empty.")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(GlassRow())
                } else {
                    Section("Pending (\(queue.jobs.count))") {
                        ForEach(queue.jobs) { job in
                            HStack(spacing: 10) {
                                if let preview = job.preview {
                                    Image(uiImage: preview)
                                        .resizable().scaledToFill()
                                        .frame(width: 40, height: 40)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Image(systemName: "photo")
                                        .frame(width: 40, height: 40)
                                        .foregroundStyle(.secondary)
                                }
                                Text(job.label).lineLimit(1)
                                Spacer()
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { queue.jobs[$0] }.forEach(queue.remove)
                        }
                    }
                    .listRowBackground(GlassRow())
                }

                if !bluetooth.isConnected {
                    Section {
                        Label("Badge not connected — items send automatically once it connects.",
                              systemImage: "tray.and.arrow.down")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(GlassRow())
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .aeroScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    if !queue.jobs.isEmpty {
                        Button(role: .destructive) { queue.clear() } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

/// Small floating progress popup shown app-wide while the queue is draining.
/// Tapping it opens the full queue.
struct UploadHUD: View {
    @EnvironmentObject private var queue: SendQueue
    @EnvironmentObject private var bluetooth: BluetoothManager
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ProgressView(value: bluetooth.uploadProgress)
                    .progressViewStyle(.circular)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sending to badge").font(.footnote.weight(.semibold))
                    Text(queue.currentLabel ?? "…")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(Int(bluetooth.uploadProgress * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if queue.jobs.count > 1 {
                    Text("+\(queue.jobs.count - 1)")
                        .font(.caption2).padding(4)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }
}
