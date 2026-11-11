//
//  Inf6CorePaperModels.swift
//  inf6
//
//  E資格 Core Paper — データモデル定義
//  metadata file store に保存された代表論文セットの進捗・スケジュール管理に使うモデル。
//

import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum Inf6LearningDomainKind: String, Codable, CaseIterable, Identifiable {
    case qualification
    case standard
    case paper
    case technicalSubject

    var id: String { rawValue }

    func title(isJapanese: Bool) -> String {
        switch self {
        case .qualification: return isJapanese ? "資格" : "Qualification"
        case .standard: return isJapanese ? "規格" : "Standard"
        case .paper: return isJapanese ? "論文" : "Paper"
        case .technicalSubject: return isJapanese ? "技術分野" : "Technical subject"
        }
    }
}

struct Inf6LearningDomain: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let kind: Inf6LearningDomainKind
    let sourceURL: URL?
    let isPreset: Bool
    let createdAt: Date?

    static let eQualification = Inf6LearningDomain(
        id: "e-qualification",
        name: "E資格",
        kind: .qualification,
        sourceURL: URL(string: "https://www.jdla.org/certificate/engineer/"),
        isPreset: true,
        createdAt: nil
    )
}

enum Inf6LearningDomainStore {
    private static let activeDomainKey = "active_learning_domain_id"

