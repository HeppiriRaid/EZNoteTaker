import SwiftUI
import UIKit

/// Builds a printable, multi-page PDF of the cheat sheet (letter size), one section per class week.
@MainActor
enum CheatSheetExporter {
    static func makePDF(lectures: [Lecture]) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 36
        let width = page.width - margin * 2

        var blocks: [AnyView] = [AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text(AppSettings.shared.courseName).font(.serifTitle(26))
                Text("Exam cheat sheet · \(Date().formatted(date: .long, time: .omitted))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )]
        for day in ClassWeek.group(lectures) where !day.entries.isEmpty {
            blocks.append(AnyView(DayHeader(day: day, count: day.entries.count)))
            for entry in day.entries {
                blocks.append(AnyView(CheatCard(building: entry.building, printMode: true)))
            }
        }

        let images: [UIImage] = blocks.compactMap { block in
            let renderer = ImageRenderer(content: block
                .frame(width: width)
                .environment(\.colorScheme, .light)
                .background(Color.white))
            renderer.scale = 2
            return renderer.uiImage
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Architecture Cheat Sheet.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        do {
            try renderer.writePDF(to: url) { context in
                var y = page.height
                for image in images {
                    let height = min(image.size.height, page.height - margin * 2)
                    if y + height > page.height - margin {
                        context.beginPage()
                        y = margin
                    }
                    image.draw(in: CGRect(x: margin, y: y, width: width, height: height))
                    y += height + 10
                }
            }
            return url
        } catch {
            return nil
        }
    }
}

/// Plain-text version of a lecture's notes for sharing (Messages, Notes, email…).
enum ShareText {
    @MainActor
    static func lecture(_ lecture: Lecture) -> String {
        var text = "\(lecture.displayTitle)\n\(lecture.date.formatted(date: .long, time: .shortened))\n\n"
        if !lecture.overview.isEmpty { text += strip(lecture.overview) + "\n\n" }
        for b in lecture.sortedBuildings {
            text += "■ \(b.name) — \(b.architectDisplay), \(b.yearDisplay)\n"
            for fact in b.keyFacts { text += "  • \(strip(fact))\n" }
            for t in b.trivia { text += "  ✦ \(strip(t))\n" }
            text += "\n"
        }
        if !lecture.keyTakeaways.isEmpty {
            text += "Key takeaways\n" + lecture.keyTakeaways.map { "• \(strip($0))" }.joined(separator: "\n") + "\n"
        }
        return text
    }

    private static func strip(_ s: String) -> String { s.replacingOccurrences(of: "**", with: "") }
}
