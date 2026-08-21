import Foundation
import PersonalizationKit

/// Watches the destination field after a dictation and learns from what the
/// user fixes there.
///
/// Corrections made where the text landed were invisible to VoxoL: it only ever
/// learned from edits made afterwards in its own history window, which is not
/// where anyone corrects a word. This reads the same control again a few times
/// and, when the change looks like a repair of what was dictated, records it as
/// a correction — the same input the dictionary already learns from.
///
/// Polled rather than observed. An `AXObserver` would be more immediate, but it
/// needs a per-process observer, a run-loop source and teardown on every focus
/// change, and this runs for at most a minute after each dictation. The cost of
/// a handful of attribute reads is not worth that machinery.
@MainActor
final class InsertionCorrectionWatcher {
    /// When to look again, in seconds after insertion. Front-loaded because a
    /// misheard word is usually fixed as soon as it is read, and stopped at a
    /// minute because after that the field belongs to whatever came next.
    private static let checkpoints: [Duration] = [
        .seconds(3), .seconds(8), .seconds(20), .seconds(45),
    ]

    private let injector: TextInjector
    private var task: Task<Void, Never>?

    init(injector: TextInjector) {
        self.injector = injector
    }

    /// Starts watching the destination for a repair of `insertedText`.
    ///
    /// The handler is called at most once, and only for a change that survives
    /// `InsertionCorrection`'s checks.
    func watch(
        target: TextInsertionTarget,
        insertedText: String,
        onCorrection: @escaping @MainActor (String) -> Void,
        onOutcome: @escaping @MainActor (InsertionCorrection.Outcome) -> Void = { _ in }
    ) {
        // One dictation at a time: the previous field is no longer where the
        // user is, and its later edits say nothing about this dictation.
        task?.cancel()
        guard let baseline = injector.currentText(of: target),
            baseline.contains(insertedText)
        else {
            // The app does not expose its text, or the insertion did not land
            // where it was read back from. Either way there is nothing to
            // compare against later.
            task = nil
            return
        }

        task = Task { [injector] in
            var lastOutcome = InsertionCorrection.Outcome.unchanged
            for checkpoint in Self.checkpoints {
                try? await Task.sleep(for: checkpoint)
                if Task.isCancelled { return }
                guard let current = injector.currentText(of: target) else {
                    onOutcome(lastOutcome)
                    return
                }
                let outcome = InsertionCorrection.classify(
                    inserted: insertedText,
                    baseline: baseline,
                    current: current
                )
                lastOutcome = outcome
                if case .corrected(let corrected) = outcome {
                    onCorrection(corrected)
                    onOutcome(outcome)
                    return
                }
            }
            // The window closed without a correction: whatever the field says
            // now is the dictation's verdict — unchanged is the win condition
            // the no-retouch rate counts.
            onOutcome(lastOutcome)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
