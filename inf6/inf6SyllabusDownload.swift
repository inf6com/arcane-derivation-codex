//
//  inf6SyllabusDownload.swift
//  inf6
//
//  Created by decopin on 2025/11/17.
//

import Foundation
import CryptoKit
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(Yams)
import Yams
#endif
#if canImport(PDFKit)
import PDFKit
#endif




// MARK: - シラバスダウンローダ & テキスト抽出 (共通基盤)


enum Inf6SyllabusError: Error {
    case configNotFound
    case invalidConfig(String)
    case badHTTPStatus(Int)
    case notPDFKitAvailable
}

// MARK: - Shared storage helper (single source of truth)

/// Shared storage paths used across the app.
///
/// This type is intentionally defined here so the project can build even if a separate
/// `Inf6Storage.swift` file is missing from the target.
public enum Inf6Storage {

    /// Returns the app home directory used for manifests/config.

    public static func homeDirectory() -> URL {
        let fm = FileManager.default

        // 記録の置き場も、実体と同じ根に揃える。
        let root = Inf6DataRoot.url()

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("""
            [Inf6Storage] Failed to create root folder at: \(root.path)
            Error: \(error)
            """)
        }

        return root
    }

    /// Returns the manifests directory under the app home.
    public static func manifestsDirectory() -> URL {
        let dir = homeDirectory().appendingPathComponent("manifests", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("""
            [Inf6Storage] Failed to create manifests directory at: \(dir.path)
            Error: \(error)
            """)
        }
        return dir
    }

    static func syllabusOutlineCacheURL() throws -> URL {
        let cacheDirectory = homeDirectory().appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let sharedURL = cacheDirectory.appendingPathComponent("syllabus_outline_cache.json")

        return sharedURL
    }

    // MARK: - Legacy directory scatter migration

    private static let _scatterMigrationFingerprintKey = "inf6_icloud_scatter_migration_fingerprint_v1"
    private static let _scatterMigrationLock = NSLock()

    public static func migrateScatteredDirectoriesIfNeeded() {
        return
    }

    public static func migrateScatteredDirectoriesNow(metadataDomains: Set<String>? = nil) throws {
        _ = metadataDomains
    }

    private static func _performScatterMigration(metadataDomains: Set<String>?) throws {
        _scatterMigrationLock.lock()
        defer { _scatterMigrationLock.unlock() }

        let startTime = Date().timeIntervalSince1970
        let fm = FileManager.default
        let documentsURL = Inf6DataRoot.url()

        let contents = try fm.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let pattern = try! NSRegularExpression(pattern: #"^inf6( \d+)?$"#)
        let scatteredRoots = contents.filter { url in
            let name = url.lastPathComponent
            return pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }

        let inputFingerprint = try _scatterMigrationFingerprint(roots: scatteredRoots)
        if UserDefaults.standard.string(forKey: _scatterMigrationFingerprintKey) == inputFingerprint {
            return
        }

        let canonicalRoot = documentsURL.appendingPathComponent("inf6", isDirectory: true)
        let canonicalMeta = canonicalRoot.appendingPathComponent("metadata", isDirectory: true)

        // iCloud は複数端末が同時に書くと「名前 2」という衝突コピーを作る。
        // ルート直下の inf6 2 だけを見ていたため、entity_images 2 のような
        // 同階層のものや、inf6/metadata 2 のような内側のものが取り残されて
        // いた。実測では inf6/metadata 2 に正本へ未統合の記録が 8,013件あった。
        // 統合してから消す。消すだけでは失われる。
        _mergeConflictCopies(under: documentsURL, mergedFiles: &_conflictMerged, skippedFiles: &_conflictSkipped)
        _mergeConflictCopies(under: canonicalRoot, mergedFiles: &_conflictMerged, skippedFiles: &_conflictSkipped)

        let scattered = scatteredRoots
            .filter { $0.lastPathComponent != "inf6" }
            .sorted { a, b in
                let aNum = Int(a.lastPathComponent.replacingOccurrences(of: "inf6 ", with: "")) ?? 0
                let bNum = Int(b.lastPathComponent.replacingOccurrences(of: "inf6 ", with: "")) ?? 0
                return aNum > bNum
            }
        guard !scattered.isEmpty else {
            UserDefaults.standard.set(inputFingerprint, forKey: _scatterMigrationFingerprintKey)
            return
        }

        print("[Inf6Storage] Scatter migration: \(scattered.count) directories found, merging before metadata load")

        try fm.createDirectory(at: canonicalMeta, withIntermediateDirectories: true)

        var mergedFiles = 0
        var skippedFiles = 0
        var failedRoots = Set<URL>()

        for scatteredRoot in scattered {
            let srcMeta = scatteredRoot.appendingPathComponent("metadata", isDirectory: true)
            guard let domainDirs = try? fm.contentsOfDirectory(
                at: srcMeta,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for domainDir in domainDirs where (try? domainDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let domainName = domainDir.lastPathComponent
                if let metadataDomains, !metadataDomains.contains(domainName) {
                    continue
                }
                let dstDomainDir = canonicalMeta.appendingPathComponent(domainName, isDirectory: true)
                do {
                    try fm.createDirectory(at: dstDomainDir, withIntermediateDirectories: true)
                    try? fm.removeItem(at: dstDomainDir.appendingPathComponent(".inf6-index.json"))
                } catch {
                    failedRoots.insert(scatteredRoot)
                    print("[Inf6Storage] scatter-merge failed to create metadata domain \(domainName): \(error.localizedDescription)")
                    continue
                }

                guard let files = try? fm.contentsOfDirectory(
                    at: domainDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else {
                    failedRoots.insert(scatteredRoot)
                    continue
                }

                for srcFile in files where srcFile.pathExtension == "json" {
                    let fileName = srcFile.lastPathComponent
                    let dstFile = dstDomainDir.appendingPathComponent(fileName)

                    if fm.fileExists(atPath: dstFile.path) {
                        if try !_shouldReplaceMetadataRecord(domainName: domainName, srcFile: srcFile, dstFile: dstFile) {
                            skippedFiles += 1
                            continue
                        }
                    }

                    do {
                        if fm.fileExists(atPath: dstFile.path) {
                            try fm.removeItem(at: dstFile)
                        }
                        try fm.copyItem(at: srcFile, to: dstFile)
                        try? fm.removeItem(at: dstDomainDir.appendingPathComponent(".inf6-index.json"))
                        mergedFiles += 1
                    } catch {
                        failedRoots.insert(scatteredRoot)
                        print("[Inf6Storage] scatter-merge failed for \(domainName)/\(fileName): \(error.localizedDescription)")
                    }
                }
            }

            if let topItems = try? fm.contentsOfDirectory(
                at: scatteredRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for item in topItems {
                    let name = item.lastPathComponent
                    if name == "metadata" { continue }
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    let dst = canonicalRoot.appendingPathComponent(name, isDirectory: isDir)

                    if isDir {
                        do {
                            try _mergeDirectoryContents(
                                from: item,
                                to: dst,
                                mergedFiles: &mergedFiles,
                                skippedFiles: &skippedFiles
                            )
                        } catch {
                            failedRoots.insert(scatteredRoot)
                            print("[Inf6Storage] scatter-merge: failed to merge \(name): \(error.localizedDescription)")
                        }
                    } else if !fm.fileExists(atPath: dst.path) {
                        do {
                            try fm.copyItem(at: item, to: dst)
                            mergedFiles += 1
                        } catch {
                            failedRoots.insert(scatteredRoot)
                            print("[Inf6Storage] scatter-merge: failed to copy \(name): \(error.localizedDescription)")
                        }
                    } else {
                        skippedFiles += 1
                    }
                }
            }
        }

        var removedDirs = 0
        for scatteredRoot in scattered where !failedRoots.contains(scatteredRoot) {
            do {
                try fm.removeItem(at: scatteredRoot)
                removedDirs += 1
            } catch {
                failedRoots.insert(scatteredRoot)
                print("[Inf6Storage] scatter-cleanup: cannot remove \(scatteredRoot.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince1970 - startTime)
        print("[Inf6Storage] Scatter migration complete (\(elapsed)s): \(mergedFiles) merged, \(skippedFiles) skipped, \(removedDirs) dirs removed, \(failedRoots.count) dirs failed")
        if !failedRoots.isEmpty {
            let names = failedRoots.map(\.lastPathComponent).sorted().joined(separator: ", ")
            throw NSError(
                domain: "Inf6Storage.ScatterMigration",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "iCloud分散データの統合に失敗しました: \(names)"]
            )
        }

        let postMigrationContents = try fm.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let postMigrationRoots = postMigrationContents.filter { url in
            let name = url.lastPathComponent
            return pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        UserDefaults.standard.set(
            try _scatterMigrationFingerprint(roots: postMigrationRoots),
            forKey: _scatterMigrationFingerprintKey
        )

        if mergedFiles > 0 {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .inf6ScatterMigrationDidComplete, object: mergedFiles)
            }
        }
    }

    private static var _conflictMerged = 0
    private static var _conflictSkipped = 0

    /// 「名前 2」という衝突コピーを、同じ名前の本体へ統合してから消す。
    ///
    /// 対象は同じ階層にある `<名前> <数字>` の形のフォルダで、`<名前>` が
    /// 存在するものに限る。本体が無い場合は名前を戻すだけにする。
    /// ルート直下の `inf6 2` は従来の処理が扱うので、ここでは対象外にする。
    private static func _mergeConflictCopies(under parent: URL, mergedFiles: inout Int, skippedFiles: inout Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let pattern = try! NSRegularExpression(pattern: #"^(.+) \d+$"#)

        for item in items {
            let name = item.lastPathComponent
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard name != "inf6", !name.hasPrefix("inf6 ") else { continue }

            let range = NSRange(name.startIndex..., in: name)
            guard let match = pattern.firstMatch(in: name, range: range),
                  let baseRange = Range(match.range(at: 1), in: name) else { continue }
            let baseName = String(name[baseRange])
            let base = parent.appendingPathComponent(baseName, isDirectory: true)

            if !fm.fileExists(atPath: base.path) {
                // 本体が無いなら、これが唯一の実体。名前を戻して残す。
                do {
                    try fm.moveItem(at: item, to: base)
                    print("[Inf6Storage] conflict copy promoted: \(name) -> \(baseName)")
                } catch {
                    print("[Inf6Storage] could not promote \(name): \(error.localizedDescription)")
                }
                continue
            }

            // 実体がローカルに無いファイルは触らない。
            //
            // iCloud に追い出されたものを読むと取得が終わるまで戻らない。
            // 実測で1件あたり最大57秒かかり、entity_images 2 のように数千件
            // あると読み込みが事実上止まる。追い出されている分は次の機会に回す。
            var pending = 0
            guard let walker = fm.enumerator(at: item, includingPropertiesForKeys: [.fileAllocatedSizeKey]) else { continue }
            for case let src as URL in walker {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let values = try? src.resourceValues(forKeys: [.fileAllocatedSizeKey])
                guard let allocated = values?.fileAllocatedSize, allocated > 0 else {
                    pending += 1
                    continue
                }
                let rel = src.path.replacingOccurrences(of: item.path + "/", with: "")
                let dst = base.appendingPathComponent(rel)
                if fm.fileExists(atPath: dst.path) {
                    skippedFiles += 1
                    try? fm.removeItem(at: src)
                    continue
                }
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: src, to: dst)
                    try? fm.removeItem(at: src)
                    mergedFiles += 1
                } catch {
                    print("[Inf6Storage] conflict merge failed for \(rel): \(error.localizedDescription)")
                }
            }
            if pending == 0 {
                try? fm.removeItem(at: item)
                print("[Inf6Storage] conflict copy merged and removed: \(name)")
            } else {
                print("[Inf6Storage] conflict copy partially merged: \(name), \(pending) files still in iCloud")
            }
        }
    }

    private static func _scatterMigrationFingerprint(roots: [URL]) throws -> String {
        let fm = FileManager.default
        var parts: [String] = []
        for root in roots.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            parts.append(root.lastPathComponent)
            let metadataURL = root.appendingPathComponent("metadata", isDirectory: true)
            guard let enumerator = fm.enumerator(
                at: metadataURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "json" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = values?.fileSize ?? 0
                parts.append("\(relativePath)|\(size)|\(mtime)")
            }
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func _shouldReplaceMetadataRecord(domainName: String, srcFile: URL, dstFile: URL) throws -> Bool {
        if domainName == "syllabus",
           try _metadataKey(url: srcFile)?.hasPrefix("structure:") == true,
           let srcRichness = try _knowledgeStructureRichness(url: srcFile),
           let dstRichness = try _knowledgeStructureRichness(url: dstFile) {
            if srcRichness.paperCount != dstRichness.paperCount {
                return srcRichness.paperCount > dstRichness.paperCount
            }
            if srcRichness.nodeCount != dstRichness.nodeCount {
                return srcRichness.nodeCount > dstRichness.nodeCount
            }
        }
        return try _extractUpdatedAt(url: srcFile) > _extractUpdatedAt(url: dstFile)
    }

    private static func _metadataKey(url: URL) throws -> String? {
        guard let text = String(data: try _readMetadataPrefix(url: url), encoding: .utf8),
              let keyRange = text.range(of: #""key""#) else { return nil }
        let tail = text[keyRange.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        let afterColon = tail[tail.index(after: colon)...].drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        guard afterColon.first == "\"" else { return nil }
        let valueStart = afterColon.index(after: afterColon.startIndex)
        guard let valueEnd = afterColon[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(afterColon[valueStart..<valueEnd])
    }

    private static func _knowledgeStructureRichness(url: URL) throws -> (nodeCount: Int, paperCount: Int)? {
        struct _Record: Decodable { var json: String }
        let data = try Data(contentsOf: url)
        let record = try JSONDecoder().decode(_Record.self, from: data)
        guard let innerData = record.json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: innerData) as? [String: Any] else { return nil }
        let nodeCount = (object["nodes"] as? [Any])?.count ?? 0
        let paperCount = (object["papers"] as? [Any])?.count ?? 0
        return (nodeCount, paperCount)
    }

    private static func _mergeDirectoryContents(
        from srcDir: URL,
        to dstDir: URL,
        mergedFiles: inout Int,
        skippedFiles: inout Int
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let children = try fm.contentsOfDirectory(
            at: srcDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for child in children {
            let isDir = (try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let childDst = dstDir.appendingPathComponent(child.lastPathComponent, isDirectory: isDir)
            if isDir {
                try _mergeDirectoryContents(
                    from: child,
                    to: childDst,
                    mergedFiles: &mergedFiles,
                    skippedFiles: &skippedFiles
                )
            } else if fm.fileExists(atPath: childDst.path) {
                skippedFiles += 1
            } else {
                try fm.copyItem(at: child, to: childDst)
                mergedFiles += 1
            }
        }
    }

    private static func _extractUpdatedAt(url: URL) throws -> TimeInterval {
        _extractUpdatedAt(fromPartialRecord: try _readMetadataPrefix(url: url)) ?? 0
    }

    private static func _extractUpdatedAt(fromPartialRecord data: Data) -> TimeInterval? {
        guard let text = String(data: data, encoding: .utf8),
              let keyRange = text.range(of: #""updatedAt""#) else { return nil }
        let tail = text[keyRange.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        let afterColon = tail[tail.index(after: colon)...].drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        let numberPrefix = afterColon.prefix { ch in
            ch.isNumber || ch == "." || ch == "-"
        }
        guard !numberPrefix.isEmpty else { return nil }
        return TimeInterval(numberPrefix)
    }

    private static func _readMetadataPrefix(url: URL) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw NSError(
                domain: "Inf6Storage.ScatterMigration",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "metadataを開けないため、分散データを統合できません: \(url.lastPathComponent)"]
            )
        }
        defer { try? handle.close() }

        var buffer = Data()
        let maxScanBytes = 64 * 1024
        while buffer.count < maxScanBytes {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        return buffer
    }

}

// MARK: - Local slug helper (kept here to avoid cross-file dependency)
private enum Inf6SyllabusSlug {
    static func slug(_ text: String, maxLength: Int = 80, emptyFallback: String = "auto") -> String {
        let lowered = text.lowercased()
        let removed = lowered.replacingOccurrences(
            of: "[^a-z0-9\\s._-]+",
            with: "",
            options: .regularExpression
        )
        let underscored = removed.replacingOccurrences(
            of: "\\s+",
            with: "_",
            options: .regularExpression
        )
        let trimmed = underscored.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))

        guard !trimmed.isEmpty else { return emptyFallback }
        if trimmed.count <= maxLength { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<idx])
    }
}

// MARK: - Local manifests storage helper (kept here to avoid cross-file dependency)
private enum Inf6SyllabusStorage {
    /// Returns the app home directory, delegating to the shared Inf6Storage helper.
    /// NOTE: Use Inf6Storage.homeDirectory() as the single source of truth.
    static func homeDirectory() -> URL {
        Inf6Storage.homeDirectory()
    }

    /// Local manifests directory under the app's manifests directory.
    /// NOTE: Delegates to Inf6Storage.manifestsDirectory() as the single source of truth.
    static func manifestsDirectory() -> URL {
        Inf6Storage.manifestsDirectory()
    }

    static func syllabusPDFDirectory() throws -> URL {
        let root = try Inf6LibraryView._sharedRootDir()

        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        #if canImport(UIKit)
        if accessed == false, !FileManager.default.isReadableFile(atPath: root.path) {
            throw NSError(
                domain: "Inf6SyllabusStorage",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Failed to access shared root folder: \(root.path)"]
            )
        }
        #endif

        let fm = FileManager.default
        var dir = root
        for component in ["jdla", "syllabus_pdfs"] {
            dir = dir.appendingPathComponent(component, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    throw NSError(
                        domain: "Inf6SyllabusStorage",
                        code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "Expected directory but found file: \(dir.path)"]
                    )
                }
            } else {
                try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            }
        }

        return dir
    }
}

/// NOTE: This is the *PDF syllabus config item* model.
/// It must NOT conflict with the enum `Inf6SyllabusSource` (Compass source selector) defined elsewhere.
struct Inf6SyllabusPDFSource: Codable, Identifiable {
    let id: String
    let exam: String       // "E資格" / "G検定" など論理名
    let version: String    // "2024" など
    let url: String
    let filename: String?

    private var normalizedExam: String {
        exam.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedVersion: String {
        version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 保存時に使用するファイル名。
    /// 設定ファイルで filename が指定されていればそのまま利用し、
    /// 無ければ exam/version からスラグ化したファイル名を自動生成する。
    var resolvedFilename: String {
        if let fn = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !fn.isEmpty {
            return fn
        }
        let examSlug = Inf6SyllabusSlug.slug(normalizedExam.isEmpty ? "syllabus" : normalizedExam)
        let verSlug = Inf6SyllabusSlug.slug(normalizedVersion.isEmpty ? "latest" : normalizedVersion)
        return "\(examSlug)_\(verSlug).pdf"
    }
}

/// シラバス の PDF をダウンロードし、テキストを抽出するためのユーティリティ。
///
/// - URL やバージョンは manifests/pdf_syllabi.(json|yaml|yml) で管理する。
/// - PDF は共有 root 配下の jdla/syllabus_pdfs/ に保存する。
/// - テキストは同名の .txt として同じディレクトリに保存する。
public enum Inf6Syllabus {

    /// manifests/pdf_syllabi.(json|yaml|yml) からシラバス情報を読み込む。
    static func loadConfiguredSources() throws -> [Inf6SyllabusPDFSource] {
        let dir = Inf6SyllabusStorage.manifestsDirectory()
        let fm = FileManager.default
        let candidates: [URL] = [
            dir.appendingPathComponent("pdf_syllabi.json"),
            dir.appendingPathComponent("pdf_syllabi.yaml"),
            dir.appendingPathComponent("pdf_syllabi.yml")
        ]

        for url in candidates {
            if fm.fileExists(atPath: url.path) {
                if url.pathExtension.lowercased() == "json" {
                    if let items = loadSourcesFromJSON(url: url) {
                        return items
                    }
                } else {
                    #if canImport(Yams)
                    if let items = loadSourcesFromYAML(url: url) {
                        return items
                    }
                    #else
                    continue
                    #endif
                }
            }
        }
        throw Inf6SyllabusError.configNotFound
    }

    private static func loadSourcesFromJSON(url: URL) -> [Inf6SyllabusPDFSource]? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()

            // ルートが配列の場合
            if let arr = try? decoder.decode([Inf6SyllabusPDFSource].self, from: data) {
                return arr
            }

            // { "items": [ ... ] } 形式も許容
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            if let dict = obj as? [String: Any],
               let items = dict["items"] {
                let itemsData = try JSONSerialization.data(withJSONObject: items, options: [])
                return try decoder.decode([Inf6SyllabusPDFSource].self, from: itemsData)
            }
        } catch {
            print("[Inf6Syllabus] JSON load failed: \(error)")
        }
        return nil
    }

    #if canImport(Yams)
    private static func loadSourcesFromYAML(url: URL) -> [Inf6SyllabusPDFSource]? {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let any = try Yams.load(yaml: text)
            let decoder = JSONDecoder()

            if let arr = any as? [[String: Any]] {
                let data = try JSONSerialization.data(withJSONObject: arr, options: [])
                return try decoder.decode([Inf6SyllabusPDFSource].self, from: data)
            } else if let dict = any as? [String: Any],
                      let items = dict["items"] as? [[String: Any]] {
                let data = try JSONSerialization.data(withJSONObject: items, options: [])
                return try decoder.decode([Inf6SyllabusPDFSource].self, from: data)
            }
        } catch {
            print("[Inf6Syllabus] YAML load failed: \(error)")
        }
        return nil
    }
    #endif

    /// 設定ファイルで定義された全ての  シラバス PDF をダウンロードする。
    ///
    /// - Parameters:
    ///   - timeout: HTTP リクエストのタイムアウト秒。
    /// - Returns: 保存した PDF ファイルの URL 配列。
    @discardableResult
    public static func downloadAllConfigured(
        timeout: TimeInterval = 60
    ) async throws -> [URL] {
        let sources = try loadConfiguredSources()
        guard !sources.isEmpty else {
            throw Inf6SyllabusError.invalidConfig("No syllabus sources defined.")
        }

        let destDir = try Inf6SyllabusStorage.syllabusPDFDirectory()
        let accessed = destDir.startAccessingSecurityScopedResource()
        defer { if accessed { destDir.stopAccessingSecurityScopedResource() } }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)

        var results: [URL] = []
        results.reserveCapacity(sources.count)

        for src in sources {
            guard let remoteURL = URL(string: src.url) else {
                print("[Inf6Syllabus] invalid URL in config: \(src.url)")
                continue
            }

            var req = URLRequest(url: remoteURL)
            req.httpMethod = "GET"
            req.setValue("application/pdf,*/*", forHTTPHeaderField: "Accept")
            req.setValue("inf6-pdf-syllabus-downloader/1.0", forHTTPHeaderField: "User-Agent")

            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    throw Inf6SyllabusError.badHTTPStatus(status)
                }
                guard data.count > 1024 else {
                    print("[Inf6Syllabus] downloaded data too small for \(remoteURL)")
                    continue
                }

                let dest = destDir.appendingPathComponent(src.resolvedFilename)
                try data.write(to: dest, options: .atomic)
                results.append(dest)
                print("[Inf6Syllabus] saved PDF: \(dest.lastPathComponent)")
            } catch {
                print("[Inf6Syllabus] download failed for \(remoteURL): \(error)")
            }
        }

        return results
    }

    /// jdla/syllabus_pdfs/ 以下に保存された PDF シラバスからテキストを抜き出し、
    /// 同名の .txt ファイルを生成する。
    ///
    /// - Returns: 作成または更新した .txt ファイルの URL 配列。
    @discardableResult
    public static func extractAllTexts() throws -> [URL] {
        let pdfDir = try Inf6SyllabusStorage.syllabusPDFDirectory()
        let accessed = pdfDir.startAccessingSecurityScopedResource()
        defer { if accessed { pdfDir.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: pdfDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var out: [URL] = []
        for pdf in items where pdf.pathExtension.lowercased() == "pdf" {
            do {
                let txt = try extractTextSidecar(for: pdf)
                out.append(txt)
            } catch {
                print("[Inf6Syllabus] text extraction failed for \(pdf.lastPathComponent): \(error)")
            }
        }
        return out
    }

    /// 単一の  シラバス PDF から本文テキストを抽出し、
    /// 同じ場所に `.txt` を生成する。
    ///
    /// - Parameter pdfURL: 抽出対象の PDF。
    /// - Returns: 生成した .txt ファイルの URL。
    public static func extractTextSidecar(for pdfURL: URL) throws -> URL {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: pdfURL) else {
            throw Inf6SyllabusError.invalidConfig("Failed to open PDF: \(pdfURL.path)")
        }

        var chunks: [String] = []
        let pageCount = doc.pageCount
        chunks.reserveCapacity(pageCount)

        for index in 0..<pageCount {
            guard let page = doc.page(at: index) else { continue }
            let text = page.string ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
        }

        let joined = chunks.joined(separator: "\n\n")
        let dest = pdfURL.deletingPathExtension().appendingPathExtension("txt")
        try joined.write(to: dest, atomically: true, encoding: .utf8)
        return dest
        #else
        throw Inf6SyllabusError.notPDFKitAvailable
        #endif
    }
}


