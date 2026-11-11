//
//  Inf6WatchConnectivityPhone.swift
//  inf6
//

import Foundation
import WatchConnectivity

enum Inf6WatchConnectivityPhoneError: LocalizedError {
    case unsupported
    case notPaired
    case watchAppNotInstalled
    case notActivated

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "WatchConnectivity is not supported on this device."
        case .notPaired:
            return "Apple Watch is not paired."
        case .watchAppNotInstalled:
            return "Apple Watch app is not installed."
        case .notActivated:
            return "WatchConnectivity session is not activated."
        }
    }
}

struct Inf6WatchPaperUpdateItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var eventTypeRaw: String
    var sourceRaw: String
    var paperID: String
    var canonicalID: String
    var title: String
    var landingURLString: String
    var shortReason: String
    var profileRelevanceScore: Float?
    var detectedAt: Date
}

struct Inf6WatchPaperUpdateEnvelope: Codable, Hashable, Sendable {
    var generatedAt: Date
    var items: [Inf6WatchPaperUpdateItem]
}

final class Inf6WatchConnectivityPhone: NSObject, WCSessionDelegate {
    static let shared = Inf6WatchConnectivityPhone()

    static let quizPayloadKey = "inf6.quiz.v1"
    static let paperUpdatePayloadKey = "inf6.paper_update.v1"

    private let stateQueue = DispatchQueue(label: "inf6.watch.phone.state")
    private var pendingApplicationContext: [String: Any] = [:]

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(quiz: Inf6PaperQuiz) throws {
        let data = try JSONEncoder().encode(quiz)
        try _send(payload: [Self.quizPayloadKey: data])
    }

    func clearQuiz() throws {
        try _send(payload: [Self.quizPayloadKey: Data()])
    }

    func sendCurrentQuiz(from baseDir: URL) throws {
        if let quiz = try Inf6PaperQuizStore.load(baseDir: baseDir) {
            try send(quiz: quiz)
        } else {
            try clearQuiz()
        }
    }

    func send(paperUpdates: [Inf6WatchPaperUpdateItem]) throws {
        let envelope = Inf6WatchPaperUpdateEnvelope(generatedAt: Date(), items: paperUpdates)
        let data = try JSONEncoder().encode(envelope)
        try _send(payload: [Self.paperUpdatePayloadKey: data])
    }

    private func _send(payload: [String: Any]) throws {
        guard WCSession.isSupported() else {
            throw Inf6WatchConnectivityPhoneError.unsupported
        }

        let session = WCSession.default
        if session.activationState != .activated {
            _enqueuePending(payload)
            session.activate()
            return
        }
        guard session.isPaired else {
            throw Inf6WatchConnectivityPhoneError.notPaired
        }
        guard session.isWatchAppInstalled else {
            throw Inf6WatchConnectivityPhoneError.watchAppNotInstalled
        }

        try session.updateApplicationContext(payload)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        guard error == nil, activationState == .activated else { return }
        _flushPendingIfPossible(using: session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    private func _enqueuePending(_ payload: [String: Any]) {
        stateQueue.sync {
            for (key, value) in payload {
                pendingApplicationContext[key] = value
            }
        }
    }

    private func _drainPending() -> [String: Any] {
        stateQueue.sync {
            let payload = pendingApplicationContext
            pendingApplicationContext = [:]
            return payload
        }
    }

    private func _restorePending(_ payload: [String: Any]) {
        guard !payload.isEmpty else { return }
        stateQueue.sync {
            for (key, value) in payload {
                pendingApplicationContext[key] = value
            }
        }
    }

    private func _flushPendingIfPossible(using session: WCSession) {
        guard session.activationState == .activated else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }

        let payload = _drainPending()
        guard !payload.isEmpty else { return }

        do {
            try session.updateApplicationContext(payload)
        } catch {
            _restorePending(payload)
        }
    }
}
