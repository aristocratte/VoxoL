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

    /// Rich runs, real Word lists and links exported from the same document used by the editor.
    public static func data(
        document: MeetingDocument, transcript: SpeakerTranscript? = nil,
        includeSources: Bool = true
    ) -> Data {
        var relationships = [
            "<Relationship Id=\"styles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>",
            "<Relationship Id=\"numbering\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>",
        ]
        var body =
            "<w:p><w:pPr><w:pStyle w:val=\"Title\"/></w:pPr><w:r><w:t>\(xml(document.title))</w:t></w:r></w:p>"
        var numberedGroup = 1
        var wasNumbered = false
        var numberDefinitions = [String]()
        for block in document.blocks {
            if block.kind == .numbered && !wasNumbered {
                numberedGroup += 1
                numberDefinitions.append(
                    "<w:num w:numId=\"\(numberedGroup)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
                )
            }
            wasNumbered = block.kind == .numbered
            let style =
                block.kind == .heading
                ? "Heading1" : block.kind == .subheading ? "Heading2" : "Normal"
            let list =
                block.kind == .bullet || block.kind == .numbered
                ? "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(block.kind == .bullet ? 1 : numberedGroup)\"/></w:numPr>"
                : ""
            body += "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/>\(list)</w:pPr>"
            if block.kind == .task { body += "<w:r><w:t>\(block.checked ? "☑" : "☐") </w:t></w:r>" }
            if block.kind == .quote { body += "<w:r><w:t>› </w:t></w:r>" }
            for run in block.runs {
                let properties =
                    (run.bold ? "<w:b/>" : "") + (run.italic ? "<w:i/>" : "")
                    + (run.highlighted ? "<w:highlight w:val=\"yellow\"/>" : "")
                var value =
                    "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(xml(run.text))</w:t></w:r>"
                if let link = run.link, run.safeURL != nil {
                    let id = "link\(relationships.count)"
                    relationships.append(
                        "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xml(link))\" TargetMode=\"External\"/>"
                    )
                    value = "<w:hyperlink r:id=\"\(id)\">\(value)</w:hyperlink>"
                }
                body += value
            }
            body += "</w:p>"
            if includeSources, let transcript, !block.sourceTurnIDs.isEmpty {
                let sources = block.sourceTurnIDs.compactMap { id in
                    transcript.turns.first { $0.id == id }.map {
                        SpeakerTranscript.timestamp($0.start)
                    }
                }.joined(separator: " · ")
                body +=
                    "<w:p><w:r><w:rPr><w:i/><w:sz w:val=\"18\"/><w:color w:val=\"777777\"/></w:rPr><w:t>Sources : \(xml(sources))</w:t></w:r></w:p>"
            }
        }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let word =
            header
            + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body>\(body)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1200\" w:right=\"1250\" w:bottom=\"1200\" w:left=\"1250\"/></w:sectPr></w:body></w:document>"
        let styles =
            header + """
                <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>
                <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:pPr><w:spacing w:after="160" w:line="300" w:lineRule="auto"/><w:widowControl/></w:pPr></w:style>
                <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:pPr><w:keepNext/><w:spacing w:after="340"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>
                <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="0"/><w:spacing w:before="320" w:after="160"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>
                <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="1"/><w:spacing w:before="220"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>
                </w:styles>
                """
        let numbering =
            header + """
                <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:pPr><w:ind w:left="480" w:hanging="240"/></w:pPr></w:lvl></w:abstractNum>
                <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="480" w:hanging="240"/></w:pPr></w:lvl></w:abstractNum>
                <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>\(numberDefinitions.joined())
                </w:numbering>
                """
        let types =
            header + """
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/></Types>
                """
        let root =
            header
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"document\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        let rels =
            header
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships.joined())</Relationships>"
        return storedZIP([
            ("[Content_Types].xml", Data(types.utf8)), ("_rels/.rels", Data(root.utf8)),
            ("word/document.xml", Data(word.utf8)), ("word/styles.xml", Data(styles.utf8)),
            ("word/numbering.xml", Data(numbering.utf8)),
            ("word/_rels/document.xml.rels", Data(rels.utf8)),
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