private enum Inf6JDLA {
    /// ExploreCourses のスクール一覧に追加する JDLA スクール名
    static let schoolName = "JDLA"
}

/// JDLA シラバス用のエントリを、設定ファイル (pdf_syllabi.*) から構築する。
/// 年度やバージョンの追加・変更は設定ファイル側だけで完結させる。
func buildEQualificationSyllabi() -> [Inf6StanfordSyllabus] {
    // manifests/pdf_syllabi.(json|yaml|yml) を唯一の情報源とする
    guard let sources = try? Inf6Syllabus.loadConfiguredSources() else {
        return []
    }

    return sources.map { src in
        let examJa = src.exam
        let version = src.version

        let code = Inf6Lang.text(
            "\(examJa)\(version)",
            "\(examJa) \(version)"
        )
        let title = Inf6Lang.text(
            "\(examJa) 試験出題範囲（シラバス \(version)）",
            "\(examJa) Exam Syllabus (\(version))"
        )
        let detail = Inf6Lang.text(
            "日本ディープラーニング協会が公開している \(examJa) の \(version) 年版シラバスです。",
            "Syllabus \(version) for \(examJa) published by the Japan Deep Learning Association (JDLA)."
        )

        // department には一旦 exam の論理名をそのまま入れておき、
        // 実際にどの学科にぶら下げるかは buildJDLAQualificationSyllabi(forDeptCode:) 側で決める。
        return Inf6StanfordSyllabus(
            id: src.id,
            code: code,
            title: title,
            detail: detail,
            department: examJa,
            level: "",
            manifestRef: nil
        )
    }
}

