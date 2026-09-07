import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class TrainingReviewStore {
    private(set) var sessions: [TrainingReviewSession] = []
    private(set) var isLoading = false
    private(set) var isLoaded = false
    private(set) var lastError: String?
    var notice: String?

    @ObservationIgnored private let repository: TrainingReviewRepository

    init(repository: TrainingReviewRepository = TrainingReviewRepository()) {
        self.repository = repository
    }

    var acceptedCount: Int {
        sessions.count(where: { $0.status == .accepted })
    }

    var attentionCount: Int {
        sessions.count(where: { $0.status == .contextReview || $0.status == .quarantined })
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            isLoaded = true
        }
        do {
            sessions = try await repository.load()
            lastError = nil
        } catch {
            if !isLoaded {
                sessions = []
            }
            lastError = error.localizedDescription
        }
    }

    func save(
        id: String,
        verbatim: String,
        faithful: String,
        rewrite: String,
        code: String,
        disposition: TrainingReviewDisposition,
        rationale: String
    ) async {
        do {
            let updated = try await repository.save(
                TrainingReviewDecision(
                    id: id,
                    verbatim: verbatim,
                    faithful: faithful,
                    rewrite: rewrite,
                    code: code,
                    disposition: disposition,
                    rationale: rationale
                )
            )
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index] = updated
            }
            lastError = nil
            notice =
                disposition == .accept
                ? String(localized: "Reference saved as human-reviewed")
                : String(localized: "Capture quarantined")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func export() async {
        do {
            let data = try await repository.exportJSONL()
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "voxol-training-reviews.jsonl"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            notice = String(localized: "Training review exported")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func dismissNotice() {
        notice = nil
    }
}
