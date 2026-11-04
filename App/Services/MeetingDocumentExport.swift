import AppKit
import SpeakerKit
import UniformTypeIdentifiers

extension MeetingsStore {
    func exportPDF(_ report: MeetingReportDraft, title: String, includeSources: Bool = true) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = title + " - compte rendu.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let document = MeetingAttributedDocument.exportDocument(
            report.content,
            transcript: records.first { $0.id == report.id }, includeSources: includeSources)
        let attributed = MeetingAttributedDocument.render(document, printing: true)
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 48; info.bottomMargin = 48; info.leftMargin = 48; info.rightMargin = 48
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(
            width: width, height: CGFloat.greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(attributed)
        if let manager = view.layoutManager, let container = view.textContainer {
            manager.ensureLayout(for: container)
            view.setFrameSize(
                NSSize(width: width, height: ceil(manager.usedRect(for: container).height)))
        }
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        if !operation.run() {
            failure = String(localized: "The PDF could not be exported. Try again.")
        }
    }
}