    static func load() throws -> (domains: [Inf6LearningDomain], activeID: String) {
        let records = try Inf6MetadataStore.listAllStrict(domain: .knowledgeDomains).map { row -> Inf6LearningDomain in
            guard let data = row.json.data(using: .utf8) else {
                throw NSError(domain: "Inf6LearningDomainStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "分野データをUTF-8として読めません: \(row.key)"])
            }
            do {
                let domain = try JSONDecoder().decode(Inf6LearningDomain.self, from: data)
                guard domain.id == row.key, domain.id != Inf6LearningDomain.eQualification.id else {
                    throw NSError(domain: "Inf6LearningDomainStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "分野IDと保存キーが一致しないか、プリセットIDを使用しています: \(row.key)"])
                }
                return domain
            } catch {
                throw NSError(domain: "Inf6LearningDomainStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "分野データを読み込めません (\(row.key)): \(error.localizedDescription)"])
            }
        }
        let domains = [Inf6LearningDomain.eQualification] + records.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let settings = try Inf6MetadataStore.listAllStrict(domain: .settings)
        let activeID = settings.first(where: { $0.key == activeDomainKey })?.json ?? Inf6LearningDomain.eQualification.id
        guard domains.contains(where: { $0.id == activeID }) else {
            throw NSError(domain: "Inf6LearningDomainStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "選択中の分野が保存一覧にありません: \(activeID)"])
        }
        return (domains, activeID)
    }

    @discardableResult
    static func add(name rawName: String, kind: Inf6LearningDomainKind, source rawSource: String) throws -> Inf6LearningDomain {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else {
            throw NSError(domain: "Inf6LearningDomainStore", code: 5, userInfo: [NSLocalizedDescriptionKey: "分野名は1〜100文字で入力してください。"])
        }
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceURL: URL?
        if source.isEmpty {
            sourceURL = nil
        } else if let components = URLComponents(string: source),
                  let url = components.url,
                  ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
                  components.host?.isEmpty == false {
            sourceURL = url
        } else {
            throw NSError(domain: "Inf6LearningDomainStore", code: 6, userInfo: [NSLocalizedDescriptionKey: "出典URLはhttpまたはhttpsの完全なURLで入力してください。"])
        }
        let existing = try load().domains
        guard !existing.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw NSError(domain: "Inf6LearningDomainStore", code: 7, userInfo: [NSLocalizedDescriptionKey: "同じ名前の分野がすでに登録されています。"])
        }
        let domain = Inf6LearningDomain(
            id: "user-\(UUID().uuidString.lowercased())",
            name: name,
            kind: kind,
            sourceURL: sourceURL,
            isPreset: false,
            createdAt: .now
        )
        guard Inf6MetadataStore.putCodable(domain, domain: .knowledgeDomains, key: domain.id) else {
            throw NSError(domain: "Inf6LearningDomainStore", code: 8, userInfo: [NSLocalizedDescriptionKey: "分野をUser Setting Rootへ保存できませんでした。保存先の状態を確認してください。"])
        }
        return domain
    }

    static func select(id: String) throws {
        guard try load().domains.contains(where: { $0.id == id }) else {
            throw NSError(domain: "Inf6LearningDomainStore", code: 9, userInfo: [NSLocalizedDescriptionKey: "選択対象の分野が登録されていません: \(id)"])
        }
        guard Inf6MetadataStore.put(domain: .settings, key: activeDomainKey, json: id) else {
            throw NSError(domain: "Inf6LearningDomainStore", code: 10, userInfo: [NSLocalizedDescriptionKey: "選択中の分野をUser Setting Rootへ保存できませんでした。"])
        }
    }
}

struct Inf6PDFReferenceRecord: Codable, Hashable {
    var version: Int?
    var fileName: String
    var absolutePath: String?
    var originalURLString: String?
    var originalPath: String?
    var contentKey: String?
    var importedAt: String?
    var registeredAtMs: Double?
    var bookmarkBase64: String?
    var title: String?
    var provider: String?
    var sourceUrl: String?
    var abstract: String?
    var learningDomainIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case version
        case fileName
        case absolutePath
        case originalURLString
        case originalPath
        case contentKey
        case importedAt
        case registeredAtMs
        case bookmarkBase64
        case title
        case provider
        case sourceUrl
        case abstract
        case learningDomainIDs
    }

    var resolvedPath: String {
        let direct = (absolutePath ?? originalPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty { return direct }
        guard let raw = originalURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              url.isFileURL
        else { return "" }
        return url.path
    }
}

enum Inf6PDFReferenceStore {
    static func list() throws -> [Inf6PDFReferenceRecord] {
        try Inf6MetadataStore.listAll(domain: .pdfRefs).map { row in
            guard let data = row.json.data(using: .utf8) else {
                throw NSError(domain: "Inf6PDFReferenceStore", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "PDF reference JSON is not UTF-8: \(row.key)"
                ])
            }
            let record = try JSONDecoder().decode(Inf6PDFReferenceRecord.self, from: data)
            guard !record.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "Inf6PDFReferenceStore", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "PDF reference fileName is empty: \(row.key)"
                ])
            }
            guard !record.resolvedPath.isEmpty else {
                throw NSError(domain: "Inf6PDFReferenceStore", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "PDF reference path is empty: \(row.key)"
                ])
            }
            return record
        }.filter { FileManager.default.fileExists(atPath: $0.resolvedPath) }
    }

    static func first(fileName: String) throws -> Inf6PDFReferenceRecord? {
        let normalized = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let matches = try list().filter { $0.fileName == normalized }
        if matches.count > 1 {
            throw NSError(domain: "Inf6PDFReferenceStore", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "PDF reference fileName is ambiguous: \(normalized)"
            ])
        }
        return matches.first
    }

    static func put(url: URL, learningDomainID: String? = nil) throws {
        guard url.isFileURL else {
            throw NSError(domain: "Inf6PDFReferenceStore", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "PDF reference URL is not a file URL: \(url.absoluteString)"
            ])
        }
        guard url.pathExtension.lowercased() == "pdf" else {
            throw NSError(domain: "Inf6PDFReferenceStore", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "PDF reference URL does not point to a PDF: \(url.path)"
            ])
        }
        try _validatePDFHeader(at: url)

        let key = try _sha256(of: url)
        let papersDirectory = Inf6LocalStore.url(.papers).standardizedFileURL
        let persistedURL = papersDirectory.appendingPathComponent("\(key).pdf", isDirectory: false)
        let fileManager = FileManager.default
        var createdPersistedFile = false
        try fileManager.createDirectory(at: papersDirectory, withIntermediateDirectories: true)

        if persistedURL.standardizedFileURL != url.standardizedFileURL {
            if fileManager.fileExists(atPath: persistedURL.path) {
                let existingDigest = try _sha256(of: persistedURL)
                guard existingDigest == key else {
                    throw NSError(domain: "Inf6PDFReferenceStore", code: 9, userInfo: [
                        NSLocalizedDescriptionKey: "Persisted PDF content does not match the selected source: \(persistedURL.path)"
                    ])
                }
            } else {
                let temporaryURL = papersDirectory.appendingPathComponent(".import-\(UUID().uuidString).pdf", isDirectory: false)
                var coordinatorError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(
                    readingItemAt: url,
                    options: [],
                    error: &coordinatorError
                ) { readableURL in
                    do {
                        try fileManager.copyItem(at: readableURL, to: temporaryURL)
                    } catch {
                        copyError = error
                    }
                }
                if let coordinatorError {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw coordinatorError
                }
                if let copyError {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw copyError
                }
                do {
                    let copiedDigest = try _sha256(of: temporaryURL)
                    guard copiedDigest == key else {
                        throw NSError(domain: "Inf6PDFReferenceStore", code: 10, userInfo: [
                            NSLocalizedDescriptionKey: "Temporary PDF digest does not match the selected source: \(temporaryURL.path)"
                        ])
                    }
                    try fileManager.moveItem(at: temporaryURL, to: persistedURL)
                    createdPersistedFile = true
                } catch {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw error
                }
            }
        }

        do {
            let persistedDigest = try _sha256(of: persistedURL)
            guard persistedDigest == key else {
                throw NSError(domain: "Inf6PDFReferenceStore", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "Saved PDF digest does not match the selected source: \(persistedURL.path)"
                ])
            }
        } catch {
            if createdPersistedFile {
                try? fileManager.removeItem(at: persistedURL)
            }
            throw error
        }
        var learningDomainIDs: [String] = []
        if let existingReference = try Inf6MetadataStore.listAllStrict(domain: .pdfRefs).first(where: { $0.key == key }) {
            guard let data = existingReference.json.data(using: .utf8) else {
                throw NSError(domain: "Inf6PDFReferenceStore", code: 13, userInfo: [NSLocalizedDescriptionKey: "既存PDFの分野関連付けを読み込めません。"])
            }
            learningDomainIDs = try JSONDecoder().decode(Inf6PDFReferenceRecord.self, from: data).learningDomainIDs ?? []
        }
        if let learningDomainID, !learningDomainIDs.contains(learningDomainID) {
            learningDomainIDs.append(learningDomainID)
        }
        let record = Inf6PDFReferenceRecord(
            version: 2,
            fileName: url.lastPathComponent,
            absolutePath: persistedURL.path,
            originalURLString: url.standardizedFileURL.absoluteString,
            originalPath: url.standardizedFileURL.path,
            contentKey: key,
            importedAt: ISO8601DateFormatter().string(from: Date()),
            registeredAtMs: Date().timeIntervalSince1970 * 1000,
            bookmarkBase64: try bookmarkBase64(for: persistedURL),
            title: url.deletingPathExtension().lastPathComponent,
            provider: nil,
            sourceUrl: nil,
            abstract: nil,
            learningDomainIDs: learningDomainIDs
        )
        let data = try JSONEncoder().encode(record)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Inf6PDFReferenceStore", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "PDF reference JSON encode failed: \(url.path)"
            ])
        }
        guard Inf6MetadataStore.put(domain: .pdfRefs, key: key, json: json) else {
            throw NSError(domain: "Inf6PDFReferenceStore", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "PDF reference metadata could not be saved: \(url.path)"
            ])
        }
    }

    private static func _validatePDFHeader(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 1024) ?? Data()
        guard prefix.range(of: Data("%PDF-".utf8)) != nil else {
            throw NSError(domain: "Inf6PDFReferenceStore", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Selected file is not a PDF byte stream: \(url.path)"
            ])
        }
    }

    private static func _sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
            if bytes.isEmpty { break }
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func bookmarkBase64(for url: URL) throws -> String {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        return data.base64EncodedString()
    }
}

