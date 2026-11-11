//
//  Inf6PaperSaveShared.swift
//  inf6
//

import Foundation

extension Notification.Name {
    static let inf6PaperPDFDidSave = Notification.Name("inf6PaperPDFDidSave")
}

enum Inf6PaperSaveShared {

    /// 論文PDFの置き場。取り込みも演習も、ここ1箇所を使う。
    ///
    /// かつて取り込みは manifests/tools/papers、演習は inf6/inf6_pdfs と
    /// 別々の場所を見ていた。同じ論文を二重に持ち、取り込み済みでも演習が
    /// もう一度ダウンロードしていた。
    static func defaultToolsPapersDirectoryURL() throws -> URL {
        let dir = Inf6LocalStore.url(.papers)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw NSError(
                domain: "Inf6PaperStorage",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create tools/papers directory: \(error.localizedDescription)"]
            )
        }
        return dir
    }

    static func safeFileName(title: String, fallbackID: String) throws -> String {
        func sanitize(_ raw: String) -> String {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
            let cleanedScalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            var s = String(cleanedScalars)
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "_")
            while s.contains("__") {
                s = s.replacingOccurrences(of: "__", with: "_")
            }
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }

        let titleRaw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let idRaw = fallbackID.trimmingCharacters(in: .whitespacesAndNewlines)

        let safeID = sanitize(idRaw)
        guard !safeID.isEmpty else {
            throw NSError(
                domain: "Inf6PaperStorage",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build a safe filename (id is empty after sanitization)."]
            )
        }

        let safeTitle = sanitize(titleRaw)
        let titlePart = safeTitle.isEmpty ? "paper" : String(safeTitle.prefix(96))
        let idPart = String(safeID.prefix(64))
        let combined = "\(titlePart)__\(idPart)"
        let clipped = String(combined.prefix(170)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !clipped.isEmpty else {
            throw NSError(
                domain: "Inf6PaperStorage",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build a safe filename (empty after sanitization)."]
            )
        }
        return "\(clipped).pdf"
    }

    static func downloadValidatedPDFData(from pdfURL: URL) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(from: pdfURL)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "Inf6PaperSave",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(status)): \(pdfURL.absoluteString)"]
            )
        }
        guard data.count >= 5, String(data: data.prefix(5), encoding: .ascii) == "%PDF-" else {
            throw NSError(
                domain: "Inf6PaperSave",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded content is not a PDF."]
            )
        }
        return data
    }

    static func classificationDirectoryName(
        title: String,
        abstractText: String,
        fallbackID: String,
        landingURL: URL?,
        pdfURL: URL?
    ) -> String {
        let text = _classificationNormalizedText(
            title: title,
            abstractText: abstractText,
            fallbackID: fallbackID,
            landingURL: landingURL,
            pdfURL: pdfURL
        )
        guard !text.isEmpty else { return "uncategorized" }

        let categories: [(name: String, keywords: [String])] = [
            (
                "speech_dialogue_asr",
                ["speech", "spoken", "asr", "dialogue", "dialog", "acoustic", "phoneme", "voice", "call center", "stt", "tts"]
            ),
            (
                "natural_language_processing",
                ["nlp", "language model", "transformer", "bert", "gpt", "token", "text", "translation", "summarization", "question answering", "retrieval"]
            ),
            (
                "computer_vision",
                ["image", "vision", "object detection", "segmentation", "video", "yolo", "cnn", "convnet", "recognition"]
            ),
            (
                "reinforcement_learning",
                ["reinforcement learning", "policy gradient", "q-learning", "bandit", "markov decision process", "mdp"]
            ),
            (
                "graph_machine_learning",
                ["graph neural", "gnn", "knowledge graph", "graph embedding", "graph attention"]
            ),
            (
                "optimization_training",
                ["optimization", "regularization", "dropout", "batch normalization", "sgd", "quantization", "pruning"]
            ),
            (
                "medical_biomedical",
                ["medical", "clinical", "biomedical", "genomics", "pathology", "healthcare"]
            ),
            (
                "multimodal",
                ["multimodal", "vision-language", "audio-visual", "cross-modal"]
            ),
        ]

        var bestName = "uncategorized"
        var bestScore = 0
        for c in categories {
            var score = 0
            for keyword in c.keywords {
                if text.contains(keyword) {
                    score += 1
                }
            }
            if score > bestScore {
                bestScore = score
                bestName = c.name
            }
        }
        return bestName
    }

    private static func _classificationNormalizedText(
        title: String,
        abstractText: String,
        fallbackID: String,
        landingURL: URL?,
        pdfURL: URL?
    ) -> String {
        let host = (
            landingURL?.host ??
            pdfURL?.host ??
            ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

        let blob = [
            title,
            abstractText,
            fallbackID,
            host,
        ]
        .joined(separator: " ")
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)

        if blob.isEmpty { return "" }
        return blob.replacingOccurrences(of: "\n", with: " ")
    }
}
