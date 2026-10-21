import MapKit
import SwiftData
import SwiftUI

/// One building's full cheat-sheet card: photos, the exam facts (name · architect · year), story and trivia.
struct BuildingDetailView: View {
    @Bindable var building: Building
    @Environment(\.modelContext) private var context
    @State private var editing = false
    @State private var viewing: LecturePhoto?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                photoCarousel
                examFacts

                if !building.significance.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: "Why it matters", systemImage: "lightbulb")
                        RichText(building.significance)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                if !building.professorEmphasis.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Professor emphasized", systemImage: "exclamationmark.bubble")
                        BulletList(items: building.professorEmphasis, symbol: "flame.fill", color: Theme.recordRed)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                if !building.keyFacts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Key facts", systemImage: "checklist")
                        BulletList(items: building.keyFacts)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                if !building.trivia.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Stories & trivia", systemImage: "sparkles")
                        BulletList(items: building.trivia, symbol: "quote.opening", color: Theme.gold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                if !building.verificationNote.isEmpty {
                    Label {
                        RichText(building.verificationNote).font(.caption)
                    } icon: {
                        Image(systemName: "checkmark.shield").foregroundStyle(Theme.sage)
                    }
                    .foregroundStyle(.secondary)
                    .card(padding: 12)
                }

                if let coordinate = building.coordinate {
                    let point = CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.lon)
                    Map(initialPosition: .region(MKCoordinateRegion(center: point, latitudinalMeters: 600, longitudinalMeters: 600))) {
                        Marker(building.name, systemImage: "building.columns", coordinate: point).tint(Theme.brick)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "My notes", systemImage: "pencil")
                    TextField("Add your own notes or memory tricks…", text: $building.userNotes, axis: .vertical)
                        .lineLimit(3...10)
                }
                .card()

                if let lecture = building.lecture {
                    Label("Visited \(lecture.date.formatted(date: .long, time: .omitted)) · \(lecture.displayTitle)",
                          systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Theme.paper)
        .navigationTitle(building.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    building.isStarred.toggle()
                    try? context.save()
                } label: {
                    Image(systemName: building.isStarred ? "star.fill" : "star")
                        .foregroundStyle(building.isStarred ? Theme.gold : Theme.brick)
                }
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) { BuildingEditor(building: building) }
        .fullScreenCover(item: $viewing) { photo in
            PhotoViewer(photo: photo, buildings: building.lecture?.sortedBuildings ?? [building])
        }
        .onDisappear { try? context.save() }
    }

    @ViewBuilder
    private var photoCarousel: some View {
        let photos = building.sortedPhotos
        if photos.isEmpty {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.brick.opacity(0.1))
                .frame(height: 160)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "building.columns").font(.largeTitle)
                        Text("No photos yet — assign one from the Photos tab").font(.caption)
                    }
                    .foregroundStyle(Theme.brick)
                }
        } else {
            TabView {
                ForEach(photos) { photo in
                    PhotoThumb(fileName: photo.fileName, maxPixel: 1400)
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                        .clipped()
                        .onTapGesture { viewing = photo }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var examFacts: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(building.name).font(.serifTitle(26))
                Spacer()
                Pill(text: building.importance.label,
                     systemImage: building.importance == .high ? "flame.fill" : "info.circle",
                     color: Theme.importanceColor(building.importance))
            }
            HStack(spacing: 10) {
                FactBox(label: "Architect", value: building.architectDisplay, systemImage: "person.fill")
                FactBox(label: "Built", value: building.yearDisplay, systemImage: "calendar")
            }
            HStack(spacing: 10) {
                if !building.style.isEmpty { FactBox(label: "Style", value: building.style, systemImage: "paintbrush") }
                if !building.location.isEmpty { FactBox(label: "Location", value: building.location, systemImage: "mappin") }
            }
        }
        .card()
    }
}

struct FactBox: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: systemImage)
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.brick)
            Text(value)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Lets the student correct anything the AI got wrong.
struct BuildingEditor: View {
    @Bindable var building: Building
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var facts = ""
    @State private var trivia = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Exam facts") {
                    TextField("Name", text: $building.name)
                    TextField("Architect", text: $building.architect)
                    TextField("Year built (e.g. 1889–1891)", text: $building.yearBuilt)
                    TextField("Style", text: $building.style)
                    TextField("Location", text: $building.location)
                    Picker("Importance", selection: Binding(get: { building.importance }, set: { building.importance = $0 })) {
                        ForEach(ExamImportance.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Why it matters") {
                    TextField("Significance", text: $building.significance, axis: .vertical)
                }
                Section("Key facts (one per line)") {
                    TextField("Facts", text: $facts, axis: .vertical).lineLimit(4...12)
                }
                Section("Stories & trivia (one per line)") {
                    TextField("Trivia", text: $trivia, axis: .vertical).lineLimit(3...10)
                }
            }
            .navigationTitle("Edit Building")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        building.keyFacts = lines(facts)
                        building.trivia = lines(trivia)
                        building.yearSort = LectureAnalysis.firstYear(in: building.yearBuilt)
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                facts = building.keyFacts.joined(separator: "\n")
                trivia = building.trivia.joined(separator: "\n")
            }
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