// MARK: - ローカル保存の構成

/// 端末に置く実体データの置き場。
///
/// PDF、図表画像、metadata は同じ root に置く。端末間共有は
/// `Inf6DataExchange` の zip export/import だけで行う。
///
///     <選んだ場所>/inf6/
///       figures/   図・表・数式の画像   派生物。PDFから作り直せる
///       papers/    論文PDF            取得元が消えることがあり、失いたくない
///
/// 場所を変えたときは、この構成ごと移す。
public enum Inf6LocalStore {

    public enum Folder: String, CaseIterable, Sendable {
        case figures
        case papers

        public func label(ja: Bool) -> String {
            switch self {
            case .figures: return ja ? "図・表・数式の画像" : "Figure images"
            case .papers:  return ja ? "論文PDF" : "Paper PDFs"
            }
        }
    }

    /// 実体を置く根。記録と同じ場所に揃える。
    public static func rootURL() -> URL {
        Inf6DataRoot.url()
    }

    public static func url(_ folder: Folder) -> URL {
        rootURL().appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    private static func regularFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let walker = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in walker {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            files.append(url)
        }
        return files
    }

    /// 置き場所を変えたときに、構成ごと移す。
    /// 移動先に同名があれば飛ばす。途中で止めても残りは次回続きから移せる。
    public static func migrate(
        from oldRoot: URL,
        to newRoot: URL,
        progress: @escaping @Sendable (_ done: Int, _ total: Int, _ name: String) async -> Void
    ) async -> (moved: Int, skipped: Int, failed: Int) {
        let fm = FileManager.default
        var moved = 0, skipped = 0, failed = 0

        var jobs: [(src: URL, dst: URL, name: String)] = []
        for folder in Folder.allCases {
            let src = oldRoot.appendingPathComponent(folder.rawValue, isDirectory: true)
            guard fm.fileExists(atPath: src.path) else { continue }
            for url in regularFiles(in: src, fileManager: fm) {
                let rel = url.path.replacingOccurrences(of: src.path + "/", with: "")
                jobs.append((
                    url,
                    newRoot.appendingPathComponent(folder.rawValue, isDirectory: true).appendingPathComponent(rel),
                    url.lastPathComponent
                ))
            }
        }

        for (index, job) in jobs.enumerated() {
            if Task.isCancelled { break }
            if fm.fileExists(atPath: job.dst.path) {
                skipped += 1
                try? fm.removeItem(at: job.src)
                continue
            }
            await progress(index + 1, jobs.count, job.name)
            do {
                try fm.createDirectory(at: job.dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                // 別ボリュームへは move できないことがあるので、複製してから消す。
                guard let data = Inf6SafeFileRead.dataIfReadable(at: job.src) else {
                    failed += 1
                    continue
                }
                try data.write(to: job.dst, options: [.atomic])
                try? fm.removeItem(at: job.src)
                moved += 1
            } catch {
                NSLog("[LocalStore] migrate failed for %@: %@", job.name, String(describing: error))
                failed += 1
            }
        }
        NSLog("[LocalStore] migrate done: moved=%d skipped=%d failed=%d", moved, skipped, failed)
        return (moved, skipped, failed)
    }
}

// MARK: - 保存 root

/// 保存 root を置く場所。
///
/// 図表画像、論文PDF、metadata、knowledge card を同じ root に置く。
/// 外付けSSDなど任意の場所を選べるようにする。
public enum Inf6EntityImageLocation {

