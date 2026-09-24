import Foundation

/// Exports the editable meeting report as a self-contained Word document.
public enum MeetingWordDocument {
    /// Creates a DOCX archive containing the current Markdown, including user edits.
    public static func data(markdown: String) -> Data {
        let body = markdown.components(separatedBy: .newlines).compactMap(paragraph).joined()
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1200" w:right="1250" w:bottom="1200" w:left="1250"/></w:sectPr></w:body></w:document>
            """
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:sz w:val="22"/><w:color w:val="171713"/></w:rPr></w:rPrDefault></w:docDefaults>
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:pPr><w:spacing w:after="140" w:line="340" w:lineRule="auto"/></w:pPr></w:style>
            <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:pPr><w:spacing w:before="0" w:after="360"/></w:pPr><w:rPr><w:b/><w:sz w:val="38"/><w:color w:val="171713"/></w:rPr></w:style>
            <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="420" w:after="180"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:color w:val="2449F8"/></w:rPr></w:style>
            <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="130"/></w:pPr><w:rPr><w:b/><w:sz w:val="23"/></w:rPr></w:style>
            </w:styles>
            """
        let types = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
            """
        let rootRelationships = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """
        let wordRelationships = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """
        return storedZIP([
            ("[Content_Types].xml", Data(types.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("word/_rels/document.xml.rels", Data(wordRelationships.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
        ])
    }

    private static func paragraph(_ rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let style: String
        let content: String
        if line.hasPrefix("# ") {
            style = "Title"; content = String(line.dropFirst(2))
        } else if line.hasPrefix("## ") {
            style = "Heading1"; content = String(line.dropFirst(3))
        } else if line.hasPrefix("### ") {
            style = "Heading2"; content = String(line.dropFirst(4))
        } else if line.hasPrefix("- [ ] ") {
            style = "Normal"; content = "☐  " + line.dropFirst(6)
        } else if line.hasPrefix("- ") {
            style = "Normal"; content = "•  " + line.dropFirst(2)
        } else {
            style = "Normal"; content = line
        }
        let italic = content.hasPrefix("_") && content.hasSuffix("_") && content.count > 2
        let formatted = italic ? String(content.dropFirst().dropLast()) : content
        let runs = formatted.components(separatedBy: "**").enumerated().map { index, part in
            let properties = "\(index.isMultiple(of: 2) ? "" : "<w:b/>")\(italic ? "<w:i/>" : "")"
            return
                "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(xml(part))</w:t></w:r>"
        }.joined()
        return "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(runs)</w:p>"
    }

    private static func xml(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func storedZIP(_ entries: [(String, Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        for (name, bytes) in entries {
            let filename = Data(name.utf8)
            let checksum = crc32(bytes)
            let offset = UInt32(archive.count)
            archive.appendLE(UInt32(0x04034B50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(checksum)
            archive.appendLE(UInt32(bytes.count))
            archive.appendLE(UInt32(bytes.count))
            archive.appendLE(UInt16(filename.count))
            archive.appendLE(UInt16(0))
            archive.append(filename)
            archive.append(bytes)

            directory.appendLE(UInt32(0x02014B50))
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(checksum)
            directory.appendLE(UInt32(bytes.count))
            directory.appendLE(UInt32(bytes.count))
            directory.appendLE(UInt16(filename.count))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt32(0))
            directory.appendLE(offset)
            directory.append(filename)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.appendLE(UInt32(0x06054B50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(directory.count))
        archive.appendLE(directoryOffset)
        archive.appendLE(UInt16(0))
        return archive
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
        }
        return value ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
