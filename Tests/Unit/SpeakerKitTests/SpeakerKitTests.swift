import AVFoundation
import Foundation
import Testing
@testable import SpeakerKit

struct SpeakerKitTests {
    @Test func stereoAudioConvertsContinuouslyThroughTheLastPartialBuffer() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for i in 0..<48_000 { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.2 }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let samples = try SpeakerAudio.load(url)
        #expect(abs(samples.count - 16000) <= 2)
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(try #require(samples.map { abs($0) }.max()) > 0.1)
    }
    private func timeline(_ rows: [(Int, [Float])]) -> [Float] {
        rows.flatMap { count, values in Array(repeating: values, count: count).flatMap { $0 } }
    }

    @Test func preservesUnicodePunctuationAndTurnBoundaries() throws {
        let text = "Élodie 👋, bonjour ! Oui."
        let ns = text as NSString
        let first = ns.range(of: "Élodie"), second = ns.range(of: "Oui")
        let turns = try SpeakerAttribution.turns(
            text: text,
            words: [
                .init(range: first.location..<(first.location + first.length), start: 0, end: 0.9),
                .init(
                    range: second.location..<(second.location + second.length), start: 1, end: 1.8),
            ], probabilities: timeline([(100, [0.9, 0.1]), (100, [0.1, 0.9])]),
            frameCount: 200, duration: 2, speakerCount: 2)
        #expect(turns.map(\.speakerIDs) == [[0], [1]])
        #expect(turns.map(\.text).joined() == text)
    }

    @Test func overlapIsExplicitAndSilenceIsUnknown() throws {
        let turns = try SpeakerAttribution.turns(
            text: "A B C",
            words: [
                .init(range: 0..<1, start: 0, end: 1),
                .init(range: 2..<3, start: 1, end: 2),
                .init(range: 4..<5, start: 2, end: 3),
            ],
            probabilities: timeline([(100, [0.9, 0.8]), (100, [0.1, 0.1]), (100, [0.9, 0.1])]),
            frameCount: 300, duration: 3, speakerCount: 2)
        #expect(turns[0].speakerIDs == [0, 1])
        #expect(turns[0].overlapping)
        #expect(turns[1].speakerIDs.isEmpty)
        #expect(turns[2].speakerIDs == [0])
    }

    @Test func equalBoundaryEvidenceDoesNotInventAnOverlap() throws {
        let turns = try SpeakerAttribution.turns(
            text: "word",
            words: [
                .init(range: 0..<4, start: 0, end: 1)
            ], probabilities: timeline([(50, [1, 0]), (50, [0, 1])]),
            frameCount: 100, duration: 1, speakerCount: 2)
        #expect(turns[0].speakerIDs.isEmpty)
        #expect(!turns[0].overlapping)
    }