    private static let _bookmarkKey = "inf6_storage_root_bookmark"
    private static let _displayPathKey = "inf6_storage_root_path"

    /// 設定画面に出す表示用のパス。未選択なら nil。
    public static var displayPath: String? {
        let raw = UserDefaults.standard.string(forKey: _displayPathKey)
        let v = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// 端末上に保存先の設定値はあるが、現在は到達できない状態。
    ///
    /// ここで黙って別 root へ切り替えると、Mac で作った演習が iPad では消えたように見える。
    /// 設定を選び直してもらう必要があるため、到達不能を明示的に扱う。
    public static var hasUnavailableStoredSelection: Bool {
        guard displayPath != nil else { return false }
        return resolvedURL() == nil
    }

    /// 保存 root をローカル metadata に記録する。
    private static func _writeLocationMarker(path: String?, deviceName: String) throws {
        let payload: [String: Any] = [
            "kind": "storage_root",
            "device": deviceName,
            "path": path ?? "",
            "updatedAt": Date().timeIntervalSince1970,
            "note": "保存 root はユーザーが選択したフォルダにあります。"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Inf6EntityImageLocation", code: 1, userInfo: [NSLocalizedDescriptionKey: "保存先の場所情報をJSONに変換できませんでした。"])
        }
        guard Inf6MetadataStore.put(domain: .settings, key: "storage_root_location:\(deviceName)", json: json) else {
            throw NSError(domain: "Inf6EntityImageLocation", code: 2, userInfo: [NSLocalizedDescriptionKey: "保存先の場所情報を選択したフォルダへ保存できませんでした。"])
        }
    }

    private static var _deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "this-device"
        #endif
    }

    public static func set(_ folderURL: URL) throws {
        let selectedURL = folderURL.standardizedFileURL
        guard selectedURL.isFileURL else {
            throw NSError(domain: "Inf6EntityImageLocation", code: 3, userInfo: [NSLocalizedDescriptionKey: "保存先にはローカルのフォルダURLを選択してください。"])
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "Inf6EntityImageLocation", code: 4, userInfo: [NSLocalizedDescriptionKey: "選択した保存先フォルダが見つかりません。"])
        }

        let accessed = selectedURL.startAccessingSecurityScopedResource()
        defer { if accessed { selectedURL.stopAccessingSecurityScopedResource() } }

        let probe = selectedURL.appendingPathComponent(".inf6-root-write-probe-\(UUID().uuidString)")
        try Data().write(to: probe, options: .atomic)
        try FileManager.default.removeItem(at: probe)

        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let data = try selectedURL.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        let bookmarkB64 = data.base64EncodedString()
        let defaults = UserDefaults.standard
        let previousBookmark = defaults.string(forKey: _bookmarkKey)
        let previousDisplayPath = defaults.string(forKey: _displayPathKey)
        let previousResolved = _resolveBookmarkURL(base64Key: _bookmarkKey)

