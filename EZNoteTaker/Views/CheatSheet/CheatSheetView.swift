import MapKit
import SwiftData
import SwiftUI

/// The exam review sheet: every building from every class, stacked by day, with photos,
/// architect, year, key facts and trivia. Also as a timeline (for memorizing years) and a map.
struct CheatSheetView: View {
    @Query(sort: \Lecture.date) private var lectures: [Lecture]
    @Query private var allBuildings: [Building]
    @State private var mode: Mode = .byClass
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var exportFile: ExportFile?
    @State private var exporting = false

    struct ExportFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    enum ExportFormat { case pdf, docx }

    enum Mode: String, CaseIterable, Identifiable {
        case byClass = "By Class", timeline = "Timeline", map = "Map"
        var id: String { rawValue }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All buildings", starred = "Starred", likely = "Likely on exam", weak = "Need practice"
        var id: String { rawValue }
    }

    private func matches(_ b: Building) -> Bool {
        switch filter {
        case .all: break
        case .starred: if !b.isStarred { return false }
        case .likely: if b.importance != .high { return false }
        case .weak: if b.studyMissed == 0 { return false }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [b.name, b.architect, b.yearBuilt, b.style, b.location].contains { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allBuildings.isEmpty {
                    ContentUnavailableView("Your cheat sheet is empty", systemImage: "list.bullet.rectangle.portrait",
                                           description: Text("Record a class — every building the professor talks about lands here automatically, with your photos."))
                } else {
                    switch mode {
                    case .byClass: byClass
                    case .timeline: timeline
                    case .map: CheatSheetMap(buildings: allBuildings.filter(matches))
                    }
                }
            }
            .background(Theme.paper)
            .navigationTitle("Cheat Sheet")
            .searchable(text: $search, prompt: "Building, architect, year, style")
            .safeAreaInset(edge: .top) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Show", selection: $filter) {
                            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Google Docs (.docx with photos)", systemImage: "doc.text") { export(.docx) }
                        Button("PDF for printing", systemImage: "printer") { export(.pdf) }
                    } label: {
                        if exporting { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                    }
                    .disabled(allBuildings.isEmpty || exporting)
                    .accessibilityLabel("Export cheat sheet")
                }
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(url: file.url)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: By class

    private var byClass: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: [.sectionHeaders]) {
                ForEach(Array(lectures.enumerated()), id: \.element.id) { index, lecture in
                    let buildings = lecture.sortedBuildings.filter(matches)
                    if !buildings.isEmpty {
                        Section {
                            ForEach(buildings) { building in
                                NavigationLink { BuildingDetailView(building: building) } label: {
                                    CheatCard(building: building)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            DayHeader(day: index + 1, lecture: lecture, count: buildings.count)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        let sorted = allBuildings.filter(matches).sorted { ($0.yearSort == 0 ? 9999 : $0.yearSort) < ($1.yearSort == 0 ? 9999 : $1.yearSort) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, building in
                    NavigationLink { BuildingDetailView(building: building) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 0) {
                                Text(building.yearSort == 0 ? "?" : String(building.yearSort))
                                    .font(.system(.headline, design: .serif).monospacedDigit())
                                    .foregroundStyle(Theme.brick)
                                    .frame(width: 58)
                                Rectangle()
                                    .fill(Theme.brick.opacity(0.25))
                                    .frame(width: 2)
                                    .frame(maxHeight: .infinity)
                                    .opacity(index == sorted.count - 1 ? 0 : 1)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(building.name).font(.headline)
                                Text(building.architectDisplay).font(.subheadline).foregroundStyle(.secondary)
                                if !building.style.isEmpty { Pill(text: building.style, color: Theme.sage) }
                            }
                            .padding(.bottom, 22)
                            Spacer()
                            if let photo = building.sortedPhotos.first {
                                PhotoThumb(fileName: photo.fileName, maxPixel: 200)
                                    .frame(width: 54, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    // MARK: Export

    private func export(_ format: ExportFormat) {
        exporting = true
        Task { @MainActor in
            let url = switch format {
            case .pdf: CheatSheetExporter.makePDF(lectures: lectures)
            case .docx: DocxExporter.makeDocx(lectures: lectures, courseName: AppSettings.shared.courseName)
            }
            exporting = false
            if let url { exportFile = ExportFile(url: url) }
        }
    }
}

struct DayHeader: View {
    let day: Int
    let lecture: Lecture
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DAY \(day) · \(lecture.date.formatted(.dateTime.weekday(.abbreviated).month().day()))")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.brick)
                Text(lecture.displayTitle).font(.serifHeadline(18))
            }
            Spacer()
            Text("\(count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
    }
}

/// Compact exam card: photo, name, architect, year, style, key facts and one piece of trivia.
struct CheatCard: View {
    let building: Building
    var printMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                let photos = building.sortedPhotos
                if let first = photos.first {
                    PhotoThumb(fileName: first.fileName, maxPixel: 400)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            if photos.count > 1 {
                                Text("+\(photos.count - 1)")
                                    .font(.caption2.weight(.bold))
                                    .padding(4)
                                    .background(.black.opacity(0.6), in: Capsule())
                                    .foregroundStyle(.white)
                                    .padding(4)
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(building.name).font(.serifHeadline(18)).fixedSize(horizontal: false, vertical: true)
                        if building.isStarred { Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.gold) }
                    }
                    Label(building.architectDisplay, systemImage: "person.fill").font(.subheadline.weight(.semibold))
                    Label(building.yearDisplay, systemImage: "calendar").font(.subheadline.weight(.semibold))
                    if !building.style.isEmpty {
                        Text(building.style).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if building.importance == .high {
                    Image(systemName: "flame.fill").foregroundStyle(Theme.recordRed)
                }
            }

            if !building.keyFacts.isEmpty {
                BulletList(items: Array(building.keyFacts.prefix(printMode ? 6 : 3)))
                    .font(.subheadline)
            }
            if let trivia = building.trivia.first {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.gold)
                    RichText(trivia).font(.caption).foregroundStyle(.secondary)
                }
            }
            if printMode, !building.userNotes.isEmpty {
                Text("My notes: \(building.userNotes)").font(.caption).italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

// MARK: - Map

struct CheatSheetMap: View {
    let buildings: [Building]
    @State private var selection: Building?

    private struct Pin: Identifiable {
        let building: Building
        let coordinate: CLLocationCoordinate2D
        var id: UUID { building.id }
    }

    private var located: [Pin] {
        buildings.compactMap { b in
            b.coordinate.map { Pin(building: b, coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
        }
    }

    var body: some View {
        Map(selection: $selection) {
            ForEach(located) { pin in
                Marker(pin.building.name, systemImage: "building.columns.fill", coordinate: pin.coordinate)
                    .tint(Theme.importanceColor(pin.building.importance))
                    .tag(pin.building)
            }
        }
        .overlay(alignment: .top) {
            if located.isEmpty {
                Text("Buildings appear here once they have a location (from Claude or your photos' GPS).")
                    .font(.caption)
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let selection {
                NavigationLink { BuildingDetailView(building: selection) } label: {
                    CheatCard(building: selection)
                }
                .buttonStyle(.plain)
                .padding()
            }
        }
    }
}

/// System share sheet. For the .docx, choose "Google Docs" (or "Drive") to open it as a Google Doc.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