    @Test func missingTimesRemainUnknownAndMalformedRangesFail() throws {
        let turns = try SpeakerAttribution.turns(
            text: "untimed", words: [],
            probabilities: [], frameCount: 0, duration: 1)
        #expect(turns[0].text == "untimed")
        #expect(turns[0].speakerIDs.isEmpty)
        #expect(throws: SpeakerError.self) {
            try SpeakerAttribution.turns(
                text: "x", words: [.init(range: 0..<9, start: 0, end: 1)],
                probabilities: [], frameCount: 0, duration: 1)
        }
        #expect(throws: SpeakerError.self) {
            try SpeakerAttribution.turns(
                text: "x", words: [],
                probabilities: [.nan], frameCount: 1, duration: 1, speakerCount: 1)
        }
    }

    @Test func speakerAttributionUsesTheTwoHourImportContract() throws {
        let turns = try SpeakerAttribution.turns(
            text: "long", words: [], probabilities: [], frameCount: 0, duration: 7_200)
        #expect(turns.count == 1)
        #expect(turns[0].start == 0)
        #expect(turns[0].end == 7_200)
        #expect(throws: SpeakerError.self) {
            try SpeakerAttribution.turns(
                text: "too long", words: [], probabilities: [], frameCount: 0,
                duration: 7_201)
        }
    }

    @Test func renamedSpeakersSurviveSaveAndAllExports() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpeakerArchiveStore(url: directory.appendingPathComponent("meetings.json"))
        let turns = try SpeakerAttribution.turns(
            text: "Bonjour.", words: [.init(range: 0..<7, start: 0.25, end: 0.95)],
            probabilities: [Float](repeating: 1, count: 100), frameCount: 100, duration: 1,
            speakerCount: 1)
        var document = SpeakerTranscript(
            title: "Test", duration: 1, rawText: "Bonjour.", turns: turns,
            diarizationRevision: "test")
        document.names[0] = "Alice"
        try await store.save([document])
        let restored = try await store.load()
        #expect(restored == [document])
        #expect(document.plainText().contains("Alice"))
        #expect(document.subtitles().contains("00:00:00,250 --> 00:00:00,950"))
        #expect(document.subtitles().contains("Alice: Bonjour."))
    }

    @Test func futureArchiveIsRejectedWithoutRewritingIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("{\"version\":99,\"transcripts\":[]}".utf8)
        try data.write(to: url)
        await #expect(throws: SpeakerError.self) { try await SpeakerArchiveStore(url: url).load() }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func correctionChangesExportsAndPreservesModelEvidence() throws {
        let turns = try SpeakerAttribution.turns(
            text: "Hello", words: [.init(range: 0..<5, start: 0, end: 1)],
            probabilities: timeline([(100, [0.9, 0.1])]), frameCount: 100, duration: 1,
            speakerCount: 2)
        var document = SpeakerTranscript(
            title: "Test", duration: 1, rawText: "Hello", turns: turns, diarizationRevision: "test")
        document.names[1] = "Alice"
        document.turns[0].correctedSpeakerIDs = [1]
        let restored = try JSONDecoder().decode(
            SpeakerTranscript.self, from: JSONEncoder().encode(document))
        #expect(restored.turns[0].speakerIDs == [0])
        #expect(restored.turns[0].displayedSpeakerIDs == [1])
        #expect(restored.plainText().contains("Alice"))
        #expect(restored.subtitles().contains("Alice: Hello"))
    }

    @Test func missingModelAndCancellationFailBeforeInference() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        #expect(throws: SpeakerError.self) { try SpeakerModelAssets.verify(directory: missing) }
        let task = Task {
            try await Task.sleep(for: .milliseconds(20))
            return try await NativeSpeakerDiarizer().analyze(samples: [0], directory: missing)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func reportDraftKeepsMarkdownAndDetectsSpeakerChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingReportArchiveStore(url: directory.appendingPathComponent("reports.json"))
        var document = SpeakerTranscript(
            title: "Réunion projet", duration: 8, rawText: "Bonjour.",
            turns: [
                .init(
                    id: 0, start: 1, end: 2, speakerIDs: [0], overlapping: false,
                    text: "Bonjour.")
            ],
            diarizationRevision: "test")
        var draft = try MeetingReportDraft.template(for: document, french: true)
        #expect(draft.markdown.hasPrefix("# Réunion projet\n"))
        #expect(draft.document?.title == document.title)
        #expect(draft.isCurrent(for: document))
        draft.markdown += "\n- Décision à relire [00:00:01]"
        try await store.save([draft])
        #expect(try await store.load() == [draft])
        document.names[0] = "Alice"
        #expect(!draft.isCurrent(for: document))
    }

    @Test func futureReportArchiveIsRejectedWithoutRewritingIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("{\"version\":99,\"reports\":[]}".utf8)
        try data.write(to: url)
        await #expect(throws: SpeakerError.self) {
            try await MeetingReportArchiveStore(url: url).load()
        }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func generatedReportRequiresTranscriptSourcesAndKeepsUnstatedDatesUnknown() throws {
        let document = SpeakerTranscript(
            title: "Migration", duration: 30,
            rawText: "Hugo envoie les journaux. Pas de date fixée.",
            turns: [
                .init(
                    id: 4, start: 12, end: 18, speakerIDs: [0], overlapping: false,
                    text: "Hugo envoie les journaux. Pas de date fixée.")
            ],
            diarizationRevision: "test")
        let output = """
            {"topic_quote":"Hugo envoie les journaux.","topic_source_id":4,"decisions":[],"actions":[{"task":"Envoyer les journaux","commitment_quote":"Hugo envoie les journaux.","commitment_turn_id":4,"owner":"Hugo","due":"vendredi"}],"open_questions":[{"open_quote":"Pas de date fixée.","open_turn_id":4}]}
            """
        let extracted = try MeetingReportExtraction.parse(
            output, sourceTurns: [4: document.turns[0].text])
        let markdown = MeetingReportMarkdown.render(
            transcript: document, extractions: [extracted], french: true)
        #expect(markdown.contains("Un engagement a été formulé"))
        #expect(markdown.contains("La personne indiquée est Hugo."))
        #expect(!markdown.contains("vendredi"))
        #expect(markdown.contains("[00:00:12]"))
        #expect(throws: MeetingReportGenerationError.self) {
            try MeetingReportExtraction.parse(output, sourceTurns: [3: document.turns[0].text])
        }
        #expect(throws: MeetingReportGenerationError.self) {
            try MeetingReportExtraction.parse("# résumé", sourceTurns: [4: document.turns[0].text])
        }
        let inventedApproval = """
            {"topic_quote":"Hugo envoie les journaux.","topic_source_id":4,"decisions":[{"approval_quote":"Le devis est approuvé","approval_turn_id":4}],"actions":[],"open_questions":[]}
            """
        #expect(throws: MeetingReportGenerationError.self) {
            try MeetingReportExtraction.parse(
                inventedApproval, sourceTurns: [4: document.turns[0].text])
        }
    }

    @Test func compactReportReferencesReconstructExactTranscriptEvidence() throws {
        let source =
            "D'accord pour planifier après l'audit, mais pas de date. Je t'enverrai les journaux demain matin."
        let fragments = MeetingReportEvidenceBuilder.fragments(in: source)
        #expect(
            fragments == [
                "D'accord pour planifier après l'audit,",
                "mais pas de date.",
                "Je t'enverrai les journaux demain matin.",
            ])
        #expect(fragments.allSatisfy { source.contains($0) })

        let evidence = Dictionary(
            uniqueKeysWithValues: fragments.enumerated().map { index, text in
                (index, MeetingReportEvidence(id: index, turnID: 7, text: text))
            })
        let output = """
            {"t":0,"s":[0,2],"p":[{"e":2,"x":"Enverra les journaux demain matin."}],"d":[0],"a":[{"e":2,"x":"Envoyer les journaux","o":"Hugo","u":"demain matin"}],"q":[1]}
            """
        let extraction = try MeetingReportExtraction.parseCompact(output, evidence: evidence)
        let document = SpeakerTranscript(
            title: "Audit", duration: 12, rawText: source,
            turns: [
                .init(
                    id: 7, start: 2, end: 10, speakerIDs: [0], overlapping: false,
                    text: source)
            ], diarizationRevision: "test")
        let markdown = MeetingReportMarkdown.render(
            transcript: document, extractions: [extraction], french: true)

        #expect(markdown.contains("« D'accord pour planifier après l'audit, »"))
        #expect(markdown.contains("« mais pas de date. »"))
        #expect(markdown.contains("« Je t'enverrai les journaux demain matin. »"))
        #expect(markdown.contains("Un engagement a été formulé"))
        #expect(markdown.contains("L'échéance mentionnée est demain matin."))

        let invented = output.replacingOccurrences(of: "\"q\":[1]", with: "\"q\":[99]")
        #expect(throws: MeetingReportGenerationError.self) {
            try MeetingReportExtraction.parseCompact(invented, evidence: evidence)
        }
    }

    @Test func daqReportReconstructsExactEvidenceAndSanitizesOpenQuestions() throws {
        let evidence = [
            0: MeetingReportEvidence(id: 0, turnID: 4, text: "Le budget est approuvé."),
            1: MeetingReportEvidence(
                id: 1, turnID: 5, text: "Je vais envoyer les journaux demain matin."),
            2: MeetingReportEvidence(
                id: 2, turnID: 6,
                text: "Il faudrait que quelqu'un prépare la démo, aucun responsable n'est nommé."),
            3: MeetingReportEvidence(
                id: 3, turnID: 7, text: "Le choix final n'est pas encore décidé."),
            4: MeetingReportEvidence(
                id: 4, turnID: 8, text: "Final approval has not been given yet."),
            5: MeetingReportEvidence(
                id: 5, turnID: 9,
                text: "I might decide tomorrow after checking the metrics."),
        ]
        let output = """
            {"d":["E0"],"a":["E1"],"q":["E2","E3","E4","E5"]}
            """
        let extraction = try MeetingReportExtraction.parseDAQ(output, evidence: evidence)

        #expect(extraction.decisions.map(\.approvalQuote) == ["Le budget est approuvé."])
        #expect(extraction.actions.map(\.task) == ["Je vais envoyer les journaux demain matin."])
        #expect(extraction.actions.allSatisfy { $0.owner == nil && $0.due == nil })
        #expect(
            extraction.openQuestions.map(\.openQuote)
                == [
                    "Le choix final n'est pas encore décidé.",
                    "Final approval has not been given yet.",
                ])
        #expect(extraction.summaryPoints.allSatisfy { point in
            evidence.values.contains { $0.text == point.quote && $0.turnID == point.turnID }
        })
    }

    @Test func daqReportRejectsMalformedInventedAndDuplicateReferences() throws {
        let evidence = [
            0: MeetingReportEvidence(id: 0, turnID: 1, text: "Décision validée.")
        ]
        for output in [
            "{\"d\":[\"E0\",\"E0\"],\"a\":[],\"q\":[]}",
            "{\"d\":[\"0\"],\"a\":[],\"q\":[]}",
            "{\"d\":[\"E00\"],\"a\":[],\"q\":[]}",
            "{\"d\":[\"E99\"],\"a\":[],\"q\":[]}",
            "{\"d\":[],\"a\":[],\"q\":[],\"extra\":[]}",
        ] {
            #expect(throws: MeetingReportGenerationError.self) {
                try MeetingReportExtraction.parseDAQ(output, evidence: evidence)
            }
        }
    }

    @Test func daqReportRejectsCrossCategoryDuplicateReference() {
        let evidence = [
            0: MeetingReportEvidence(id: 0, turnID: 1, text: "Décision validée.")
        ]
        let output = #"{"d":["E0"],"a":["E0"],"q":[]}"#
        #expect(throws: MeetingReportGenerationError.self) {
            try MeetingReportExtraction.parseDAQ(output, evidence: evidence)
        }
    }

    @Test func deterministicDAQFastPathResolvesExplicitFrenchEvidence() throws {
        let evidence = [
            16: MeetingReportEvidence(
                id: 16, turnID: 3,
                text: "C'est validé : nous lançons la bêta privée lundi matin."),
            18: MeetingReportEvidence(
                id: 18, turnID: 4,
                text: "Moi, Alice, je m'engage à envoyer la liste finale demain."),
            20: MeetingReportEvidence(
                id: 20, turnID: 5,
                text: "Moi, Bob, je prends en charge la checklist et je la terminerai vendredi."),
            22: MeetingReportEvidence(
                id: 22, turnID: 6,
                text: "On n'a pas encore décidé qui fera la démonstration client."),
            26: MeetingReportEvidence(
                id: 26, turnID: 8,
                text: "Décision prise : on garde les notifications désactivées."),
        ]
        let output = MeetingReportExtraction.deterministicDAQOutput(
            candidateIDs: [16, 18, 20, 22, 26], evidence: evidence)

        #expect(
            output
                == "{\"d\":[\"E16\",\"E26\"],\"a\":[\"E18\",\"E20\"],\"q\":[\"E22\"]}")
        let extraction = try MeetingReportExtraction.parseDAQ(output ?? "", evidence: evidence)
        #expect(extraction.decisions.map(\.approvalTurnID) == [3, 8])
        #expect(extraction.actions.map(\.commitmentTurnID) == [4, 5])
        #expect(extraction.openQuestions.map(\.openTurnID) == [6])
    }

    @Test func deterministicDAQFastPathHandlesConditionalFrenchAndExplicitEnglish() {
        let nuanced = [
            18: MeetingReportEvidence(
                id: 18, turnID: 4,
                text: "Après discussion, on décide de ne pas migrer tout le trafic vendredi."),
            20: MeetingReportEvidence(
                id: 20, turnID: 5,
                text: "Si l'API passe les tests, moi, Nadia, je préparerai le déploiement lundi."),
            24: MeetingReportEvidence(
                id: 24, turnID: 7,
                text: "L'approbation sécurité reste en attente et personne ne l'a encore donnée."),
            26: MeetingReportEvidence(
                id: 26, turnID: 8,
                text: "On doit encore décider si l'ancien endpoint restera actif."),
            32: MeetingReportEvidence(
                id: 32, turnID: 11,
                text: "Moi, Marc, je m'engage à vérifier les alertes et à publier le résultat."),
            34: MeetingReportEvidence(
                id: 34, turnID: 12,
                text: "Décision confirmée : le rollback restera automatique."),
        ]
        #expect(
            MeetingReportExtraction.deterministicDAQOutput(
                candidateIDs: [18, 20, 24, 26, 32, 34], evidence: nuanced)
                == "{\"d\":[\"E18\",\"E34\"],\"a\":[\"E20\",\"E32\"],\"q\":[\"E24\",\"E26\"]}")

        let english = [
            16: MeetingReportEvidence(
                id: 16, turnID: 3,
                text: "We approved keeping report generation manual for this release."),
            18: MeetingReportEvidence(
                id: 18, turnID: 4,
                text: "I, Priya, commit to update the release notes by Thursday."),
            20: MeetingReportEvidence(
                id: 20, turnID: 5,
                text: "I, Daniel, will run the final regression set by Friday."),
            22: MeetingReportEvidence(
                id: 22, turnID: 6,
                text: "We still have not decided whether drafts should open automatically."),
            26: MeetingReportEvidence(
                id: 26, turnID: 8,
                text: "Decision confirmed: the generated draft remains editable."),
        ]
        #expect(
            MeetingReportExtraction.deterministicDAQOutput(
                candidateIDs: [16, 18, 20, 22, 26], evidence: english)
                == "{\"d\":[\"E16\",\"E26\"],\"a\":[\"E18\",\"E20\"],\"q\":[\"E22\"]}")
    }

    @Test func deterministicDAQFastPathFallsBackOnAmbiguousOrWeakCandidates() {
        let ambiguous = [
            0: MeetingReportEvidence(
                id: 0, turnID: 1,
                text: "Decision confirmed, and I will publish the notes tomorrow.")
        ]
        #expect(
            MeetingReportExtraction.deterministicDAQOutput(
                candidateIDs: [0], evidence: ambiguous) == nil)

        let weak = [
            1: MeetingReportEvidence(
                id: 1, turnID: 2,
                text: "I might decide tomorrow after checking the metrics.")
        ]
        #expect(
            MeetingReportExtraction.deterministicDAQOutput(
                candidateIDs: [1], evidence: weak) == nil)
        #expect(
            MeetingReportExtraction.deterministicDAQOutput(
                candidateIDs: [99], evidence: weak) == nil)

        let proposals = [
            2: MeetingReportEvidence(
                id: 2, turnID: 3,
                text: "Je propose qu'on décide vendredi après les derniers tests."),
            3: MeetingReportEvidence(
                id: 3, turnID: 4,
                text: "I suggest we decide on Friday after the final tests."),
        ]
        #expect(
            MeetingReportExtraction.deterministicDAQOutput(
                candidateIDs: [2], evidence: proposals)
                == "{\"d\":[],\"a\":[],\"q\":[]}")
        #expect(
            MeetingReportExtraction.deterministicDAQOutput(
                candidateIDs: [3], evidence: proposals)
                == "{\"d\":[],\"a\":[],\"q\":[]}")

        let decidedProposal = [
            5: MeetingReportEvidence(
                id: 5, turnID: 6,
                text: "We approved the proposal after the final review.")
        ]
        #expect(
            MeetingReportExtraction.deterministicDAQOutput(
                candidateIDs: [5], evidence: decidedProposal) == nil)

        let mixed = [
            2: proposals[2]!,
            4: MeetingReportEvidence(
                id: 4, turnID: 5,
                text: "Décision confirmée : le pilote reste limité à dix pour cent."),
        ]
        let partition = MeetingReportExtraction.deterministicDAQPartition(
            candidateIDs: [2, 4], evidence: mixed)
        #expect(partition?.unresolvedIDs.isEmpty == true)
        #expect(partition?.resolvedOutput == "{\"d\":[\"E4\"],\"a\":[],\"q\":[]}")
    }

    @Test func daqCandidatePrefilterRejectsIncidentalQuestionAndIncompleteCommitmentFragments() {
        for text in [
            "Le nom de l'avatar en question.",
            "On affiche ensuite l'élément en question",
            "D'après ce que je vais",
            "que je vais",
            "The component in question is already visible.",
        ] {
            #expect(!MeetingReportExtraction.isLikelyDAQCandidate(text))
        }

        for text in [
            "Je vais publier le rapport demain.",
            "I will publish the report tomorrow.",
            "On n'a pas encore décidé qui fera la démonstration.",
            "This remains to be decided.",
            "Open question: faut-il conserver ce comportement ?",
            "Est-ce qu'on garde ce comportement ?",
        ] {
            #expect(MeetingReportExtraction.isLikelyDAQCandidate(text))
        }
    }

    @Test func deterministicDAQPreservesTasksBesideCognitiveFutureStatements() throws {
        let texts = [
            "Je vais comprendre le tableau et je publierai les notes demain.",
            "I will know more after the demo and I will publish the notes tomorrow.",
        ]
        let evidence = Dictionary(
            uniqueKeysWithValues: texts.enumerated().map { id, text in
                (id, MeetingReportEvidence(id: id, turnID: id, text: text))
            })
        let partition = try #require(
            MeetingReportExtraction.deterministicDAQPartition(
                candidateIDs: [0, 1], evidence: evidence))
        let extraction = try MeetingReportExtraction.parseDAQ(
            partition.resolvedOutput, evidence: evidence)
        #expect(extraction.actions.map(\.commitmentQuote) == texts)
        #expect(partition.unresolvedIDs.isEmpty)

        let sharedSubject = [
            0: MeetingReportEvidence(
                id: 0, turnID: 0, text: "Je vais comprendre le tableau et publier les notes.")
        ]
        #expect(
            MeetingReportExtraction.deterministicDAQPartition(
                candidateIDs: [0], evidence: sharedSubject)?.unresolvedIDs == [0])
    }

    @Test func daqPreservesExplicitOpenQuestionsWithoutQuestionMarks() throws {
        for text in [
            "Question ouverte : qui prendra en charge la maintenance.",
            "Cette question reste une question en suspens.",
            "Open question: who will maintain the service.",
        ] {
            #expect(MeetingReportExtraction.isLikelyDAQCandidate(text))
            let evidence = [0: MeetingReportEvidence(id: 0, turnID: 0, text: text)]
            let output = try #require(
                MeetingReportExtraction.deterministicDAQOutput(
                    candidateIDs: [0], evidence: evidence))
            let extraction = try MeetingReportExtraction.parseDAQ(output, evidence: evidence)
            #expect(extraction.openQuestions.map(\.openQuote) == [text])
        }
    }

    @Test func deterministicDAQDoesNotPromoteCognitiveFutureStatementsToActions() throws {
        let evidence = [
            0: MeetingReportEvidence(
                id: 0, turnID: 1,
                text: "Ce que je vais comprendre après la démonstration."),
            1: MeetingReportEvidence(
                id: 1, turnID: 2,
                text: "I will know more after the demo."),
        ]
        let output = MeetingReportExtraction.deterministicDAQOutput(
            candidateIDs: [0, 1], evidence: evidence)
        #expect(output == "{\"d\":[],\"a\":[],\"q\":[]}")
        let extraction = try MeetingReportExtraction.parseDAQ(output ?? "", evidence: evidence)
        #expect(extraction.actions.isEmpty)
    }

    @Test func reportRendersGroundedParagraphsInsteadOfBulletSummaries() throws {
        let document = SpeakerTranscript(
            title: "Atlas", duration: 20,
            rawText: "Le prototype fonctionne. Je prépare les chiffres.",
            turns: [
                .init(
                    id: 0, start: 1, end: 3, speakerIDs: [0], overlapping: false,
                    text: "Le prototype fonctionne."),
                .init(
                    id: 1, start: 8, end: 10, speakerIDs: [1], overlapping: false,
                    text: "Je prépare les chiffres."),
            ], diarizationRevision: "test")
        let output = """
            {"topic_quote":"Le prototype fonctionne.","topic_source_id":0,"summary_points":[{"text":"Le prototype a été approuvé.","quote":"Le prototype fonctionne.","turn_id":0}],"speaker_points":[{"text":"Prépare les chiffres.","quote":"Je prépare les chiffres.","turn_id":1}],"decisions":[],"actions":[],"open_questions":[]}
            """
        let extracted = try MeetingReportExtraction.parse(
            output, sourceTurns: [0: document.turns[0].text, 1: document.turns[1].text])
        let evidence = [
            0: MeetingReportEvidence(id: 0, turnID: 0, text: document.turns[0].text),
            1: MeetingReportEvidence(id: 1, turnID: 1, text: document.turns[1].text),
        ]
        let narrative = try MeetingReportNarrative.parse(
            """
            {"p":[{"t":"Le prototype fonctionne. Une autre intervention porte sur la préparation des chiffres.","e":[0,1]}]}
            """, evidence: evidence, transcript: document)
        let markdown = MeetingReportMarkdown.render(
            transcript: document, extractions: [extracted], french: true,
            narratives: [narrative])
        #expect(markdown.contains("## Synthèse"))
        #expect(markdown.contains("Le prototype fonctionne. Une autre intervention porte sur la préparation des chiffres.\n_Sources : [00:00:01] · [00:00:08]_"))
        #expect(!markdown.contains("\n- "))
        #expect(!markdown.contains("Le prototype a été approuvé."))
        let invented = output.replacingOccurrences(
            of: "Je prépare les chiffres.", with: "Le devis est validé.")
        #expect(throws: MeetingReportGenerationError.self) {
            try MeetingReportExtraction.parse(
                invented, sourceTurns: [0: document.turns[0].text, 1: document.turns[1].text])
        }
    }

    @Test func reportNarrativeRejectsUncitedFactsAndUnsupportedApproval() throws {
        let document = SpeakerTranscript(
            title: "Budget", duration: 12, rawText: "Le budget de 40 euros reste à confirmer.",
            turns: [.init(id: 3, start: 2, end: 8, speakerIDs: [0], overlapping: false,
                          text: "Le budget de 40 euros reste à confirmer.")],
            diarizationRevision: "test")
        let evidence = [
            0: MeetingReportEvidence(id: 0, turnID: 3,
                                     text: "Le budget de 40 euros reste à confirmer.")
        ]
        for output in [
            #"{"p":[{"t":"Le budget de 50 euros reste à confirmer.","e":[0]}]}"#,
            #"{"p":[{"t":"Le budget de 40 euros a été approuvé.","e":[0]}]}"#,
            #"{"p":[{"t":"Le budget de 40 euros reste à confirmer.","e":[9]}]}"#,
            #"{"p":[{"t":"- Le budget de 40 euros reste à confirmer.","e":[0]}]}"#,
        ] {
            #expect(throws: MeetingReportGenerationError.self) {
                try MeetingReportNarrative.parse(output, evidence: evidence, transcript: document)
            }
        }
        let fallback = MeetingReportNarrative.verbatimFallback(
            evidence: evidence, transcript: document, french: true)
        #expect(fallback.usesVerbatimFallback)
        #expect(fallback.paragraphs[0].text.contains("Le budget de 40 euros reste à confirmer."))

        let settled = SpeakerTranscript(
            title: "Budget", duration: 12,
            rawText: "Le budget est approuvé. La date reste à confirmer.",
            turns: [.init(id: 3, start: 2, end: 8, speakerIDs: [0], overlapping: false,
                          text: "Le budget est approuvé. La date reste à confirmer.")],
            diarizationRevision: "test")
        let mixedEvidence = [
            0: MeetingReportEvidence(id: 0, turnID: 3, text: "Le budget est approuvé."),
            1: MeetingReportEvidence(id: 1, turnID: 3, text: "La date reste à confirmer."),
        ]
        let claimedApproval = #"{"p":[{"t":"La date a été approuvée pendant la réunion.","e":[1]}]}"#
        #expect(throws: MeetingReportGenerationError.self) {
            try MeetingReportNarrative.parse(
                claimedApproval, evidence: mixedEvidence, transcript: settled,
                allowedDecisionEvidenceIDs: [0])
        }
    }

    @Test func reportNarrativeAcceptsOneAccidentalEvidenceArrayWrapper() throws {
        let document = SpeakerTranscript(
            title: "Test", duration: 2, rawText: "Le tableau doit être plus lisible.",
            turns: [
                .init(
                    id: 0, start: 0, end: 2, speakerIDs: [0], overlapping: false,
                    text: "Le tableau doit être plus lisible.")
            ],
            diarizationRevision: "test")
        let evidence = [
            0: MeetingReportEvidence(
                id: 0, turnID: 0, text: "Le tableau doit être plus lisible.")
        ]
        for ids in ["[0]", "[[0]]", #"["E0"]"#] {
            let narrative = try MeetingReportNarrative.parse(
                "{\"p\":[{\"t\":\"Le tableau doit être plus lisible.\",\"e\":\(ids)}]}",
                evidence: evidence,
                transcript: document)
            #expect(narrative.paragraphs.count == 1)
            #expect(narrative.paragraphs[0].sourceTurnIDs == [0])
        }
        for ids in [
            #"["E00"]"#, #"["0"]"#, #"["E-1"]"#, #"["E99"]"#,
            #"["E0","E0"]"#, "[[[0]]]",
        ] {
            #expect(throws: MeetingReportGenerationError.self) {
                try MeetingReportNarrative.parse(
                    "{\"p\":[{\"t\":\"Le tableau doit être plus lisible.\",\"e\":\(ids)}]}",
                    evidence: evidence, transcript: document)
            }
        }
    }

    @Test func transcriptNarrativePromptUsesExactFragmentsAndCorrectedSpeakerNames() throws {
        let text = "Le budget est approuvé. Je vais envoyer le rapport demain."
        var document = SpeakerTranscript(
            title: "Rapport", duration: 10, rawText: text,
            turns: [
                .init(
                    id: 7, start: 0, end: 10, speakerIDs: [1], overlapping: false,
                    text: text, correctedSpeakerIDs: [0])
            ],
            diarizationRevision: "test")
        document.names[0] = "Alice"
        let evidence = MeetingReportNarrative.boundedEvidence(from: document)
        let fragments = MeetingReportEvidenceBuilder.fragments(in: text)
        #expect(evidence.values.sorted { $0.id < $1.id }.map(\.text) == fragments)
        let prompt = MeetingReportNarrative.prompt(
            evidence: evidence, transcript: document, french: true)
        for source in evidence.values {
            #expect(source.turnID == 7)
            #expect(prompt.contains("[E\(source.id)] Alice: \(source.text)"))
        }
        let narrative = try MeetingReportNarrative.parse(
            #"{"p":[{"t":"Alice enverra le rapport demain.","e":[1]}]}"#,
            evidence: evidence, transcript: document)
        #expect(narrative.paragraphs.first?.sourceTurnIDs == [7])
    }

    @Test func boundedNarrativeEvidenceKeepsPriorityAndTimelineCoverage() throws {
        let sources = (0..<200).map { index in
            MeetingReportNarrative.Source(
                turnID: index,
                text: "Fragment \(index) about the meeting and its current state.",
                prioritized: index == 50 || index == 150
            )
        }
        let evidence = MeetingReportNarrative.boundedEvidence(
            from: sources, maximumCharacters: 1_200, maximumCount: 12)
        let selected = evidence.values.sorted { $0.id < $1.id }
        #expect(selected.count <= 12)
        #expect(selected.contains(where: { $0.turnID == 50 }))
        #expect(selected.contains(where: { $0.turnID == 150 }))
        #expect(selected.contains(where: { $0.turnID < 20 }))
        #expect(selected.contains(where: { $0.turnID > 180 }))
        #expect(selected.map(\.turnID) == selected.map(\.turnID).sorted())
    }

    @Test func boundedNarrativeEvidenceCollapsesRepeatedText() throws {
        let sources = (0..<20).map { index in
            MeetingReportNarrative.Source(
                turnID: index,
                text: index.isMultiple(of: 2) ? "Même passage répété." : "Passage unique \(index)."
            )
        }
        let evidence = MeetingReportNarrative.boundedEvidence(
            from: sources, maximumCharacters: 4_000, maximumCount: 64)
        #expect(evidence.values.filter { $0.text == "Même passage répété." }.count == 1)
    }

    @Test func wordExportIsAReadableDocumentWithEditedUnicodeContent() throws {
        let data = MeetingWordDocument.data(
            markdown:
                "# Compte rendu — Équipe\n\n## Synthèse\n\n**Alice :** 5 < 7 & prêt.\n- [ ] Vérifier le devis"
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".docx")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-t", url.path]
        let output = Pipe()
        listing.standardOutput = output
        listing.standardError = output
        try listing.run()
        listing.waitUntilExit()
        #expect(listing.terminationStatus == 0)
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extract.arguments = ["-p", url.path, "word/document.xml"]
        let xmlOutput = Pipe()
        extract.standardOutput = xmlOutput
        try extract.run()
        let xml = String(
            decoding: xmlOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        extract.waitUntilExit()
        #expect(extract.terminationStatus == 0)
        #expect(xml.contains("Équipe"))
        #expect(xml.contains("5 &lt; 7 &amp; prêt"))
        #expect(xml.contains("Vérifier le devis"))
    }
}
