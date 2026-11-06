import AppKit
import Observation
import SpeakerKit
import SwiftUI

private extension NSAttributedString.Key {
    static let meetingBlock = Self("VoxoLMeetingBlock")
    static let meetingKind = Self("VoxoLMeetingKind")
    static let meetingBold = Self("VoxoLMeetingBold")
    static let meetingItalic = Self("VoxoLMeetingItalic")
    static let meetingHighlight = Self("VoxoLMeetingHighlight")
    static let meetingChecked = Self("VoxoLMeetingChecked")
    static let meetingSources = Self("VoxoLMeetingSources")
    static let meetingSourceText = Self("VoxoLMeetingSourceText")
    static let meetingNeedsReview = Self("VoxoLMeetingNeedsReview")
}

@MainActor
enum MeetingAttributedDocument {
    static func attributes(
        kind: MeetingDocumentBlock.Kind, run: MeetingTextRun = .init(""),
        printing: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        let size: CGFloat =
            printing
            ? (kind == .heading ? 23 : kind == .subheading ? 18 : 15)
            : (kind == .heading ? 19 : 16)
        let weight: NSFont.Weight =
            run.bold || kind == .heading || kind == .subheading ? .semibold : .regular
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        // On screen the report is set in New York, like the reading view it switches from.
        if !printing, let serif = font.fontDescriptor.withDesign(.serif) {
            font = NSFont(descriptor: serif, size: size) ?? font
        }
        if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = kind == .heading ? 12 : 16
        style.paragraphSpacingBefore = kind == .heading ? 18 : kind == .subheading ? 10 : 0
        if [.bullet, .numbered, .task, .quote].contains(kind) {
            style.headIndent = 24
            style.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
        }
        var value: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: printing ? NSColor.black : NSColor.labelColor,
            .paragraphStyle: style, .meetingKind: kind.rawValue,
            .meetingBold: run.bold, .meetingItalic: run.italic, .meetingHighlight: run.highlighted,
        ]
        if kind == .quote {
            value[.foregroundColor] = printing ? NSColor.darkGray : NSColor.secondaryLabelColor
        }
        if run.highlighted {
            value[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(
                printing ? 0.35 : 0.22)
        }
        if let url = run.safeURL {
            value[.link] = url
        }
        return value
    }

    static func prefix(_ kind: MeetingDocumentBlock.Kind, number: Int = 1, checked: Bool = false)
        -> String
    {
        switch kind {
        case .bullet: "•\t"
        case .numbered: "\(number).\t"
        case .task: checked ? "☑\t" : "☐\t"
        case .quote: "›\t"
        default: ""
        }
    }

    static func render(_ document: MeetingDocument, printing: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var number = 0
        for block in document.blocks {
            number = block.kind == .numbered ? number + 1 : 0
            let start = result.length
            result.append(
                NSAttributedString(
                    string: prefix(block.kind, number: number, checked: block.checked),
                    attributes: attributes(kind: block.kind, printing: printing)))
            for run in block.runs {
                result.append(
                    NSAttributedString(
                        string: run.text,
                        attributes: attributes(kind: block.kind, run: run, printing: printing)))
            }
            result.append(
                NSAttributedString(
                    string: "\n", attributes: attributes(kind: block.kind, printing: printing)))
            result.addAttributes(
                [
                    .meetingBlock: block.id.uuidString, .meetingKind: block.kind.rawValue,
                    .meetingChecked: block.checked, .meetingSources: block.sourceTurnIDs,
                    .meetingSourceText: block.text, .meetingNeedsReview: block.sourcesNeedReview,
                ],
                range: NSRange(location: start, length: result.length - start))
        }
        return result
    }

