import Foundation
import UIKit

/// Exports the cheat sheet as a Word document (.docx) with photos. Google Docs opens .docx natively:
/// share it to the Google Docs or Google Drive app and it becomes an editable Google Doc.
@MainActor
enum DocxExporter {
    private struct Media {
        let relID: String
        let fileName: String
        let data: Data
    }

    static func makeDocx(lectures: [Lecture], courseName: String) -> URL? {
        var body = ""
        var media: [Media] = []
        var drawingID = 1

        func paragraph(_ text: String, style: String? = nil, bold: Bool = false, italic: Bool = false, size: Int? = nil, color: String? = nil) {
            var pPr = ""
            if let style { pPr = "<w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>" }
            body += "<w:p>\(pPr)\(runs(text, bold: bold, italic: italic, size: size, color: color))</w:p>"
        }

        func image(_ fileName: String) {
            guard let original = ImageCache.shared.full(for: fileName),
                  let jpeg = original.resized(maxPixel: 1200).jpegData(compressionQuality: 0.75) else { return }
            let relID = "rIdImg\(media.count + 1)"
            let name = "image\(media.count + 1).jpeg"
            media.append(Media(relID: relID, fileName: name, data: jpeg))
            let widthEMU = 2_743_200 // 3 inches
            let aspect = original.size.width > 0 ? original.size.height / original.size.width : 0.75
            let heightEMU = Int(Double(widthEMU) * aspect)
            body += "<w:p><w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
            body += "<wp:extent cx=\"\(widthEMU)\" cy=\"\(heightEMU)\"/><wp:docPr id=\"\(drawingID)\" name=\"Picture \(drawingID)\"/>"
            body += "<a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">"
            body += "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            body += "<pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            body += "<pic:nvPicPr><pic:cNvPr id=\"\(drawingID)\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            body += "<pic:blipFill><a:blip r:embed=\"\(relID)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            body += "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(widthEMU)\" cy=\"\(heightEMU)\"/></a:xfrm>"
            body += "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>"
            body += "</wp:inline></w:drawing></w:r></w:p>"
            drawingID += 1
        }

        paragraph(courseName.isEmpty ? "Architecture History" : courseName, style: "Title")
        paragraph("Exam cheat sheet · \(Date().formatted(date: .long, time: .omitted))", italic: true, color: "777777")

        for day in ClassWeek.group(lectures) where !day.entries.isEmpty {
            paragraph("Week \(day.number) — \(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.title)", style: "Heading1")
            if !day.overview.isEmpty { paragraph(day.overview, italic: true) }

            for building in day.entries.map(\.building) {
                paragraph(building.name + (building.importance == .high ? "  ★ likely on exam" : ""), style: "Heading2")
                paragraph("Architect: \(building.architectDisplay)", bold: true)
                paragraph("Built: \(building.yearDisplay)", bold: true)
                if !building.style.isEmpty { paragraph("Style: \(building.style)") }
                if !building.location.isEmpty { paragraph("Location: \(building.location)") }
                for photo in building.sortedPhotos.prefix(2) { image(photo.fileName) }
                if !building.significance.isEmpty { paragraph(building.significance) }
                if !building.keyFacts.isEmpty {
                    paragraph("Key facts", bold: true, color: "B8583C")
                    building.keyFacts.forEach { paragraph("•  " + $0) }
                }
                if !building.professorEmphasis.isEmpty {
                    paragraph("Professor emphasized", bold: true, color: "B8583C")
                    building.professorEmphasis.forEach { paragraph("•  " + $0) }
                }
                if !building.trivia.isEmpty {
                    paragraph("Stories & trivia", bold: true, color: "B8583C")
                    building.trivia.forEach { paragraph("✦  " + $0) }
                }
                if !building.userNotes.isEmpty { paragraph("My notes: \(building.userNotes)", italic: true) }
            }
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">\
        <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
        <w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>\
        </w:body></w:document>
        """

        var documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        for m in media {
            documentRels += "<Relationship Id=\"\(m.relID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(m.fileName)\"/>"
        }
        documentRels += "</Relationships>"

        var files: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
            ("word/_rels/document.xml.rels", Data(documentRels.utf8)),
        ]
        files += media.map { ("word/media/\($0.fileName)", $0.data) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Architecture Cheat Sheet.docx")
        do {
            try ZipWriter.archive(files).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Converts "**bold** text" into Word runs, escaping XML.
    private static func runs(_ text: String, bold: Bool, italic: Bool, size: Int?, color: String?) -> String {
        var xml = ""
        for (i, piece) in text.components(separatedBy: "**").enumerated() where !piece.isEmpty {
            var rPr = ""
            if bold || i % 2 == 1 { rPr += "<w:b/>" }
            if italic { rPr += "<w:i/>" }
            if let color { rPr += "<w:color w:val=\"\(color)\"/>" }
            if let size { rPr += "<w:sz w:val=\"\(size * 2)\"/>" }
            xml += "<w:r>\(rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>")<w:t xml:space=\"preserve\">\(escape(piece))</w:t></w:r>"
        }
        return xml
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Default Extension="jpeg" ContentType="image/jpeg"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    </Types>
    """

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    </Relationships>
    """

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="80"/></w:pPr></w:pPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>\
    <w:rPr><w:b/><w:sz w:val="48"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>\
    <w:rPr><w:b/><w:color w:val="B8583C"/><w:sz w:val="34"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr>\
    <w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>\
    </w:styles>
    """
}

/// Minimal ZIP writer (stored, no compression) — enough for .docx packages.
enum ZipWriter {
    static func archive(_ files: [(String, Data)]) -> Data {
        var output = Data()
        var central = Data()

        for (name, data) in files {
            let nameData = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(output.count)

            output.append(le32(0x0403_4B50))      // local file header signature
            output.append(le16(20))               // version needed
            output.append(le16(0x0800))           // flags: UTF-8 names
            output.append(le16(0))                // method: stored
            output.append(le16(0)); output.append(le16(0x21)) // mod time / date (1980-01-01)
            output.append(le32(crc))
            output.append(le32(UInt32(data.count)))
            output.append(le32(UInt32(data.count)))
            output.append(le16(UInt16(nameData.count)))
            output.append(le16(0))                // extra length
            output.append(nameData)
            output.append(data)

            central.append(le32(0x0201_4B50))     // central directory signature
            central.append(le16(20)); central.append(le16(20))
            central.append(le16(0x0800)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0x21))
            central.append(le32(crc))
            central.append(le32(UInt32(data.count)))
            central.append(le32(UInt32(data.count)))
            central.append(le16(UInt16(nameData.count)))
            central.append(le16(0)); central.append(le16(0)) // extra, comment
            central.append(le16(0)); central.append(le16(0)) // disk, internal attrs
            central.append(le32(0))               // external attrs
            central.append(le32(offset))
            central.append(nameData)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(le32(0x0605_4B50))          // end of central directory
        output.append(le16(0)); output.append(le16(0))
        output.append(le16(UInt16(files.count))); output.append(le16(UInt16(files.count)))
        output.append(le32(UInt32(central.count)))
        output.append(le32(centralOffset))
        output.append(le16(0))
        return output
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
