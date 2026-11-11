//
//  Inf6PaperVectorIndex.swift
//  inf6
//
//  Local paper/profile vector index + nearest-neighbor search.
//

import Foundation

// MARK: - Errors

enum Inf6PaperVectorIndexError: LocalizedError {
    case baseDirUnavailable
    case invalidVector
    case ioReadFailed(String)
    case ioWriteFailed(String)
    case decodeFailed(String)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .baseDirUnavailable:
            return "Vector index base directory is unavailable."
        case .invalidVector:
            return "Invalid vector (empty or non-finite values)."
        case .ioReadFailed(let s):
            return "Failed to read vector index: \(s)"
        case .ioWriteFailed(let s):
            return "Failed to write vector index: \(s)"
        case .decodeFailed(let s):
            return "Failed to decode vector index: \(s)"
        case .encodeFailed(let s):
            return "Failed to encode vector index: \(s)"
        }
    }
}

// MARK: - Vector math

enum Inf6VectorMath {
    static func isFinite(_ v: [Float]) -> Bool {
        guard !v.isEmpty else { return false }
        for x in v {
            if !x.isFinite { return false }
        }
        return true
    }

    static func l2Norm(_ v: [Float]) -> Float {
        var s: Float = 0
        for x in v { s += x * x }
        return sqrt(max(0, s))
    }

    static func normalizeL2(_ v: [Float]) -> [Float] {
        let n = l2Norm(v)
        if n <= 0 { return v }
        return v.map { $0 / n }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        if n <= 0 { return 0 }
        var s: Float = 0
        for i in 0..<n { s += a[i] * b[i] }
        return s
    }

    /// Cosine similarity (expects normalized vectors, but will still work if not).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let da = l2Norm(a)
        let db = l2Norm(b)
        if da <= 0 || db <= 0 { return 0 }
        return dot(a, b) / (da * db)
    }
}

// MARK: - Storage model

struct Inf6PaperVectorIndexEntry: Codable, Hashable {
    let paperID: String                 // stable id (e.g., arXiv id URL string, or PubMed pmid)
    var title: String                   // optional but useful for UI
    var sourceRaw: String               // "arxiv" / "pubmed" / etc
    var vector: [Float]                 // recommended: L2-normalized
    var updatedAt: TimeInterval

    init(paperID: String, title: String, sourceRaw: String, vector: [Float]) {
        self.paperID = paperID
        self.title = title
        self.sourceRaw = sourceRaw
        self.vector = vector
        self.updatedAt = Date().timeIntervalSince1970
    }
}

struct Inf6ProfileVectorSnapshot: Codable, Hashable {
    var profileID: String               // stable id per user profile/version
    var label: String                   // human-readable label (optional)
    var vector: [Float]                 // recommended: L2-normalized
    var updatedAt: TimeInterval

    init(profileID: String, label: String, vector: [Float]) {
        self.profileID = profileID
        self.label = label
        self.vector = vector
        self.updatedAt = Date().timeIntervalSince1970
    }
}

private struct _Inf6PaperVectorIndexOnDisk: Codable {
    var version: Int
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var dimension: Int?                 // optional; set once we know it
    var papers: [Inf6PaperVectorIndexEntry]
    var profiles: [Inf6ProfileVectorSnapshot]

    init() {
        self.version = 1
        let now = Date().timeIntervalSince1970
        self.createdAt = now
        self.updatedAt = now
        self.dimension = nil
        self.papers = []
        self.profiles = []
    }
}

// MARK: - Index

/// Local vector index stored under:
///   <baseDir>/paper.vector.index/v1/index.json
///
/// `baseDir` should already be the resolved local folder URL you use for the paper workspace.
final class Inf6PaperVectorIndex {

    private let baseDir: URL

    // cached in-memory
    private var disk: _Inf6PaperVectorIndexOnDisk = _Inf6PaperVectorIndexOnDisk()
    private var loaded: Bool = false

    init(baseDir: URL) {
        self.baseDir = baseDir
    }