    static func document(from value: NSAttributedString, previous: MeetingDocument)
        -> MeetingDocument
    {
        var result = previous
        result.blocks = []
        let string = value.string as NSString
        var location = 0
        var used = Set<UUID>()
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            let attrs = value.attributes(at: location, effectiveRange: nil)
            let inherited = (attrs[.meetingBlock] as? String).flatMap(UUID.init(uuidString:))
            let id = inherited.flatMap { used.contains($0) ? nil : $0 } ?? UUID()
            used.insert(id)
            let old = previous.blocks.first { $0.id == inherited }
            let kind =
                (attrs[.meetingKind] as? String).flatMap(MeetingDocumentBlock.Kind.init(rawValue:))
                ?? .paragraph
            let checked = attrs[.meetingChecked] as? Bool ?? false
            var range = paragraph
            while range.length > 0, [10, 13].contains(string.character(at: NSMaxRange(range) - 1)) {
                range.length -= 1
            }
            let text = string.substring(with: range)
            let prefix = prefix(kind, checked: checked)
            if !prefix.isEmpty {
                if kind == .numbered,
                    let match = text.range(of: #"^\d+\.\t"#, options: .regularExpression)
                {
                    let length = (String(text[match]) as NSString).length
                    range.location += length; range.length -= length
                } else if text.hasPrefix(prefix) {
                    range.location += (prefix as NSString).length;
                    range.length -= (prefix as NSString).length
                }
            }
            var runs = [MeetingTextRun]()
            value.enumerateAttributes(in: range) { attributes, subrange, _ in
                let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 15)
                let traits = NSFontManager.shared.traits(of: font)
                runs.append(
                    MeetingTextRun(
                        string.substring(with: subrange),
                        bold: attributes[.meetingBold] as? Bool ?? traits.contains(.boldFontMask),
                        italic: attributes[.meetingItalic] as? Bool
                            ?? traits.contains(.italicFontMask),
                        highlighted: attributes[.meetingHighlight] as? Bool
                            ?? (attributes[.backgroundColor] != nil),
                        link: (attributes[.link] as? URL)?.absoluteString ?? attributes[.link]
                            as? String))
            }
            if runs.isEmpty { runs = [.init("")] }
            let sourceIDs = old?.sourceTurnIDs ?? attrs[.meetingSources] as? [Int] ?? []
            let sourceText = old?.text ?? attrs[.meetingSourceText] as? String
            result.blocks.append(
                MeetingDocumentBlock(
                    id: id, kind: kind, runs: runs,
                    sourceTurnIDs: sourceIDs,
                    sourcesNeedReview: old?.sourcesNeedReview == true
                        || attrs[.meetingNeedsReview] as? Bool == true
                        || (!sourceIDs.isEmpty && sourceText != runs.map(\.text).joined()),
                    checked: checked))
            location = NSMaxRange(paragraph)
        }
        return result
    }

    static func exportDocument(
        _ content: MeetingDocument, transcript: SpeakerTranscript?, includeSources: Bool
    )
        -> MeetingDocument
    {
        var document = content
        var blocks = [MeetingDocumentBlock(kind: .heading, runs: [.init(content.title)])]
        if let transcript {
            blocks.append(
                .init(runs: [
                    .init(
                        transcript.occurredAt.formatted(date: .abbreviated, time: .shortened)
                            + " · " + SpeakerTranscript.timestamp(transcript.duration), italic: true
                    )
                ]))
        }
        for block in content.blocks {
            blocks.append(block)
            if includeSources, let transcript, !block.sourceTurnIDs.isEmpty {
                let text = block.sourceTurnIDs.compactMap { id in
                    transcript.turns.first { $0.id == id }.map {
                        SpeakerTranscript.timestamp($0.start)
                    }
                }.joined(separator: " · ")
                blocks.append(.init(runs: [.init("Sources : " + text, italic: true)]))
            }
        }
        document.blocks = blocks
        return document
    }
}

@MainActor @Observable
final class MeetingEditorController {
    weak var textView: NSTextView?
    private(set) var selectedBlock: UUID?
    private(set) var selectedText = ""
    private(set) var kind: MeetingDocumentBlock.Kind = .paragraph