/// JDLA 用のシラバスを、学科コードごとにフィルタして返すヘルパー。
/// - Parameter deptCode: 学科コード（JDLA 資格試験名そのもの。例: "E資格" / "G検定"）
/// - Returns: 指定された学科に対応するシラバスのみを返す。
func buildJDLAQualificationSyllabi(forDeptCode deptCode: String) -> [Inf6StanfordSyllabus] {
    let all = buildEQualificationSyllabi()

    // JDLA では、学科コード = 試験名（"E資格" / "G検定" / それ以外の将来の資格名）として扱う。
    let targetExamJa = deptCode

    // buildEQualificationSyllabi() で department に exam 論理名（試験名）を入れているので、
    // ここではそれと一致するものだけを返す。
    return all.filter { $0.department == targetExamJa }
}

/// ExploreCourses から取得したスクール一覧の先頭に JDLA 資格試験用スクールを差し込む。
/// 試験種別（E資格 / G検定 / 将来追加される資格など）は manifests/pdf_syllabi.* の exam 値から動的に決定する。
func prependEQualificationSchool(to schools: [ECSchool]) -> [ECSchool] {
    // すでに JDLA スクールが存在する場合は重複して追加しない
    if schools.contains(where: { $0.name == Inf6JDLA.schoolName }) {
        return schools
    }

    // 設定ファイルから JDLA の資格試験一覧を取得
    guard let sources = try? Inf6Syllabus.loadConfiguredSources(), !sources.isEmpty else {
        return schools
    }

    // exam のユニーク値（E資格 / G検定 / それ以外の将来の資格名）を学科として扱う
    let examNames = Array(Set(sources.map { $0.exam })).sorted()
    guard !examNames.isEmpty else {
        return schools
    }

    let departments = examNames.map { exam in
        ECDepartment(name: exam, code: exam)
    }

    let pseudo = ECSchool(
        name: Inf6JDLA.schoolName,
        departments: departments
    )

    var result = schools
    result.insert(pseudo, at: 0)
    return result
}



