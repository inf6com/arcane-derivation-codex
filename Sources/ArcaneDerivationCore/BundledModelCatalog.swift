import CoreML
import Foundation

public struct BundledModelStatus: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let resourceName: String
    public let available: Bool
    public let loadFailure: String?

    public init(id: String, displayName: String, resourceName: String, available: Bool, loadFailure: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.resourceName = resourceName
        self.available = available
        self.loadFailure = loadFailure
    }
}

public struct BundledModelCatalog {
    public init() {}

    public func statuses(bundle: Bundle = .main) -> [BundledModelStatus] {
        [
            status(
                id: "document-layout",
                displayName: "図・表・数式領域検出",
                resourceName: "yolo11n_doc_layout",
                bundle: bundle
            ),
            status(
                id: "text-embedding",
                displayName: "テキスト埋め込み",
                resourceName: "Inf6TextEmbedding",
                bundle: bundle
            ),
            status(
                id: "formula-vision-encoder",
                displayName: "数式画像特徴抽出（TexTeller）",
                resourceName: "TexTellerEncoder",
                bundle: bundle
            ),
            status(
                id: "formula-token-decoder-init",
                displayName: "数式トークン初回生成（TexTeller）",
                resourceName: "TexTellerDecoderInit",
                bundle: bundle
            ),
            status(
                id: "formula-token-decoder-kv",
                displayName: "数式トークン生成（TexTeller・KVキャッシュ）",
                resourceName: "TexTellerDecoderKV",
                bundle: bundle
            ),
            status(
                id: "hinotori-fold7-isolated-symbol",
                displayName: "火の鳥・一記号分類（Fold-07）",
                resourceName: "HinotoriFold7Classifier",
                bundle: bundle
            ),
            status(
                id: "hinotori-typeset-candidates",
                displayName: "火の鳥・活字記号候補",
                resourceName: "HinotoriTypesetAuxiliaryHead",
                bundle: bundle
            )
        ]
    }

    private func status(
        id: String,
        displayName: String,
        resourceName: String,
        bundle: Bundle
    ) -> BundledModelStatus {
        guard let url = bundle.url(forResource: resourceName, withExtension: "mlmodelc")
                ?? bundle.url(forResource: resourceName, withExtension: "mlpackage") else {
            return BundledModelStatus(
                id: id,
                displayName: displayName,
                resourceName: resourceName,
                available: false,
                loadFailure: "アプリ内モデルが見つかりません。"
            )
        }

        do {
            _ = try MLModel(contentsOf: url)
            return BundledModelStatus(
                id: id,
                displayName: displayName,
                resourceName: resourceName,
                available: true
            )
        } catch {
            return BundledModelStatus(
                id: id,
                displayName: displayName,
                resourceName: resourceName,
                available: false,
                loadFailure: error.localizedDescription
            )
        }
    }
}