        defaults.set(bookmarkB64, forKey: _bookmarkKey)
        defaults.set(selectedURL.path, forKey: _displayPathKey)
        Inf6DataRoot.invalidate()
        Inf6MetadataStore.invalidateCachesForRootChange()
        do {
            guard resolvedURL()?.standardizedFileURL == selectedURL else {
                throw NSError(domain: "Inf6EntityImageLocation", code: 5, userInfo: [NSLocalizedDescriptionKey: "選択したフォルダの保存権限を再確認できませんでした。別のフォルダを選んでください。"])
            }
            try _writeLocationMarker(path: selectedURL.path, deviceName: _deviceName)
        } catch {
            if let previousBookmark {
                defaults.set(previousBookmark, forKey: _bookmarkKey)
            } else {
                defaults.removeObject(forKey: _bookmarkKey)
            }
            if let previousDisplayPath {
                defaults.set(previousDisplayPath, forKey: _displayPathKey)
            } else {
                defaults.removeObject(forKey: _displayPathKey)
            }
            Inf6DataRoot.invalidate()
            Inf6MetadataStore.invalidateCachesForRootChange()
            if previousResolved == nil, previousBookmark == nil {
                throw NSError(domain: "Inf6EntityImageLocation", code: 6, userInfo: [NSLocalizedDescriptionKey: "保存先を確定できませんでした。選択内容を取り消しました。\n\(error.localizedDescription)"])
            }
            throw error
        }
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: _bookmarkKey)
        UserDefaults.standard.removeObject(forKey: _displayPathKey)
        Inf6DataRoot.invalidate()
        Inf6MetadataStore.invalidateCachesForRootChange()
    }

    private static func _resolveBookmarkURL(base64Key: String) -> URL? {
        guard let b64 = UserDefaults.standard.string(forKey: base64Key),
              let data = Data(base64Encoded: b64) else { return nil }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        return try? URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ).standardizedFileURL
    }

    /// ユーザーが設定した保存先。未選択・解決不能なら nil を返す。
    public static func resolvedURL() -> URL? {
        guard let url = _resolveBookmarkURL(base64Key: _bookmarkKey) else { return nil }

        // A bookmark outside the app container is not readable until its security
        // scope has started. Check existence only after acquiring that access.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("[StorageRoot] chosen folder is not available: %@", url.path)
            return nil
        }

        // 存在していても、Files/File Provider の表示先には書けない場合がある。
        // 起動後の metadata 書き込みまで進めず、初期設定で保存先を選び直させる。
        do {
            let fm = FileManager.default
            let probeDirectories = [
                url.appendingPathComponent("metadata", isDirectory: true),
                url.appendingPathComponent("settings", isDirectory: true),
                url.appendingPathComponent("mma", isDirectory: true)
            ]
            for directory in probeDirectories {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let probe = directory.appendingPathComponent(
                    ".inf6-write-probe-\(UUID().uuidString)",
                    isDirectory: false
                )
                try Data().write(to: probe, options: .atomic)
                try fm.removeItem(at: probe)
            }

            // Existing family folders can retain File Provider permissions that differ
            // from the parent folder, so probe each one before accepting the root.
            if let familyURLs = try? fm.contentsOfDirectory(
                at: url.appendingPathComponent("mma", isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for familyURL in familyURLs {
                    guard (try? familyURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    let probe = familyURL.appendingPathComponent(
                        ".inf6-write-probe-\(UUID().uuidString)",
                        isDirectory: false
                    )
                    try Data().write(to: probe, options: .atomic)
                    try fm.removeItem(at: probe)
                }
            }
        } catch {
            NSLog("[StorageRoot] chosen folder is not writable: %@ / %@", url.path, error.localizedDescription)
            return nil
        }
        return url
    }
}

// MARK: - データを置く唯一の根

/// アプリのデータを置く根。ここ一つに揃える。
///
/// すべてのアプリデータを、利用者が設定した単一の User Setting Root に集約する。
///
    /// 保存 root はユーザーが設定した場所だけを使用する。
    /// 未設定・到達不能時に別の root へ切り替えることは禁止する。
public enum Inf6DataRoot {

    private static let _lock = NSLock()
    private static var _cached: URL?

    /// 利用者が選んだ場所は、書く前に権限を開始しないと保存に失敗する。
    ///
    /// User Setting Root は利用者が選んだ場所であるため、保存前に権限を取得する。
    ///
    /// 根は起動中ずっと使う。呼ぶたびに開始と終了を繰り返すと、書いている
    /// 途中で別の経路が終了させてしまう。一度開始して保持する。
    private static func _beginAccess(_ url: URL) -> URL {
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    public static func url() -> URL {
        _lock.lock()
        defer { _lock.unlock() }
        if let cached = _cached { return cached }

        let resolved = _resolve()
        _cached = resolved
        return resolved
    }

    /// 保存先が変更されたときに、次回の解決をやり直させる。
    public static func invalidate() {
        _lock.lock()
        defer { _lock.unlock() }
        _cached = nil
    }

    private static func _resolve() -> URL {
        guard let chosen = Inf6EntityImageLocation.resolvedURL() else {
            let configured = Inf6EntityImageLocation.displayPath ?? "未設定"
            preconditionFailure("[DataRoot] user-configured storage root is unavailable: \(configured)")
        }
        return _beginAccess(chosen)
    }
}

// MARK: - 図表数式画像の実体ストア

/// 図・表・数式の画像の実体を扱う。
///
/// 置き場所は端末ローカルまたはユーザーが選択した root だけである。
public enum Inf6EntityImageStore {

    /// 表示と保存に使うローカルの置き場。構成は Inf6LocalStore が決める。
    public static func localBaseURL() -> URL {
        Inf6LocalStore.url(.figures)
    }

    /// 生成時の保存。
    public static func write(_ data: Data, relativePath: String) throws {
        let local = localBaseURL().appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: local, options: [.atomic])
    }