// MARK: - 軽量 XML Element ツリー (ElementTree 相当)

final class ECXMLElement {
    let name: String
    var attributes: [String: String]
    var children: [ECXMLElement] = []
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    // 直下の子要素
    func firstChild(named tag: String) -> ECXMLElement? {
        children.first { $0.name == tag }
    }

    func children(named tag: String) -> [ECXMLElement] {
        children.filter { $0.name == tag }
    }

    // 直下の子要素のテキスト
    func firstText(named tag: String) -> String? {
        firstChild(named: tag)?.normalizedText
    }

    // 再帰的に最初の一致要素を探す（.//tag 相当）
    func firstDescendant(named tag: String) -> ECXMLElement? {
        if name == tag { return self }
        for c in children {
            if let hit = c.firstDescendant(named: tag) {
                return hit
            }
        }
        return nil
    }

    func firstDescendantText(named tag: String) -> String? {
        firstDescendant(named: tag)?.normalizedText
    }

    var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // .//tag すべて
    func descendants(named tag: String) -> [ECXMLElement] {
        var result: [ECXMLElement] = []
        if name == tag { result.append(self) }
        for c in children {
            result.append(contentsOf: c.descendants(named: tag))
        }
        return result
    }
}

final class ECXMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var root: ECXMLElement?
    var stack: [ECXMLElement] = []

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {

        let elem = ECXMLElement(name: elementName, attributes: attributeDict)
        if let last = stack.last {
            last.children.append(elem)
        } else {
            root = elem
        }
        stack.append(elem)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text.append(string)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}