    func selectionChanged() {
        guard let view = textView, let storage = view.textStorage, storage.length > 0 else {
            selectedBlock = nil; selectedText = ""; return
        }
        let selected = view.selectedRange()
        let attributes = storage.attributes(
            at: min(selected.location, storage.length - 1), effectiveRange: nil)
        selectedBlock = (attributes[.meetingBlock] as? String).flatMap(UUID.init(uuidString:))
        kind =
            (attributes[.meetingKind] as? String).flatMap(MeetingDocumentBlock.Kind.init(rawValue:))
            ?? .paragraph
        selectedText = (storage.string as NSString).substring(with: selected)
    }

    func scroll(to id: UUID) {
        guard let view = textView, let storage = view.textStorage else { return }
        storage.enumerateAttribute(.meetingBlock, in: NSRange(location: 0, length: storage.length))
        { value, range, stop in
            if value as? String == id.uuidString {
                view.scrollRangeToVisible(range);
                view.setSelectedRange(NSRange(location: range.location, length: 0))
                stop.pointee = true
            }
        }
        selectionChanged()
    }

    func toggle(_ mark: String) {
        guard let view = textView else { return }
        let key: NSAttributedString.Key =
            mark == "bold" ? .meetingBold : mark == "italic" ? .meetingItalic : .meetingHighlight
        let range = view.selectedRange()
        if range.length == 0 {
            var attributes = view.typingAttributes
            attributes[key] = !(attributes[key] as? Bool ?? false)
            view.typingAttributes = restyled(attributes)
            view.window?.makeFirstResponder(view)
            return
        }
        guard let storage = view.textStorage else { return }
        let content = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: range))
        let enabled = !(content.attribute(key, at: 0, effectiveRange: nil) as? Bool ?? false)
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) {
            attrs, part, _ in
            var attrs = attrs; attrs[key] = enabled
            content.setAttributes(restyled(attrs), range: part)
        }
        replace(content, range: range)
    }

    func setKind(_ kind: MeetingDocumentBlock.Kind) {
        guard let view = textView, let storage = view.textStorage else { return }
        if storage.length == 0 {
            view.typingAttributes = MeetingAttributedDocument.attributes(kind: kind)
            view.window?.makeFirstResponder(view)
            let prefix = MeetingAttributedDocument.prefix(kind)
            if !prefix.isEmpty { view.insertText(prefix, replacementRange: view.selectedRange()) }
            return
        }
        let range = (storage.string as NSString).paragraphRange(for: view.selectedRange())
        let content = storage.attributedSubstring(from: range)
        var document = MeetingAttributedDocument.document(
            from: content, previous: MeetingDocument(title: ""))
        for i in document.blocks.indices { document.blocks[i].kind = kind }
        replace(MeetingAttributedDocument.render(document), range: range)
    }

    func setLink(_ address: String) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        guard range.length > 0 else { return }
        let content = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: range))
        let all = NSRange(location: 0, length: content.length)
        if address.isEmpty {
            content.removeAttribute(.link, range: all)
        } else if let url = MeetingTextRun.safeURL(address) {
            content.addAttribute(.link, value: url, range: all)
        } else {
            return
        }
        replace(content, range: range)
    }

    func undo() { textView?.undoManager?.undo() }
    func redo() { textView?.undoManager?.redo() }

    private func replace(_ content: NSAttributedString, range: NSRange) {
        guard let view = textView else { return }
        view.window?.makeFirstResponder(view)
        view.insertText(content, replacementRange: range)
        view.setSelectedRange(NSRange(location: range.location, length: content.length))
        selectionChanged()
    }

    private func restyled(_ original: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key:
        Any]
    {
        var result = original
        let kind =
            (original[.meetingKind] as? String).flatMap(MeetingDocumentBlock.Kind.init(rawValue:))
            ?? .paragraph
        let run = MeetingTextRun(
            "", bold: original[.meetingBold] as? Bool ?? false,
            italic: original[.meetingItalic] as? Bool ?? false,
            highlighted: original[.meetingHighlight] as? Bool ?? false)
        result[.backgroundColor] = nil
        result.merge(MeetingAttributedDocument.attributes(kind: kind, run: run)) { _, new in new }
        return result
    }
}