    /// 表示のために実体を用意する。ローカルにある場合だけ返す。
    public static func ensureLocalFile(relativePath: String) async -> URL? {
        let fm = FileManager.default
        let local = localBaseURL().appendingPathComponent(relativePath)
        if fm.fileExists(atPath: local.path) { return local }
        return nil
    }

    private static func imageRelativePaths(in base: URL, fileManager: FileManager) -> [String] {
        guard let walker = fileManager.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        var relatives: [String] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".png") || name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") else {
                continue
            }
            relatives.append(url.path.replacingOccurrences(of: base.path + "/", with: ""))
        }
        return relatives.sorted()
    }

    /// 保存先を変えたときに、既存の画像を新しい場所へ移す。
    ///
    /// 移さないと、これまでに作った図が古い場所に取り残される。表示側は
    /// 新しい場所しか見ないため、作り直すまで出てこなくなる。
    /// 移動先に同名があれば飛ばし、移し終えたものだけ元を消す。
    /// 途中で止めても、残りは次回の続きから移せる。
    public static func migrate(
        from oldBase: URL,
        to newBase: URL,
        progress: @escaping @Sendable (_ done: Int, _ total: Int, _ name: String) async -> Void
    ) async -> (moved: Int, skipped: Int, failed: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldBase.path) else {
            return (0, 0, 0)
        }
        let relatives = imageRelativePaths(in: oldBase, fileManager: fm)

        var moved = 0, skipped = 0, failed = 0
        for (index, rel) in relatives.enumerated() {
            if Task.isCancelled { break }
            let src = oldBase.appendingPathComponent(rel)
            let dst = newBase.appendingPathComponent(rel)
            if fm.fileExists(atPath: dst.path) {
                skipped += 1
                try? fm.removeItem(at: src)
                continue
            }
            await progress(index + 1, relatives.count, (rel as NSString).lastPathComponent)
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                // 別ボリュームへは move できないことがあるので、複製してから消す。
                guard let data = Inf6SafeFileRead.dataIfReadable(at: src) else {
                    failed += 1
                    continue
                }
                try data.write(to: dst, options: [.atomic])
                try? fm.removeItem(at: src)
                moved += 1
            } catch {
                NSLog("[EntityImageStore] migrate failed for %@: %@", rel, String(describing: error))
                failed += 1
            }
        }
        NSLog("[EntityImageStore] migrate done: moved=%d skipped=%d failed=%d", moved, skipped, failed)
        return (moved, skipped, failed)
    }

    /// ローカル実体が現れるまで読む。外部同期からの取得は行わない。
    private static func _readWhenAvailable(_ url: URL, timeoutSeconds: Double = 90) async -> Data? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let data = Inf6SafeFileRead.dataIfReadable(at: url), !data.isEmpty {
                return data
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return nil }
        }
        NSLog("[EntityImageStore] timed out waiting for %@", url.lastPathComponent)
        return nil
    }
}

// MARK: - Core Paper

struct Inf6CorePaper: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let titleEn: String?
    let provider: String          // "arxiv" | "direct"
    let arxivId: String?          // arxiv_id
    let pdfURL: String?           // pdf_url (direct provider)
    let year: Int?                // publication year
    let tags: [String]
    /// arXiv / OpenAlex から取得した原文の Abstract。論文概要としてそのまま提示する。
    /// 既存レコードには存在しないため optional。
    var abstract: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, provider, tags, year, abstract
        case titleEn = "title_en"
        case arxivId = "arxiv_id"
        case pdfURL  = "pdf_url"
    }

    /// PDF URL — resolves local shared PDFs first, then remote URLs.
    var resolvedPDFURL: URL? {
        if let local = _localPapersPDF() { return local }
        if let raw = pdfURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let u = URL(string: raw), u.scheme != nil { return u }
        }
        if let aid = arxivId {
            return URL(string: "https://arxiv.org/pdf/\(aid)")
        }
        return nil
    }

    func _localPapersPDFPublic() -> URL? { _localPapersPDF() }

    private func _localPapersPDF() -> URL? {
        let fm = FileManager.default
        let bases: [URL] = [Inf6LocalStore.url(.papers)]

        var candidates: [URL] = []
        for base in bases {
            let titleKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: title)
            let titleEnKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: titleEn ?? "")
            // 直下
            if !titleKey.isEmpty {
                candidates.append(base.appendingPathComponent("\(titleKey).pdf"))
            }
            if !titleEnKey.isEmpty, titleEnKey != titleKey {
                candidates.append(base.appendingPathComponent("\(titleEnKey).pdf"))
            }
            // サブディレクトリ
            candidates.append(base.appendingPathComponent("\(provider)/\(id).pdf"))
            candidates.append(base.appendingPathComponent("arxiv/\(id).pdf"))
            candidates.append(base.appendingPathComponent("direct/\(id).pdf"))
            if !titleKey.isEmpty {
                candidates.append(base.appendingPathComponent("\(provider)/\(titleKey).pdf"))
                candidates.append(base.appendingPathComponent("arxiv/\(titleKey).pdf"))
                candidates.append(base.appendingPathComponent("direct/\(titleKey).pdf"))
            }
            if !titleEnKey.isEmpty, titleEnKey != titleKey {
                candidates.append(base.appendingPathComponent("\(provider)/\(titleEnKey).pdf"))
                candidates.append(base.appendingPathComponent("arxiv/\(titleEnKey).pdf"))
                candidates.append(base.appendingPathComponent("direct/\(titleEnKey).pdf"))
            }
            if let raw = pdfURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
               URL(string: raw)?.scheme == nil {
                candidates.append(base.appendingPathComponent(raw))
                candidates.append(base.appendingPathComponent("\(provider)/\(raw)"))
                for tag in tags where !tag.isEmpty {
                    candidates.append(base.appendingPathComponent("\(tag)/\(raw)"))
                }
            }
        }
        let uniqueCandidates = candidates.reduce(into: [URL]()) { result, candidate in
            let path = candidate.standardizedFileURL.path
            if !result.contains(where: { $0.standardizedFileURL.path == path }) {
                result.append(candidate)
            }
        }
        return uniqueCandidates.first(where: { fm.fileExists(atPath: $0.path) })
    }

    var resolvedAbsURL: URL? {
        if provider == "arxiv", let aid = arxivId {
            return URL(string: "https://arxiv.org/abs/\(aid)")
        }
        return resolvedPDFURL
    }
}