enum ECXMLParseError: Error {
    case parseFailed
}

func ECParseXML(_ data: Data) throws -> ECXMLElement {
    let delegate = ECXMLParserDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), let root = delegate.root else {
        throw ECXMLParseError.parseFailed
    }
    return root
}

// MARK: - Stanford ExploreCourses モデル (Python classes 対応)

// Department
struct ECDepartment: Codable, Hashable, CustomStringConvertible {
    let name: String   // longname
    let code: String   // name

    init(elem: ECXMLElement) {
        self.name = elem.attributes["longname"] ?? ""
        self.code = elem.attributes["name"] ?? ""
    }

    var description: String {
        "\(name) (\(code))"
    }

}

extension ECDepartment {
    /// ExploreCourses 由来ではない学科（例: JDLA など）を手動で構築するためのイニシャライザ。
    init(name: String, code: String) {
        self.name = name
        self.code = code
    }
}



extension ECDepartment {
    /// 日本語モードのときは、stanford_taxonomy_labels.* に `key: code` のエントリがあれば
    /// その label_ja / label_en を優先的に使う。
    /// なければ従来どおり `name` / `code` を表示する。
    var displayName: String {
        let base = name.isEmpty ? code : name
        return Inf6TaxonomyLocalization.localizedLabel(for: code, fallback: base)
    }
}

// School
struct ECSchool: Codable, Hashable, CustomStringConvertible {
    let name: String
    let departments: [ECDepartment]