    // MARK: Paths

    private func _indexDir() -> URL {
        baseDir
            .appendingPathComponent("paper.vector.index", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private func _indexURL() -> URL {
        _indexDir().appendingPathComponent("index.json", isDirectory: false)
    }

    // MARK: Public API

    /// Loads index from iCloud (or initializes empty if absent).
    func loadOrCreate() throws {
        if loaded { return }
        try _ensureDirExists(_indexDir())
        try _loadFromDiskIfExists()
        loaded = true
    }

    /// Returns current dimension if known.
    func currentDimension() -> Int? {
        disk.dimension
    }

    /// Upsert a paper vector. Vector is validated and L2-normalized before storage.
    func upsertPaperVector(paperID: String, title: String, sourceRaw: String, vector rawVector: [Float]) throws {
        try _requireLoaded()

        let v = try _validatedNormalizedVector(rawVector)
        if let dim = disk.dimension {
            if dim != v.count {
                // keep strict; don't silently mix dimensions
                throw Inf6PaperVectorIndexError.invalidVector
            }
        } else {
            disk.dimension = v.count
        }

        let now = Date().timeIntervalSince1970

        if let i = disk.papers.firstIndex(where: { $0.paperID == paperID }) {
            disk.papers[i].title = title
            disk.papers[i].sourceRaw = sourceRaw
            disk.papers[i].vector = v
            disk.papers[i].updatedAt = now
        } else {
            var e = Inf6PaperVectorIndexEntry(paperID: paperID, title: title, sourceRaw: sourceRaw, vector: v)
            e.updatedAt = now
            disk.papers.append(e)
        }

        disk.updatedAt = now
        try _persistToDisk()
    }

    /// Remove a paper entry.
    func removePaper(paperID: String) throws {
        try _requireLoaded()
        let before = disk.papers.count
        disk.papers.removeAll(where: { $0.paperID == paperID })
        if disk.papers.count != before {
            disk.updatedAt = Date().timeIntervalSince1970
            try _persistToDisk()
        }
    }

    /// Store a profile vector (e.g., from chat-driven profile). Vector is validated and L2-normalized.
    func upsertProfileVector(profileID: String, label: String, vector rawVector: [Float]) throws {
        try _requireLoaded()

        let v = try _validatedNormalizedVector(rawVector)
        if let dim = disk.dimension {
            if dim != v.count { throw Inf6PaperVectorIndexError.invalidVector }
        } else {
            disk.dimension = v.count
        }

        let now = Date().timeIntervalSince1970

        if let i = disk.profiles.firstIndex(where: { $0.profileID == profileID }) {
            disk.profiles[i].label = label
            disk.profiles[i].vector = v
            disk.profiles[i].updatedAt = now
        } else {
            var p = Inf6ProfileVectorSnapshot(profileID: profileID, label: label, vector: v)
            p.updatedAt = now
            disk.profiles.append(p)
        }

        disk.updatedAt = now
        try _persistToDisk()
    }

    /// Fetch profile vector.
    func profileVector(profileID: String) throws -> Inf6ProfileVectorSnapshot? {
        try _requireLoaded()
        return disk.profiles.first(where: { $0.profileID == profileID })
    }

    /// Nearest-neighbor search over stored paper vectors using cosine similarity.
    /// - Note: expects queryVector to be same dimension; will validate and normalize.
    func searchPapers(queryVector rawQuery: [Float], topK: Int) throws -> [(paper: Inf6PaperVectorIndexEntry, score: Float)] {
        try _requireLoaded()
        let q = try _validatedNormalizedVector(rawQuery)

        if let dim = disk.dimension, dim != q.count {
            throw Inf6PaperVectorIndexError.invalidVector
        }

        let k = max(1, min(topK, 200))

        // Linear scan (first version). Replace with ANN later.
        var scored: [(Inf6PaperVectorIndexEntry, Float)] = []
        scored.reserveCapacity(min(disk.papers.count, k * 2))

        for e in disk.papers {
            // e.vector is expected normalized, but we still compute robustly.
            let s = Inf6VectorMath.cosine(q, e.vector)
            scored.append((e, s))
        }

        scored.sort { $0.1 > $1.1 }
        if scored.count > k { scored.removeSubrange(k..<scored.count) }
        return scored
    }

    /// Convenience: search by profileID.
    func searchPapersByProfile(profileID: String, topK: Int) throws -> [(paper: Inf6PaperVectorIndexEntry, score: Float)] {
        try _requireLoaded()
        guard let p = disk.profiles.first(where: { $0.profileID == profileID }) else { return [] }
        return try searchPapers(queryVector: p.vector, topK: topK)
    }

    /// Return all stored paper entries (e.g. for UI).
    func allPapers() throws -> [Inf6PaperVectorIndexEntry] {
        try _requireLoaded()
        return disk.papers
    }

    // MARK: - Internal

    private func _requireLoaded() throws {
        if !loaded {
            throw Inf6PaperVectorIndexError.ioReadFailed("Index not loaded. Call loadOrCreate() first.")
        }
    }

    private func _validatedNormalizedVector(_ raw: [Float]) throws -> [Float] {
        guard Inf6VectorMath.isFinite(raw) else { throw Inf6PaperVectorIndexError.invalidVector }
        let trimmed = raw // keep as-is; upstream decides dimension
        guard !trimmed.isEmpty else { throw Inf6PaperVectorIndexError.invalidVector }
        return Inf6VectorMath.normalizeL2(trimmed)
    }

    private func _ensureDirExists(_ dir: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) { return }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw Inf6PaperVectorIndexError.ioWriteFailed("mkdir failed: \(error.localizedDescription) url=\(dir)")
        }
    }

