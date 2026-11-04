import SwiftUI
import AVKit
import LensPromptCore

struct RecordingsBrowser: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var oldestFirst = false
    @State private var selection: UUID?
    @State private var player = AVPlayer()
    @State private var previewError: String?
    @State private var loadingPreview = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var trashCandidate: TakeRecord?
    @State private var confirmTrash = false

    private var recordings: [TakeRecord] {
        let filtered = model.takes.takes.filter { search.isEmpty || $0.fileName.localizedCaseInsensitiveContains(search) }
        return filtered.sorted { oldestFirst ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt }
    }
    private var selected: TakeRecord? { model.takes.takes.first { $0.id == selection } }
    private func exists(_ take: TakeRecord) -> Bool { FileManager.default.fileExists(atPath: take.fileURL.path) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recordings").font(.title2.bold())
                Text("\(model.takes.takes.count) saved files").foregroundStyle(.secondary)
                Spacer()
                if model.libraryRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshRecordings() }
                    .disabled(model.libraryRefreshing)
                Button("Open Folder", systemImage: "folder") { NSWorkspace.shared.open(model.outputFolder) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            if let error = model.libraryError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("Dismiss") { model.libraryError = nil }
                }.font(.callout).padding(10).background(.orange.opacity(0.1))
            }
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        TextField("Search recordings", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search recordings")
                        Toggle("Oldest first", isOn: $oldestFirst).toggleStyle(.checkbox).font(.caption)
                    }.padding(10)
                    List(selection: $selection) {
                        ForEach(recordings) { take in
                            HStack(spacing: 10) {
                                RecordingThumbnail(url: take.fileURL)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(take.fileName).font(.callout).lineLimit(2)
                                    Text("\(formatDuration(take.duration)) · \(take.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !exists(take) {
                                        Text("File missing").font(.caption).foregroundStyle(.orange)
                                    } else if take.status != .complete {
                                        Text(take.status == .interrupted ? "Interrupted take" : "May be incomplete")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(take.id)
                            .contextMenu {
                                Button("Reveal in Finder") { reveal(take) }.disabled(!exists(take))
                                Button("Rename…") { beginRename(take) }.disabled(model.inputsLocked || !exists(take))
                                Button("Move to Trash…", role: .destructive) { requestTrash(take) }
                                    .disabled(model.inputsLocked || !exists(take))
                            }
                        }
                    }
                    .overlay {
                        if recordings.isEmpty {
                            ContentUnavailableView(search.isEmpty ? "No recordings yet" : "No matching recordings",
                                systemImage: "film", description: Text(search.isEmpty
                                    ? "Saved videos in your recordings folder appear here."
                                    : "Try a different file name."))
                        }
                    }
                    .onDeleteCommand {
                        if let take = selected, exists(take), !model.inputsLocked { requestTrash(take) }
                    }
                }
                .frame(minWidth: 300, idealWidth: 360)
                VStack(alignment: .leading, spacing: 12) {
                    if let take = selected {
                        ZStack {
                            Color.black
                            VideoPlayer(player: player)
                            if loadingPreview { ProgressView("Loading preview…").padding().background(.black.opacity(0.7)) }
                            if let error = previewError {
                                ContentUnavailableView("Preview unavailable", systemImage: "video.slash", description: Text(error))
                            }
                        }
                        .frame(minHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(take.fileName).font(.headline).textSelection(.enabled)
                        Text("\(formatDuration(take.duration)) · \(fileSize(take)) · \(statusText(take))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(take.fileURL.path).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        if let format = take.videoFormat { Text(format).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("Reveal in Finder", systemImage: "folder") { reveal(take) }.disabled(!exists(take))
                            Button("Rename…", systemImage: "pencil") { beginRename(take) }
                                .disabled(model.inputsLocked || !exists(take))
                            Spacer()
                            if exists(take) {
                                Button("Move to Trash…", systemImage: "trash", role: .destructive) { requestTrash(take) }
                                    .disabled(model.inputsLocked)
                            } else {
                                Button("Remove Missing Entry") { model.removeTakeFromList(take) }
                            }
                        }
                        Text("Trashed videos can be recovered from the Mac’s Trash.")
                            .font(.caption2).foregroundStyle(.secondary)
                        if model.inputsLocked {
                            Text("Finish the current take before renaming or deleting recordings.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        ContentUnavailableView("Select a recording", systemImage: "play.rectangle",
                            description: Text("Preview, scrub, rename, or move previous takes to Trash."))
                    }
                }
                .padding(14)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, idealWidth: 1020, minHeight: 500, idealHeight: 620)
        .preferredColorScheme(.dark)
        .onChange(of: recordings.map(\.id), initial: true) { _, ids in
            if selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
        .task(id: selected?.fileURL) { await loadPreview() }
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
        .alert("Rename recording", isPresented: $renaming) {
            TextField("File name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let take = selected {
                    player.pause()
                    model.renameRecording(take, to: newName)
                }
            }
        } message: { Text("The video extension is kept. Existing files will not be overwritten.") }
        .confirmationDialog("Move recording to Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let take = trashCandidate {
                    player.pause()
                    player.replaceCurrentItem(with: nil)
                    if !model.trashRecording(take) { Task { await loadPreview() } }
                }
                trashCandidate = nil
            }
            Button("Cancel", role: .cancel) { trashCandidate = nil }
        } message: {
            Text("\(trashCandidate?.fileName ?? "This recording") will move to the Mac’s Trash. You can restore it there.")
        }
    }

    private func fileSize(_ take: TakeRecord) -> String {
        let bytes = model.recordingSizes[take.fileURL]
            ?? (try? take.fileURL.resourceValues(forKeys: [.fileSizeKey])).flatMap { $0.fileSize }.map(Int64.init)
        return bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unavailable"
    }
    private func reveal(_ take: TakeRecord) { NSWorkspace.shared.activateFileViewerSelecting([take.fileURL]) }
    private func beginRename(_ take: TakeRecord) {
        selection = take.id
        newName = take.fileURL.deletingPathExtension().lastPathComponent
        renaming = true
    }
    private func requestTrash(_ take: TakeRecord) { trashCandidate = take; confirmTrash = true }

    @MainActor private func loadPreview() async {
        player.pause()
        player.replaceCurrentItem(with: nil)
        previewError = nil
        guard let take = selected else { loadingPreview = false; return }
        guard exists(take) else { previewError = "The file was moved or deleted outside the app."; loadingPreview = false; return }
        loadingPreview = true
        let asset = AVURLAsset(url: take.fileURL)
        do {
            let playable = try await asset.load(.isPlayable)
            guard !Task.isCancelled, selected?.fileURL == take.fileURL else { return }
            loadingPreview = false
            guard playable else { previewError = "This file may be incomplete or use an unsupported format."; return }
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.play()
        } catch {
            guard !Task.isCancelled, selected?.fileURL == take.fileURL else { return }
            loadingPreview = false
            previewError = error.localizedDescription
        }
    }
}

private struct RecordingThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color(white: 0.15)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "film").foregroundStyle(.secondary) }
        }
        .frame(width: 90, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 180, height: 108)
            if let result = try? await generator.image(at: .zero), !Task.isCancelled {
                image = NSImage(cgImage: result.image, size: .zero)
            }
        }
    }
}