    init(elem: ECXMLElement) {
        self.name = elem.attributes["name"] ?? ""
        let deptElems = elem.children(named: "department")
        self.departments = deptElems.map { ECDepartment(elem: $0) }
    }

    func department(matching idf: String) -> ECDepartment? {
        let q = idf.lowercased()
        return departments.first { dept in
            dept.name.lowercased() == q || dept.code.lowercased() == q
        }
    }

    var description: String { name }

}

extension ECSchool {
    /// ExploreCourses 由来ではないスクール（例: JDLA など）を手動で構築するためのイニシャライザ。
    init(name: String, departments: [ECDepartment]) {
        self.name = name
        self.departments = departments
    }
}



extension ECSchool {
    /// Stanford ExploreCourses から返るスクール名をローカライズする。
    /// stanford_taxonomy_labels.* に `key: name` のエントリがあればそれを利用する。
    var displayName: String {
        Inf6TaxonomyLocalization.localizedLabel(for: name, fallback: name)
    }
}

extension ECSchool {
    /// Stanford ExploreCourses から取得したタクソノミー情報をもとに、
    /// manifests ディレクトリ直下に `stanford_taxonomy_labels.yaml` のスケルトンを生成する。
    /// - Parameter schools: ExploreCourses から取得したスクール一覧。
    static func debugDumpTaxonomy(_ schools: [ECSchool]) {
        Inf6TaxonomyLocalization.writeSkeletonIfNeeded(for: schools)
    }
}

// Instructor
struct ECInstructor: CustomStringConvertible {
    let name: String
    let firstName: String
    let middleName: String
    let lastName: String
    let sunetID: String
    let isPrimaryInstructor: Bool

    init(elem: ECXMLElement) {
        self.name = elem.firstText(named: "name") ?? ""
        self.firstName = elem.firstText(named: "firstName") ?? ""
        self.middleName = elem.firstText(named: "middleName") ?? ""
        self.lastName = elem.firstText(named: "lastName") ?? ""
        self.sunetID = elem.firstText(named: "sunet") ?? ""
        self.isPrimaryInstructor = (elem.firstText(named: "role") == "PI")
    }

    var description: String {
        "\(firstName) \(lastName) (\(sunetID))"
    }
}

// Attribute
struct ECAttribute: CustomStringConvertible {
    let name: String
    let value: String
    let descriptionText: String
    let catalogPrint: Bool
    let schedulePrint: Bool

    init(elem: ECXMLElement) {
        self.name = elem.firstText(named: "name") ?? ""
        self.value = elem.firstText(named: "value") ?? ""
        self.descriptionText = elem.firstText(named: "description") ?? ""
        self.catalogPrint = (elem.firstText(named: "catalogPrint") == "true")
        self.schedulePrint = (elem.firstText(named: "schedulePrint") == "true")
    }

    var description: String {
        "\(name)::\(value)"
    }
}

// Schedule
struct ECSchedule: CustomStringConvertible {
    let startDate: String
    let endDate: String
    let startTime: String
    let endTime: String
    let location: String
    let days: [String]
    let instructors: [ECInstructor]

    init(elem: ECXMLElement) {
        self.startDate = elem.firstText(named: "startDate") ?? ""
        self.endDate = elem.firstText(named: "endDate") ?? ""
        self.startTime = elem.firstText(named: "startTime") ?? ""
        self.endTime = elem.firstText(named: "endTime") ?? ""
        self.location = elem.firstText(named: "location") ?? ""

        let daysText = elem.firstText(named: "days") ?? ""
        self.days = daysText.split(whereSeparator: { $0.isWhitespace }).map { String($0) }

        if let instrsElem = elem.firstChild(named: "instructors") {
            self.instructors = instrsElem.children.map { ECInstructor(elem: $0) }
        } else {
            self.instructors = []
        }
    }

    var description: String {
        "\(days.joined(separator: ", ")), \(startTime) - \(endTime) at \(location)"
    }
}

// Tag
struct ECTag: CustomStringConvertible {
    let organization: String
    let name: String

    init(elem: ECXMLElement) {
        self.organization = elem.firstText(named: "organization") ?? ""
        self.name = elem.firstText(named: "name") ?? ""
    }

    var description: String {
        "\(organization)::\(name)"
    }
}

// LearningObjective
struct ECLearningObjective: CustomStringConvertible {
    let code: String
    let descriptionText: String

    init(elem: ECXMLElement) {
        self.code = elem.firstDescendantText(named: "requirementCode") ?? ""
        self.descriptionText = elem.firstDescendantText(named: "description") ?? ""
    }

    var description: String {
        "Learning Objective (\(code): \(descriptionText))"
    }
}

// Section
struct ECSection: CustomStringConvertible {
    let classID: Int
    let term: String
    let units: String
    let sectionNum: String
    let component: String
    let currClassSize: Int
    let maxClassSize: Int
    let currWaitlistSize: Int
    let maxWaitlistSize: Int
    let notes: String
    let schedules: [ECSchedule]
    let attributes: [ECAttribute]

    init(elem: ECXMLElement) {
        func intText(_ name: String) -> Int {
            if let t = elem.firstText(named: name), let v = Int(t) { return v }
            return 0
        }

        self.classID = intText("classId")
        self.term = elem.firstText(named: "term") ?? ""
        self.units = elem.firstText(named: "units") ?? ""
        self.sectionNum = elem.firstText(named: "sectionNumber") ?? ""
        self.component = elem.firstText(named: "component") ?? ""
        self.maxClassSize = intText("maxClassSize")
        self.currClassSize = intText("currentClassSize")
        self.currWaitlistSize = intText("currentWaitlistSize")
        self.maxWaitlistSize = intText("maxWaitlistSize")
        self.notes = elem.firstText(named: "notes") ?? ""

        if let schedulesElem = elem.firstChild(named: "schedules") {
            self.schedules = schedulesElem.children.map { ECSchedule(elem: $0) }
        } else {
            self.schedules = []
        }

        if let attrsElem = elem.firstChild(named: "attributes") {
            self.attributes = attrsElem.children.map { ECAttribute(elem: $0) }
        } else {
            self.attributes = []
        }
    }

    var description: String {
        "\(component) \(sectionNum) (id: \(classID))"
    }
}

