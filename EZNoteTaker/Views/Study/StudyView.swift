import SwiftData
import SwiftUI

/// Exam practice built from the cheat sheet: flashcards (photo → name, architect, year) and a quiz.
struct StudyView: View {
    @Query(sort: \Lecture.date) private var lectures: [Lecture]
    @Query private var buildings: [Building]
    @State private var deck: DeckChoice = .all

    enum DeckChoice: Hashable {
        case all, likely, weak, starred
        case lecture(UUID)
    }

    private var deckBuildings: [Building] {
        switch deck {
        case .all: buildings
        case .likely: buildings.filter { $0.importance == .high }
        case .weak: buildings.filter { $0.studyMissed > 0 }
        case .starred: buildings.filter(\.isStarred)
        case .lecture(let id): buildings.filter { $0.lecture?.id == id }
        }
    }

    private var mastered: Int { buildings.filter { $0.studyCorrect > 0 && $0.masteryScore > 0 }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    progressCard

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: "Deck", systemImage: "rectangle.stack")
                        Picker("Deck", selection: $deck) {
                            Text("All buildings (\(buildings.count))").tag(DeckChoice.all)
                            Text("Likely on exam").tag(DeckChoice.likely)
                            Text("Need practice").tag(DeckChoice.weak)
                            Text("Starred").tag(DeckChoice.starred)
                            ForEach(Array(lectures.enumerated()), id: \.element.id) { index, lecture in
                                Text("Day \(index + 1): \(lecture.displayTitle)").tag(DeckChoice.lecture(lecture.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .card()

                    NavigationLink {
                        FlashcardsView(buildings: deckBuildings)
                    } label: {
                        ModeCard(title: "Flashcards", subtitle: "See the photo, recall the name, architect and year. Weakest cards come first.",
                                 systemImage: "rectangle.on.rectangle.angled", color: Theme.brick)
                    }
                    .disabled(deckBuildings.isEmpty)

                    NavigationLink {
                        QuizView(pool: deckBuildings, all: buildings)
                    } label: {
                        ModeCard(title: "Exam Quiz", subtitle: "Multiple-choice questions just like the final: who designed it, when was it built, which building is this?",
                                 systemImage: "checklist", color: Theme.sage)
                    }
                    .disabled(deckBuildings.isEmpty || buildings.count < 2)

                    if buildings.isEmpty {
                        Text("Record a class first — study decks are built from the buildings in your cheat sheet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .background(Theme.paper)
            .navigationTitle("Study")
        }
    }

    private var progressCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(Theme.brick.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: buildings.isEmpty ? 0 : Double(mastered) / Double(buildings.count))
                    .stroke(Theme.brick, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(buildings.isEmpty ? "–" : "\(Int(Double(mastered) / Double(buildings.count) * 100))%")
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 4) {
                Text("Exam readiness").font(.serifHeadline())
                Text("\(mastered) of \(buildings.count) buildings mastered").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .card()
    }
}

private struct ModeCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .card()
    }
}

// MARK: - Flashcards

struct FlashcardsView: View {
    let buildings: [Building]
    @Environment(\.modelContext) private var context
    @State private var order: [Building] = []
    @State private var index = 0
    @State private var flipped = false
    @State private var correct = 0

    var body: some View {
        VStack(spacing: 20) {
            if index < order.count {
                let building = order[index]
                ProgressView(value: Double(index), total: Double(order.count))
                Text("\(index + 1) of \(order.count)").font(.caption).foregroundStyle(.secondary)

                ZStack {
                    front(building).opacity(flipped ? 0 : 1)
                    back(building).opacity(flipped ? 1 : 0).rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                }
                .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                .onTapGesture { withAnimation(.spring(duration: 0.45)) { flipped.toggle() } }

                if flipped {
                    HStack(spacing: 12) {
                        Button { grade(building, knew: false) } label: {
                            Label("Missed it", systemImage: "xmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(Theme.recordRed)
                        Button { grade(building, knew: true) } label: {
                            Label("Knew it", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.sage)
                    }
                    .controlSize(.large)
                } else {
                    Text("Tap the card to reveal").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if !order.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "trophy.fill").font(.system(size: 56)).foregroundStyle(Theme.gold)
                    Text("Deck complete").font(.serifTitle())
                    Text("You knew \(correct) of \(order.count).").foregroundStyle(.secondary)
                    Button("Study again") { restart() }.buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(Theme.paper)
        .navigationTitle("Flashcards")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if order.isEmpty { restart() } }
    }

    private func front(_ b: Building) -> some View {
        VStack(spacing: 14) {
            if let photo = b.sortedPhotos.randomElement() {
                PhotoThumb(fileName: photo.fileName, maxPixel: 1000)
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("Name · Architect · Year?").font(.serifHeadline())
            } else {
                Spacer()
                Text(b.name).font(.serifTitle(30)).multilineTextAlignment(.center)
                Text("Who designed it, and when?").font(.headline).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 400)
        .card()
    }

    private func back(_ b: Building) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(b.name).font(.serifTitle(26))
            FactBox(label: "Architect", value: b.architectDisplay, systemImage: "person.fill")
            FactBox(label: "Built", value: b.yearDisplay, systemImage: "calendar")
            if !b.style.isEmpty { FactBox(label: "Style", value: b.style, systemImage: "paintbrush") }
            if let fact = b.keyFacts.first { RichText(fact).font(.subheadline) }
            if let trivia = b.trivia.first {
                Label { RichText(trivia).font(.caption) } icon: { Image(systemName: "sparkles").foregroundStyle(Theme.gold) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
        .card()
    }

    private func grade(_ b: Building, knew: Bool) {
        if knew { b.studyCorrect += 1; correct += 1 } else { b.studyMissed += 1 }
        try? context.save()
        Haptics.light()
        flipped = false
        withAnimation(.snappy) { index += 1 }
    }

    private func restart() {
        // Weakest first, shuffled within equal scores.
        order = buildings.shuffled().sorted { $0.masteryScore < $1.masteryScore }
        index = 0
        correct = 0
        flipped = false
    }
}

// MARK: - Quiz

struct QuizView: View {
    let pool: [Building]
    let all: [Building]
    @Environment(\.modelContext) private var context
    @State private var questions: [Question] = []
    @State private var index = 0
    @State private var picked: String?
    @State private var score = 0

    struct Question: Identifiable {
        let id = UUID()
        let building: Building
        let prompt: String
        let photoFile: String?
        let answer: String
        let options: [String]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if index < questions.count {
                let q = questions[index]
                ProgressView(value: Double(index), total: Double(questions.count))
                Text("Question \(index + 1) of \(questions.count) · Score \(score)")
                    .font(.caption).foregroundStyle(.secondary)
                if let file = q.photoFile {
                    PhotoThumb(fileName: file, maxPixel: 1000)
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                Text(q.prompt).font(.serifHeadline(21))
                ForEach(q.options, id: \.self) { option in
                    Button { choose(option, for: q) } label: {
                        HStack {
                            Text(option).multilineTextAlignment(.leading)
                            Spacer()
                            if picked != nil && option == q.answer { Image(systemName: "checkmark.circle.fill") }
                            else if picked == option { Image(systemName: "xmark.circle.fill") }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: option, q), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(picked != nil)
                }
                if picked != nil {
                    Button(index + 1 == questions.count ? "See results" : "Next question") {
                        picked = nil
                        withAnimation(.snappy) { index += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            } else if !questions.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: score * 10 >= questions.count * 8 ? "star.circle.fill" : "graduationcap.circle.fill")
                        .font(.system(size: 60)).foregroundStyle(Theme.gold)
                    Text("\(score) / \(questions.count)").font(.serifTitle(40))
                    Text(score == questions.count ? "Perfect — you're ready!" : "Missed ones were added to “Need practice”.")
                        .foregroundStyle(.secondary)
                    Button("New quiz") { build() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(Theme.paper)
        .navigationTitle("Exam Quiz")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if questions.isEmpty { build() } }
    }

    private func background(for option: String, _ q: Question) -> Color {
        guard picked != nil else { return Theme.card }
        if option == q.answer { return Theme.sage.opacity(0.25) }
        if option == picked { return Theme.recordRed.opacity(0.2) }
        return Theme.card
    }

    private func choose(_ option: String, for q: Question) {
        picked = option
        if option == q.answer {
            score += 1
            q.building.studyCorrect += 1
            Haptics.success()
        } else {
            q.building.studyMissed += 1
            Haptics.error()
        }
        try? context.save()
    }

    private func build() {
        var result: [Question] = []
        for b in pool.shuffled().prefix(15) {
            var kinds: [Int] = []
            if !b.architect.isEmpty { kinds.append(0) }
            if !b.yearBuilt.isEmpty { kinds.append(1) }
            if !b.photos.isEmpty { kinds.append(2) }
            if !b.architect.isEmpty { kinds.append(3) }
            guard let kind = kinds.randomElement() else { continue }

            switch kind {
            case 0:
                result.append(make(b, "Who designed \(b.name)?", answer: b.architect, others: all.map(\.architect)))
            case 1:
                result.append(make(b, "When was \(b.name) built?", answer: b.yearBuilt,
                                   others: all.map(\.yearBuilt) + Self.nearbyYears(b.yearSort)))
            case 2:
                result.append(make(b, "Which building is this?", answer: b.name, others: all.map(\.name),
                                   photo: b.sortedPhotos.randomElement()?.fileName))
            default:
                result.append(make(b, "Which building was designed by \(b.architect)?", answer: b.name,
                                   others: all.filter { $0.architect != b.architect }.map(\.name)))
            }
        }
        questions = result.filter { $0.options.count >= 2 }
        index = 0
        score = 0
        picked = nil
    }

    private func make(_ b: Building, _ prompt: String, answer: String, others: [String], photo: String? = nil) -> Question {
        let distractors = Array(Set(others.filter { !$0.isEmpty && $0 != answer })).shuffled().prefix(3)
        return Question(building: b, prompt: prompt, photoFile: photo, answer: answer,
                        options: (Array(distractors) + [answer]).shuffled())
    }

    private static func nearbyYears(_ year: Int) -> [String] {
        guard year > 0 else { return [] }
        return [-12, -5, 7, 15].map { String(year + $0) }
    }
}
