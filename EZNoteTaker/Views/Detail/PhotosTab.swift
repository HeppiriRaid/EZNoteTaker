import PhotosUI
import SwiftData
import SwiftUI

/// All photos of a class, grouped by building. Photos can be added from the library and moved between buildings.
struct PhotosTab: View {
    let lecture: Lecture
    @Environment(\.modelContext) private var context
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var viewing: LecturePhoto?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 30, matching: .images) {
                Label("Add photos from library", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .onChange(of: pickerItems) { _, items in importPhotos(items) }

            if lecture.photos.isEmpty {
                ContentUnavailableView("No photos", systemImage: "camera",
                                       description: Text("Photos you take while recording show up here and on each building's cheat sheet card."))
            }

            ForEach(lecture.sortedBuildings.filter { !$0.photos.isEmpty }) { building in
                group(title: building.name, photos: building.sortedPhotos)
            }
            let unassigned = lecture.sortedPhotos.filter { $0.building == nil }
            if !unassigned.isEmpty {
                group(title: "Not matched to a building", photos: unassigned)
            }
        }
        .fullScreenCover(item: $viewing) { photo in
            PhotoViewer(photo: photo, buildings: lecture.sortedBuildings)
        }
    }

    private func group(title: String, photos: [LecturePhoto]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.serifHeadline(17))
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(photos) { photo in
                    Button { viewing = photo } label: {
                        PhotoThumb(fileName: photo.fileName, maxPixel: 400)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let name = try? FileStore.savePhotoData(data) else { continue }
                let photo = LecturePhoto(fileName: name, takenAt: lecture.durationSeconds)
                context.insert(photo)
                photo.lecture = lecture
            }
            try? context.save()
            pickerItems = []
        }
    }
}

/// Full-screen photo with zoom, caption and "this is…" building reassignment.
struct PhotoViewer: View {
    @Bindable var photo: LecturePhoto
    let buildings: [Building]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var scale: CGFloat = 1
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = ImageCache.shared.full(for: photo.fileName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }
                            .onEnded { _ in withAnimation(.spring) { scale = 1 } })
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if !photo.caption.isEmpty { Text(photo.caption).font(.subheadline) }
                    Text("Taken at \(TimeFormat.clock(photo.takenAt)) into class")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu {
                        ForEach(buildings) { building in
                            Button {
                                photo.building = building
                                photo.manuallyAssigned = true
                                try? context.save()
                            } label: {
                                if photo.building?.id == building.id {
                                    Label(building.name, systemImage: "checkmark")
                                } else {
                                    Text(building.name)
                                }
                            }
                        }
                        Divider()
                        Button("No building") {
                            photo.building = nil
                            photo.manuallyAssigned = true
                            try? context.save()
                        }
                    } label: {
                        Label(photo.building?.name ?? "Choose building…", systemImage: "building.2")
                            .font(.headline)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.brick, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .disabled(buildings.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.ultraThinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if let image = ImageCache.shared.full(for: photo.fileName) {
                            ShareLink(item: Image(uiImage: image), preview: SharePreview(photo.caption.isEmpty ? "Photo" : photo.caption,
                                                                                       image: Image(uiImage: image)))
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    }
                }
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirmDelete) {
                Button("Delete Photo", role: .destructive) {
                    FileStore.delete(fileName: photo.fileName, in: FileStore.photoDirectory)
                    context.delete(photo)
                    try? context.save()
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