// MARK: - Learning Order Category

enum Inf6CorePaperCategory: String, CaseIterable, Identifiable, Codable {
    case mathFoundation     = "math"
    case optimization       = "optimization"
    case cnnBasics          = "cnn_basics"
    case normReg            = "norm_reg"
    case detection          = "detection"
    case segmentation       = "segmentation"
    case rnnAttention       = "rnn_attention"
    case transformer        = "transformer"
    case nlpEmbeddings      = "nlp_embeddings"
    case generative         = "generative"
    case selfSupervised     = "self_supervised"
    case reinforcement      = "reinforcement"
    case edge               = "edge"
    case xai                = "xai"
    case gnn                = "gnn"
    case metaLearning       = "meta_learning"
    case audio              = "audio"
    case diffusion          = "diffusion"
    case multimodal         = "multimodal"
    case curriculum         = "curriculum"
    case other              = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mathFoundation: return "数学的基礎"
        case .optimization:   return "最適化・正規化"
        case .cnnBasics:      return "CNN 基礎"
        case .normReg:        return "正規化・正則化"
        case .detection:      return "物体検出"
        case .segmentation:   return "セグメンテーション"
        case .rnnAttention:   return "RNN / Attention"
        case .transformer:    return "Transformer"
        case .nlpEmbeddings:  return "NLP / Embeddings"
        case .generative:     return "生成モデル"
        case .selfSupervised: return "自己教師あり学習"
        case .reinforcement:  return "強化学習"
        case .edge:           return "エッジ / 軽量化"
        case .xai:            return "説明可能 AI"
        case .gnn:            return "グラフニューラルネット"
        case .metaLearning:   return "メタ学習"
        case .audio:          return "音声処理"
        case .diffusion:      return "拡散モデル"
        case .multimodal:     return "マルチモーダル"
        case .curriculum:     return "実装カリキュラム"
        case .other:          return "その他"
        }
    }

    /// 推奨学習順（小さいほど先）
    var recommendedOrder: Int {
        switch self {
        case .mathFoundation: return 0
        case .optimization:   return 1
        case .cnnBasics:      return 2
        case .normReg:        return 3
        case .rnnAttention:   return 4
        case .transformer:    return 5
        case .nlpEmbeddings:  return 6
        case .detection:      return 7
        case .segmentation:   return 8
        case .generative:     return 9
        case .selfSupervised: return 10
        case .reinforcement:  return 11
        case .edge:           return 12
        case .xai:            return 13
        case .gnn:            return 14
        case .metaLearning:   return 15
        case .audio:          return 16
        case .diffusion:      return 17
        case .multimodal:     return 18
        case .curriculum:     return 50
        case .other:          return 99
        }
    }

    /// tags から カテゴリを推定
    static func infer(from tags: [String]) -> Inf6CorePaperCategory {
        let t = tags.map { $0.lowercased() }
        if t.contains(where: { $0.contains("math") || $0.contains("statistic") || $0.contains("probability") || $0.contains("linear_algebra") || $0.contains("ml_basics") || $0.contains("information_theory") }) { return .mathFoundation }
        if t.contains("reinforcement_learning") || t.contains("deep_rl") { return .reinforcement }
        if t.contains("gnn") { return .gnn }
        if t.contains("meta_learning") { return .metaLearning }
        if t.contains("audio") { return .audio }
        if t.contains("xai") { return .xai }
        if t.contains("curriculum") || t.contains("pytorch") { return .curriculum }
        if t.contains("diffusion") { return .diffusion }
        if t.contains("multimodal") { return .multimodal }
        if t.contains("self_supervised") { return .selfSupervised }
        if t.contains("gan") || t.contains("vae") { return .generative }
        if t.contains("edge") || t.contains("efficient") || t.contains("compression") || t.contains("quantization") || t.contains("distillation") || t.contains("federated_learning") || t.contains("distributed") { return .edge }
        if t.contains("normalization") || t.contains("regularization") { return .normReg }
        if t.contains("optimization") { return .optimization }
        if t.contains("segmentation") { return .segmentation }
        if t.contains("detection") { return .detection }
        if t.contains("transformer") && (t.contains("nlp") || t.contains("pretraining") || t.contains("llm") || t.contains("nmt") || t.contains("rag") || t.contains("embeddings")) { return .nlpEmbeddings }
        if t.contains("rnn") || t.contains("gru") || t.contains("seq2seq") || t.contains("attention") { return .rnnAttention }
        if t.contains("transformer") { return .transformer }
        if t.contains("cnn") || t.contains("residual") || t.contains("imagenet") || t.contains("vit") || t.contains("vision") { return .cnnBasics }
        if t.contains("nlp") || t.contains("embeddings") { return .nlpEmbeddings }
        return .other
    }
}