// Course
struct ECCourse: CustomStringConvertible, Equatable, Comparable {
    let year: String
    let subject: String
    let code: String
    let title: String
    let descriptionText: String
    let gers: [String]
    let repeatable: Bool
    let gradingBasis: String
    let unitsMin: Int
    let unitsMax: Int
    let objectives: [ECLearningObjective]
    let finalExam: Bool?
    let sections: [ECSection]
    let tags: [ECTag]
    let attributes: [ECAttribute]
    let courseID: Int
    let active: Bool?
    let offerNum: String
    let academicGroup: String
    let academicOrg: String
    let academicCareer: String
    let maxUnitsRepeat: Int
    let maxTimesRepeat: Int

    init(elem: ECXMLElement) {
        func intText(_ name: String) -> Int {
            if let t = elem.firstText(named: name), let v = Int(t) { return v }
            return 0
        }

        self.year = elem.firstText(named: "year") ?? ""
        self.subject = elem.firstText(named: "subject") ?? ""
        self.code = elem.firstText(named: "code") ?? ""
        self.title = elem.firstText(named: "title") ?? ""
        self.descriptionText = elem.firstText(named: "description") ?? ""

        let gersText = elem.firstText(named: "gers") ?? ""
        self.gers = gersText.isEmpty ? [] : gersText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        self.repeatable = (elem.firstText(named: "repeatable") == "true")
        self.gradingBasis = elem.firstText(named: "grading") ?? ""
        self.unitsMin = intText("unitsMin")
        self.unitsMax = intText("unitsMax")

        if let objsElem = elem.firstChild(named: "learningObjectives") {
            self.objectives = objsElem.children.map { ECLearningObjective(elem: $0) }
        } else {
            self.objectives = []
        }

        if let flag = elem.firstDescendantText(named: "finalExamFlag") {
            if flag == "Y" { self.finalExam = true }
            else if flag == "N" { self.finalExam = false }
            else { self.finalExam = nil }
        } else {
            self.finalExam = nil
        }

        if let secsElem = elem.firstChild(named: "sections") {
            self.sections = secsElem.children.map { ECSection(elem: $0) }
        } else {
            self.sections = []
        }

        if let tagsElem = elem.firstChild(named: "tags") {
            self.tags = tagsElem.children.map { ECTag(elem: $0) }
        } else {
            self.tags = []
        }

        if let attrsElem = elem.firstChild(named: "attributes") {
            self.attributes = attrsElem.children.map { ECAttribute(elem: $0) }
        } else {
            self.attributes = []
        }

        self.courseID = {
            if let t = elem.firstDescendantText(named: "courseId"), let v = Int(t) { return v }
            return 0
        }()

        if let status = elem.firstDescendantText(named: "effectiveStatus") {
            if status == "A" { self.active = true }
            else if status == "I" { self.active = false }
            else { self.active = nil }
        } else {
            self.active = nil
        }

        self.offerNum = elem.firstDescendantText(named: "offerNumber") ?? ""
        self.academicGroup = elem.firstDescendantText(named: "academicGroup") ?? ""
        self.academicOrg = elem.firstDescendantText(named: "academicOrganization") ?? ""
        self.academicCareer = elem.firstDescendantText(named: "academicCareer") ?? ""
        self.maxUnitsRepeat = {
            if let t = elem.firstDescendantText(named: "maxUnitsRepeat"), let v = Int(t) { return v }
            return 0
        }()
        self.maxTimesRepeat = {
            if let t = elem.firstDescendantText(named: "maxTimesRepeat"), let v = Int(t) { return v }
            return 0
        }()
    }

    var description: String {
        "\(subject)\(code) \(title)"
    }

    // Python の __eq__ (course_id で比較)
    static func == (lhs: ECCourse, rhs: ECCourse) -> Bool {
        lhs.courseID == rhs.courseID
    }

    // Python の __lt__ ロジック: subject -> code -> year
    static func < (lhs: ECCourse, rhs: ECCourse) -> Bool {
        if lhs.subject != rhs.subject { return lhs.subject < rhs.subject }
        if lhs.code != rhs.code { return lhs.code < rhs.code }
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        return false
    }
}

// MARK: - ExploreCourses フィルタ定数 (Python filters 対応)

enum ECTermFilter: String {
    case autumn  = "filter-term-Autumn"
    case winter  = "filter-term-Winter"
    case spring  = "filter-term-Spring"
    case summer  = "filter-term-Summer"
}

enum ECGerFilter: String {
    case language   = "filter-ger-Language"
    case writing1   = "filter-ger-Writing1"
    case writing2   = "filter-ger-Writing2"
    case writingSLE = "filter-ger-WritingSLE"

    case wayAII = "filter-ger-WAYAII"
    case wayAQR = "filter-ger-WAYAQR"
    case wayCE  = "filter-ger-WAYCE"
    case wayED  = "filter-ger-WAYED"
    case wayER  = "filter-ger-WAYER"
    case wayFR  = "filter-ger-WAYFR"
    case waySI  = "filter-ger-WAYSI"
    case waySMA = "filter-ger-WAYSMA"
}

enum ECUnitsFilter: String {
    case units1   = "filter-units-1"
    case units2   = "filter-units-2"
    case units3   = "filter-units-3"
    case units4   = "filter-units-4"
    case units5   = "filter-units-5"
    case unitsGT5 = "filter-units-gt5"
}

enum ECTimeFilter: String {
    case earlyMorning = "filter-time-0"
    case morning      = "filter-time-1"
    case lunchtime    = "filter-time-2"
    case afternoon    = "filter-time-3"
    case evening      = "filter-time-4"
}

enum ECDayFilter: String {
    case sunday    = "filter-day-1"
    case monday    = "filter-day-2"
    case tuesday   = "filter-day-3"
    case wednesday = "filter-day-4"
    case thursday  = "filter-day-5"
    case friday    = "filter-day-6"
    case saturday  = "filter-day-7"
}

enum ECCareerFilter: String {
    case ug  = "filter-academiclevel-UG"
    case gr  = "filter-academiclevel-GR"
    case gsb = "filter-academiclevel-GSB"
    case law = "filter-academiclevel-LAW"
    case med = "filter-academiclevel-MED"
}

// MARK: - CourseConnection (Python CourseConnection 相当)

final class ECCourseConnection {

     let baseURL = URL(string: "https://explorecourses.stanford.edu/")!
     let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 学年 "2017-2018" を "20172018" に変換
     func normalizeYear(_ year: String?) -> String? {
        guard let y = year, !y.isEmpty else { return nil }
        return y.replacingOccurrences(of: "-", with: "")
    }