    private func _readFileDataCoordinated(_ url: URL) -> Data? {
        var out: Data? = nil
        var coordError: NSError? = nil
        let coord = NSFileCoordinator(filePresenter: nil)
        coord.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            out = try? Data(contentsOf: readURL)
        }
        return out
    }

    private func _writeFileDataCoordinated(_ data: Data, to url: URL) throws {
        var coordErr: NSError? = nil
        var writeErr: Error? = nil

        let coord = NSFileCoordinator(filePresenter: nil)
        coord.coordinate(writingItemAt: url, options: .forReplacing, error: &coordErr) { writeURL in
            do {
                try data.write(to: writeURL, options: [.atomic])
            } catch {
                writeErr = error
            }
        }

        if let coordErr {
            throw Inf6PaperVectorIndexError.ioWriteFailed(
                "coordinated write failed: \(coordErr.localizedDescription) url=\(url)"
            )
        }

        if let writeErr {
            throw Inf6PaperVectorIndexError.ioWriteFailed(
                "write failed: \(writeErr.localizedDescription) url=\(url)"
            )
        }
    }

    private func _loadFromDiskIfExists() throws {
        let u = _indexURL()
        let fm = FileManager.default

        guard fm.fileExists(atPath: u.path) else {
            // absent -> keep empty index
            disk = _Inf6PaperVectorIndexOnDisk()
            return
        }

        guard let data = _readFileDataCoordinated(u), !data.isEmpty else {
            // if exists but unreadable -> surface
            throw Inf6PaperVectorIndexError.ioReadFailed("read failed or empty: \(u)")
        }

        do {
            let decoded = try JSONDecoder().decode(_Inf6PaperVectorIndexOnDisk.self, from: data)
            disk = decoded
        } catch {
            throw Inf6PaperVectorIndexError.decodeFailed("\(error.localizedDescription)")
        }
    }

    private func _persistToDisk() throws {
        let u = _indexURL()
        try _ensureDirExists(_indexDir())

        let data: Data
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try enc.encode(disk)
        } catch {
            throw Inf6PaperVectorIndexError.encodeFailed("\(error.localizedDescription)")
        }

        try _writeFileDataCoordinated(data, to: u)
    }
}