// MARK: - Progress

enum Inf6CorePaperStatus: String, CaseIterable, Codable, Identifiable {
    case notStarted  = "not_started"
    case reading     = "reading"
    case done        = "done"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notStarted: return "未着手"
        case .reading:    return "学習中"
        case .done:       return "完了"
        }
    }

    var emoji: String {
        switch self {
        case .notStarted: return "⭕"
        case .reading:    return "📖"
        case .done:       return "✅"
        }
    }

    var color: String {   // SwiftUI Color name
        switch self {
        case .notStarted: return "gray"
        case .reading:    return "orange"
        case .done:       return "green"
        }
    }
}

struct Inf6CorePaperProgress: Codable, Identifiable {
    let paperId: String
    var status: Inf6CorePaperStatus
    /// 到達度 0 (未評価) … 5 (完全理解)
    var masteryScore: Int          // 0-5
    var keyPoints: String          // 自分メモ
    var lastStudiedAt: Date?

    var id: String { paperId }

    var achievementState: Inf6KnowledgeAchievementState {
        if status == .done || masteryScore >= 5 { return .measured }
        if masteryScore >= 4 { return .questioned }
        if masteryScore >= 3 { return .explained }
        if masteryScore >= 2 { return .annotating }
        if status == .reading || masteryScore >= 1 { return .reading }
        return .notStarted
    }

    init(paperId: String) {
        self.paperId = paperId
        self.status = .notStarted
        self.masteryScore = 0
        self.keyPoints = ""
        self.lastStudiedAt = nil
    }
}

// MARK: - Schedule Entry

struct Inf6CorePaperScheduleEntry: Codable, Identifiable {
    let paperId: String
    var plannedDate: Date?
    var estimatedHoursStr: String    // "2" / "1.5" etc.

    var id: String { paperId }

    init(paperId: String) {
        self.paperId = paperId
        self.plannedDate = nil
        self.estimatedHoursStr = ""
    }

    var estimatedHours: Double? {
        Double(estimatedHoursStr)
    }
}

// MARK: - Syllabus Coverage

/// E資格シラバス大項目と、それをカバーする論文タグの関連定義
struct Inf6SyllabusCoverageDefinition: Decodable {
    let syllabusSection: String    // シラバス大項目名
    let syllabusSectionEn: String
    let coveringTags: [String]     // 関連タグ
    /// E資格試験での出題比重が高い＝優先度高
    let isHighPriority: Bool

    enum CodingKeys: String, CodingKey {
        case syllabusSection = "syllabus_section"
        case syllabusSectionEn = "syllabus_section_en"
        case coveringTags = "covering_tags"
        case isHighPriority = "is_high_priority"
    }

    init(syllabusSection: String, syllabusSectionEn: String, coveringTags: [String], isHighPriority: Bool = false) {
        self.syllabusSection = syllabusSection
        self.syllabusSectionEn = syllabusSectionEn
        self.coveringTags = coveringTags
        self.isHighPriority = isHighPriority
    }

    static func loadDefinitions() throws -> [Inf6SyllabusCoverageDefinition] {
        guard let url = Bundle.main.url(forResource: "eshikaku_coverage", withExtension: "json") else {
            throw NSError(
                domain: "Inf6SyllabusCoverageDefinition",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "eshikaku_coverage.json is missing from bundle resources"]
            )
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Inf6SyllabusCoverageDefinition].self, from: data)
    }
}