    // Python: get_schools(self, academic_year=None)
    func getSchools(academicYear: String? = nil) async throws -> [ECSchool] {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "view", value: "xml-20200810")
        ]
        if let ny = normalizeYear(academicYear) {
            queryItems.append(URLQueryItem(name: "year", value: ny))
        }
        comps.queryItems = queryItems

        let (data, _) = try await session.data(from: comps.url!)
        let root = try ECParseXML(data)
        let schoolElems = root.descendants(named: "school")
        return schoolElems.map { ECSchool(elem: $0) }
    }

    // Python: get_school(self, name: str)
    func getSchool(named name: String) async throws -> ECSchool? {
        let schools = try await getSchools()
        return schools.first { $0.name == name }
    }

    // Python: get_courses_by_department(self, code, *filters, year=None)
    func getCoursesByDepartment(code: String,
                                filters: [String] = [],
                                academicYear: String? = nil) async throws -> [ECCourse] {
        var flt = filters
        flt.append("filter-departmentcode-\(code)")
        return try await getCoursesByQuery(query: code, filters: flt, academicYear: academicYear)
    }

    // Python: get_courses_by_query(self, query, *filters, year=None)
    func getCoursesByQuery(query: String,
                           filters: [String] = [],
                           academicYear: String? = nil) async throws -> [ECCourse] {

        var url = baseURL
        url.appendPathComponent("search")

        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "view", value: "xml-20200810"),
            URLQueryItem(name: "filter-coursestatus-Active", value: "on"),
            URLQueryItem(name: "q", value: query)
        ]
        for f in filters {
            queryItems.append(URLQueryItem(name: f, value: "on"))
        }
        if let ny = normalizeYear(academicYear) {
            queryItems.append(URLQueryItem(name: "academicYear", value: ny))
        }
        comps.queryItems = queryItems

        let (data, _) = try await session.data(from: comps.url!)
        let root = try ECParseXML(data)
        let courseElems = root.descendants(named: "course")
        return courseElems.map { ECCourse(elem: $0) }
    }
}


// Edit Syllabus

struct Inf6EDITSyllabus: Codable, Identifiable, Hashable {
    let id: String          // "equal-2025" など
    let code: String        // 一覧で出すコード（任意）
    let title: String       // 表示用タイトル（多言語は *_ja / *_en で拡張可）
    let detail: String      // 説明（任意）
    let department: String  // 「大学名 / 学部名」など
    let level: String       // 初学者向け / 中級 など
    let manifestRef: String? // 論文セット YAML への論理名

     enum CodingKeys: String, CodingKey {
        case id, code, title, detail, department, level
        case manifestRef      // camelCase
        case manifest_ref     // snake_case (YAML)
        case manifestURL      // legacy/alternate
    }

    init(
        id: String,
        code: String,
        title: String,
        detail: String,
        department: String,
        level: String,
        manifestRef: String? = nil
    ) {
        self.id = id
        self.code = code
        self.title = title
        self.detail = detail
        self.department = department
        self.level = level
        self.manifestRef = manifestRef
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        self.department = try c.decodeIfPresent(String.self, forKey: .department) ?? ""
        self.level = try c.decodeIfPresent(String.self, forKey: .level) ?? ""

        // Accept both manifest_ref (YAML) and manifestRef/manifestURL (legacy)
        let mr1 = try c.decodeIfPresent(String.self, forKey: .manifest_ref)
        let mr2 = try c.decodeIfPresent(String.self, forKey: .manifestRef)
        let mr3 = try c.decodeIfPresent(String.self, forKey: .manifestURL)
        self.manifestRef = mr1 ?? mr2 ?? mr3
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(code, forKey: .code)
        try c.encode(title, forKey: .title)
        try c.encode(detail, forKey: .detail)
        try c.encode(department, forKey: .department)
        try c.encode(level, forKey: .level)
        // Write using snake_case so the YAML stays consistent with existing files.
        if let mr = manifestRef { try c.encode(mr, forKey: .manifest_ref) }
    }
}

struct Inf6EDITConfig: Codable {
    var syllabi: [Inf6EDITSyllabus]
}


enum Inf6EDITConfigIO {
    static func configURL() -> URL {
        Inf6Storage.manifestsDirectory()
            .appendingPathComponent("schools_jdla.yaml")
    }

    static func defaultConfigURLInBundle() -> URL? {
        let jdlaFamilies = ["jdla_eshikaku", "jdla_gkentei"]
        for sf in jdlaFamilies {
            let url = Inf6KnowledgeDataStore.schoolsURL(for: sf)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return Bundle.main.url(forResource: "schools_jdla.default", withExtension: "yaml")
    }

    static func load() -> Inf6EDITConfig {
        let url = configURL()
        let fm = FileManager.default

        // 1) ユーザー編集版があればそれを読む
        #if canImport(Yams)
        if fm.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let cfg = try? YAMLDecoder().decode(Inf6EDITConfig.self, from: data) {
            return cfg
        }
        #endif

        // 2) なければ default を manifests にコピーしてから読む
        if let def = defaultConfigURLInBundle(),
           let data = try? Data(contentsOf: def) {
            // ユーザーが編集できるように manifests 配下にコピー
            if let text = String(data: data, encoding: .utf8) {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            #if canImport(Yams)
            if let cfg = try? YAMLDecoder().decode(Inf6EDITConfig.self, from: data) {
                return cfg
            }
            #endif
        }

        // 3) それでもダメなら空
        return Inf6EDITConfig(syllabi: [])
    }

    static func save(_ config: Inf6EDITConfig) {
        let url = configURL()
        #if canImport(Yams)
        if let text = try? YAMLEncoder().encode(config) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        #else
        // Yams が無いビルドでは保存できないため no-op
        #endif
    }
}


// swiftlint:disable file_length

#if canImport(SwiftUI)
struct Inf6EDITConfigView: View {
    @Environment(\.dismiss)  var dismiss
    @State  var config = Inf6EDITConfigIO.load()
    @State  var selection: Inf6EDITSyllabus.ID?

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(config.syllabi) { s in
                    Text("\(s.code)  \(s.title)")
                }
                .onDelete { indexSet in
                    config.syllabi.remove(atOffsets: indexSet)
                }
            }
            .navigationTitle("JDLA / 大学シラバス設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inf6Lang.text("閉じる", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(Inf6Lang.text("保存", "Save")) {
                        Inf6EDITConfigIO.save(config)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let new = Inf6EDITSyllabus(
                            id: UUID().uuidString,
                            code: "",
                            title: "",
                            detail: "",
                            department: "",
                            level: "",
                            manifestRef: nil
                        )
                        config.syllabi.append(new)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}
#endif