struct MeetingRichEditor: NSViewRepresentable {
    @Binding var document: MeetingDocument
    let controller: MeetingEditorController
    var editable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = MeetingNativeTextView(frame: .zero)
        view.controller = controller
        view.isRichText = true
        view.isEditable = editable
        view.isSelectable = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.textContainerInset = NSSize(width: 36, height: 22)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(MeetingAttributedDocument.render(document))
        view.typingAttributes = MeetingAttributedDocument.attributes(kind: .paragraph)
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Meeting document")
        scroll.documentView = view
        controller.textView = view
        context.coordinator.lastValue = document
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = editable
        if context.coordinator.lastValue?.blocks != document.blocks {
            let range = view.selectedRange()
            context.coordinator.updating = true
            view.textStorage?.setAttributedString(MeetingAttributedDocument.render(document))
            view.setSelectedRange(
                NSRange(location: min(range.location, view.string.utf16.count), length: 0))
            view.undoManager?.removeAllActions()
            context.coordinator.lastValue = document
            context.coordinator.updating = false
        } else {
            context.coordinator.lastValue = document
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MeetingRichEditor
        var lastValue: MeetingDocument?
        var updating = false
        init(_ parent: MeetingRichEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView,
                let storage = view.textStorage
            else { return }
            updating = true
            defer { updating = false }
            let document = MeetingAttributedDocument.document(
                from: storage, previous: parent.document)
            // New paragraphs inherit attributes in AppKit; give them stable, unique block IDs.
            var offset = 0
            for block in document.blocks {
                guard offset < storage.length else { break }
                let range = (storage.string as NSString).paragraphRange(
                    for: NSRange(location: offset, length: 0))
                storage.addAttribute(.meetingBlock, value: block.id.uuidString, range: range)
                offset = NSMaxRange(range)
            }
            lastValue = document
            parent.document = document
            parent.controller.selectionChanged()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating else { return }
            parent.controller.selectionChanged()
        }
    }
}

@MainActor private final class MeetingNativeTextView: NSTextView {
    weak var controller: MeetingEditorController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            if event.charactersIgnoringModifiers == "b" { controller?.toggle("bold"); return true }
            if event.charactersIgnoringModifiers == "i" {
                controller?.toggle("italic"); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        let kind =
            (typingAttributes[.meetingKind] as? String).flatMap(
                MeetingDocumentBlock.Kind.init(rawValue:)) ?? .paragraph
        let selected = selectedRange()
        let ns = string as NSString
        let paragraph = ns.paragraphRange(for: selected)
        let line = ns.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
        if [.bullet, .numbered, .task, .quote].contains(kind),
            (["•", "☐", "☑", "›"].contains(line)
                || line.range(of: #"^\d+\.$"#, options: .regularExpression) != nil)
        {
            insertText("", replacementRange: paragraph)
            typingAttributes = MeetingAttributedDocument.attributes(kind: .paragraph)
            return
        }
        super.insertNewline(sender)
        let next: MeetingDocumentBlock.Kind =
            [.heading, .subheading].contains(kind) ? .paragraph : kind
        typingAttributes = MeetingAttributedDocument.attributes(kind: next)
        let number = kind == .numbered ? (Int(line.split(separator: ".").first ?? "0") ?? 0) + 1 : 1
        let prefix = MeetingAttributedDocument.prefix(next, number: number)
        if !prefix.isEmpty { insertText(prefix, replacementRange: selectedRange()) }
    }
}
