//
//  Inf6CorePaperWatchSender.swift
//  inf6
//
//  Sends learning guide + quiz to Watch via WatchConnectivity.
//

import Foundation
#if os(iOS)
import WatchConnectivity

// MARK: - Payload Models

struct Inf6WatchLearningGuideItem: Codable, Hashable, Sendable {
    var paperId: String
    var paperTitle: String
    var categoryName: String
    var reasonJa: String
}

struct Inf6WatchCorePaperAlertItem: Codable, Hashable, Sendable {
    var sectionName: String
    var notStartedCount: Int
    var totalCount: Int
}

struct Inf6WatchCorePaperPayload: Codable, Hashable, Sendable {
    var guideItems: [Inf6WatchLearningGuideItem]
    var alertItems: [Inf6WatchCorePaperAlertItem]
    var generatedAt: Date
}

// MARK: - Sender

@MainActor
final class Inf6CorePaperWatchSender: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = Inf6CorePaperWatchSender()

    static let payloadKey = "inf6.corepaper.v1"

    @Published var lastError: String?

    override private init() {
        super.init()
        guard WCSession.isSupported() else {
            lastError = "WatchConnectivity is not supported."
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Public API

    func sendLearningGuide(store: Inf6CorePaperStore) {
        let papers = store.nextRecommendedPapers(count: 5)
        let guideItems: [Inf6WatchLearningGuideItem] = papers.map { paper in
            let cat = Inf6CorePaperCategory.infer(from: paper.tags)
            return Inf6WatchLearningGuideItem(
                paperId: paper.id,
                paperTitle: paper.title,
                categoryName: cat.displayName,
                reasonJa: store.recommendationReason(for: paper)
            )
        }

        let alarmNodes = store.topAlarmNodes()
        let alertItems: [Inf6WatchCorePaperAlertItem] = alarmNodes.map { node in
            let notStarted = node.coveringPapers.filter {
                (store.progress[$0.id]?.status ?? .notStarted) == .notStarted
            }.count
            return Inf6WatchCorePaperAlertItem(
                sectionName: node.sectionName,
                notStartedCount: notStarted,
                totalCount: node.coveringPapers.count
            )
        }

        let payload = Inf6WatchCorePaperPayload(
            guideItems: guideItems,
            alertItems: alertItems,
            generatedAt: Date()
        )

        guard let data = try? JSONEncoder().encode(payload) else { return }
        _send(payload: [Self.payloadKey: data])
    }

    func sendQuiz(for paper: Inf6CorePaper) {
        let notes = Inf6EshikakuCorePaperQuizGenerator.findSidecarNotes(for: paper)
        guard let quiz = Inf6EshikakuCorePaperQuizGenerator.generateQuiz(paper: paper, notes: notes, lang: "ja") else { return }
        guard let data = try? JSONEncoder().encode(quiz) else { return }
        _send(payload: [Inf6WatchConnectivityPhone.quizPayloadKey: data])
    }

    // MARK: - Private

    private func _send(payload: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(payload)
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        if let error {
            Task { @MainActor in
                self.lastError = "WatchConnectivity activation failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
#endif
