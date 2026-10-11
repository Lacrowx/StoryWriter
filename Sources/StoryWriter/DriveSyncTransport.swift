import Foundation
import CryptoKit

struct DriveRevision: Codable {
    var format = 1
    var id = UUID()
    var parents: [UUID]
    var deviceID: UUID
    var deviceName: String
    var project: StoryProject
    var assets: [String: String]
}

struct DriveScan {
    var revisions: [UUID: DriveRevision]
    var waiting: Bool
}

private struct DriveAssetMemo: Codable {
    var size: UInt64
    var modified: Date
    var inode: UInt64
    var digest: String
}

/// iCloud is a file transport. Immutable commits and content-addressed assets
/// avoid a shared mutable head file and cross-device lock assumptions.
enum DriveSyncTransport {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sameProject(_ a: StoryProject, _ b: StoryProject) -> Bool {
        var a = a, b = b; a.modifiedAt = .distantPast; b.modifiedAt = .distantPast
        return (try? encode(a)) == (try? encode(b))
    }
    static func assetURL(_ hash: String, in folder: URL) -> URL { folder.appendingPathComponent("Assets/\(hash).blob") }
    static func revisionURL(_ id: UUID, in folder: URL) -> URL { folder.appendingPathComponent("Versions/\(id.uuidString).json") }
    static func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func safeAsset(_ path: String) -> Bool {
        ProjectStore.isSafeRelativePath(path) && path.hasPrefix("Media/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." })
    }
    static func validateLocation(_ url: URL, inside folder: URL) throws {
        // Foundation's standardizedFileURL can remove /private only for paths
        // that already exist. A new child must compare against the same lexical
        // root as its existing parent, then check each actual symlink separately.
        func lexical(_ path: String) -> String {
            var parts: [String] = []
            for part in path.split(separator: "/") {
                if part == ".." { if !parts.isEmpty { parts.removeLast() } }
                else if part != "." { parts.append(String(part)) }
            }
            return "/" + parts.joined(separator: "/")
        }
        func canonical(_ url: URL) -> String {
            var ancestor = URL(fileURLWithPath: lexical(url.path)), suffix: [String] = []
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                suffix.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
            }
            let anchor = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
            return anchor + (suffix.isEmpty ? "" : "/" + suffix.reversed().joined(separator: "/"))
        }
        let root = canonical(folder)
        let target = canonical(url)
        guard target.hasPrefix(root + "/") else { throw ProjectError.invalid("The sync folder contains a symbolic link outside its folder.") }
        var component = URL(fileURLWithPath: lexical(url.path))
        while canonical(component) != root {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) == nil else { throw ProjectError.invalid("Sync folders cannot contain symbolic links.") }
            let parent = component.deletingLastPathComponent()
            guard parent.path != component.path else { throw ProjectError.invalid("A sync file is outside its folder.") }
            component = parent
        }
    }
    static func requireFolder(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectError.invalid("The sync folder is unavailable. Your writing continues saving on this Mac.")
        }
    }
    static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?, result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in result = Result { try Data(contentsOf: target) } }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ProjectError.invalid("The file is not available yet.") }
        return try result.get()
    }
    static func write(_ data: Data, to url: URL, inside folder: URL) throws {
        try validateLocation(url, inside: folder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    guard try Data(contentsOf: target) == data else { throw ProjectError.invalid("A sync version changed unexpectedly. Your local writing is safe.") }
                } else { try data.write(to: target, options: .atomic) }
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }
    static func decodeRevision(_ data: Data) throws -> DriveRevision {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let revision = try decoder.decode(DriveRevision.self, from: data)
        guard revision.format == 1, revision.parents.count <= 2, Set(revision.parents).count == revision.parents.count,
              !revision.parents.contains(revision.id) else { throw ProjectError.invalid("An unsupported or invalid sync version needs attention.") }
        _ = try ProjectStore.decode(encode(revision.project))
        guard revision.assets.allSatisfy({ safeAsset($0.key) && validHash($0.value) }) else { throw ProjectError.invalid("A sync version contains an unsafe reference path.") }
        for source in revision.project.sources {
            for path in [source.relativePath, source.snapshotPath].compactMap({ $0 }) {
                guard revision.assets[path] != nil else { throw ProjectError.invalid("A sync version is missing a reference file.") }
            }
        }
        return revision
    }
    static func capture(project: StoryProject, package: URL, cache: URL, parents: [UUID], deviceID: UUID, deviceName: String) throws -> DriveRevision {
        var assets: [String: String] = [:]
        let memoURL = cache.appendingPathComponent("Scans/\(project.id.uuidString).json")
        let oldMemo = (try? JSONDecoder().decode([String: DriveAssetMemo].self, from: Data(contentsOf: memoURL))) ?? [:]
        var memo: [String: DriveAssetMemo] = [:]
        let canonicalPackage = package.resolvingSymlinksInPath().standardizedFileURL
        let media = canonicalPackage.appendingPathComponent("Media")
        if FileManager.default.fileExists(atPath: media.path) {
            guard let files = FileManager.default.enumerator(at: media, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in false }) else { throw ProjectError.invalid("Reference files could not be read.") }
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw ProjectError.invalid("Reference files containing symbolic links cannot be synced.") }
                guard values.isRegularFile == true else { continue }
                let path = String(file.standardizedFileURL.path.dropFirst(canonicalPackage.path.count + 1))
                guard safeAsset(path) else { throw ProjectError.invalid("A reference file has an unsafe path.") }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = attributes[.modificationDate] as? Date ?? .distantPast
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                if let previous = oldMemo[path], previous.size == size, previous.modified == modified, previous.inode == inode,
                   validHash(previous.digest), FileManager.default.fileExists(atPath: assetURL(previous.digest, in: cache).path) {
                    assets[path] = previous.digest; memo[path] = previous; continue
                }
                let data = try read(file), digest = hash(data)
                try write(data, to: assetURL(digest, in: cache), inside: cache)
                assets[path] = digest
                memo[path] = DriveAssetMemo(size: size, modified: modified, inode: inode, digest: digest)
            }
        }
        let revision = DriveRevision(parents: parents, deviceID: deviceID, deviceName: deviceName, project: project, assets: assets)
        _ = try decodeRevision(encode(revision))
        try FileManager.default.createDirectory(at: memoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(memo).write(to: memoURL, options: .atomic)
        return revision
    }
    static func publish(_ revision: DriveRevision, folder: URL, cache: URL) throws {
        try requireFolder(folder)
        _ = try decodeRevision(encode(revision))
        for digest in Set(revision.assets.values) {
            let destination = assetURL(digest, in: folder)
            try validateLocation(destination, inside: folder)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            let data = try read(assetURL(digest, in: cache))
            guard hash(data) == digest else { throw ProjectError.invalid("A cached reference file could not be verified.") }
            try write(data, to: assetURL(digest, in: folder), inside: folder)
        }
        let data = try encode(revision)
        try write(data, to: revisionURL(revision.id, in: cache), inside: cache)
        try write(data, to: revisionURL(revision.id, in: folder), inside: folder)
    }
    static func requestDownload(_ url: URL) {
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
    }
    static func awaitingFile(_ url: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) { return true }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus != .current
    }
    static func scan(folder: URL, cache: URL, known: [UUID: DriveRevision] = [:]) throws -> DriveScan {
        try requireFolder(folder)
        var revisions: [UUID: DriveRevision] = [:], waiting = false
        let versions = folder.appendingPathComponent("Versions")
        try validateLocation(versions, inside: folder)
        if FileManager.default.fileExists(atPath: versions.path) {
            for file in try FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: [.isUbiquitousItemKey]) {
                try validateLocation(file, inside: folder)
                if file.lastPathComponent.hasPrefix("."), file.lastPathComponent.hasSuffix(".json.icloud") {
                    let original = String(file.lastPathComponent.dropFirst().dropLast(".icloud".count))
                    requestDownload(versions.appendingPathComponent(original)); waiting = true; continue
                }
                guard file.pathExtension == "json" else { continue }
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let previous = known[id] {
                    revisions[id] = previous; continue
                }
                let data: Data
                do { data = try read(file) } catch {
                    guard awaitingFile(file) else { throw error }
                    requestDownload(file); waiting = true; continue
                }
                let revision = try decodeRevision(data)
                guard file.deletingPathExtension().lastPathComponent == revision.id.uuidString else { throw ProjectError.invalid("A sync version has an unexpected filename.") }
                var complete = true
                for digest in Set(revision.assets.values) {
                    let destination = assetURL(digest, in: cache)
                    if FileManager.default.fileExists(atPath: destination.path) { continue }
                    let source = assetURL(digest, in: folder)
                    try validateLocation(source, inside: folder)
                    let asset: Data
                    do { asset = try read(source) } catch {
                        guard awaitingFile(source) else { throw error }
                        requestDownload(source); complete = false; waiting = true
                        continue
                    }
                    guard hash(asset) == digest else { throw ProjectError.invalid("An incoming reference file could not be verified.") }
                    try write(asset, to: destination, inside: cache)
                }
                if complete {
                    try write(data, to: revisionURL(revision.id, in: cache), inside: cache)
                    revisions[revision.id] = revision
                }
            }
        }
        // A commit may arrive before its parents or assets. Never interpret that
        // as a new independent story or overwrite a newer local branch.
        var children: [UUID: [UUID]] = [:], counts: [UUID: Int] = [:], blocked = Set<UUID>()
        for (id, revision) in revisions {
            counts[id] = revision.parents.count
            for parent in revision.parents {
                children[parent, default: []].append(id)
                if let ancestor = revisions[parent] {
                    guard ancestor.project.id == revision.project.id else { throw ProjectError.invalid("A sync version refers to a different story.") }
                } else { blocked.insert(id); waiting = true }
            }
        }
        var pending = Array(blocked)
        while let next = pending.popLast() {
            for child in children[next] ?? [] where blocked.insert(child).inserted { pending.append(child) }
        }
        pending = counts.filter { $0.value == 0 }.map(\.key)
        var ready = Set<UUID>()
        while let next = pending.popLast() {
            ready.insert(next)
            for child in children[next] ?? [] {
                counts[child, default: 0] -= 1
                if counts[child] == 0 { pending.append(child) }
            }
        }
        guard Set(revisions.keys).subtracting(ready).subtracting(blocked).isEmpty else { throw ProjectError.invalid("The sync history contains a cycle.") }
        return DriveScan(revisions: revisions.filter { ready.contains($0.key) }, waiting: waiting)
    }
    static func cached(_ id: UUID, cache: URL) throws -> DriveRevision { try decodeRevision(read(revisionURL(id, in: cache))) }
    static func ancestors(_ id: UUID, revisions: [UUID: DriveRevision]) -> Set<UUID> {
        var result = Set<UUID>(), pending = [id]
        while let next = pending.popLast() {
            guard result.insert(next).inserted else { continue }
            pending.append(contentsOf: revisions[next]?.parents ?? [])
        }
        return result
    }
    static func commonBase(_ a: UUID, _ b: UUID, revisions: [UUID: DriveRevision]) -> DriveRevision? {
        let common = ancestors(a, revisions: revisions).intersection(ancestors(b, revisions: revisions))
        // Criss-cross merges may have more than one best base. Review rather than
        // choose an arbitrary ancestor and silently misinterpret edits.
        let nonmaximal = Set(common.flatMap { revisions[$0]?.parents ?? [] })
        let best = common.subtracting(nonmaximal)
        return best.count == 1 ? best.first.flatMap { revisions[$0] } : nil
    }
    static func heads(_ revisions: [UUID: DriveRevision], projectID: UUID) -> [DriveRevision] {
        let project = revisions.values.filter { $0.project.id == projectID }
        let parents = Set(project.flatMap(\.parents))
        return project.filter { !parents.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    static func prepare(_ revision: DriveRevision, package: URL, cache: URL) throws -> URL {
        let staging = package.deletingLastPathComponent().appendingPathComponent(".sync-install-\(UUID().uuidString).storywriter")
        do {
            if FileManager.default.fileExists(atPath: package.path) { try FileManager.default.copyItem(at: package, to: staging) }
            else { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
            for (path, digest) in revision.assets {
                let data = try read(assetURL(digest, in: cache))
                guard hash(data) == digest else { throw ProjectError.invalid("A reference file could not be verified.") }
                let destination = staging.appendingPathComponent(path)
                try validateLocation(destination, inside: staging)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
            try encode(revision.project).write(to: staging.appendingPathComponent("project.json"), options: .atomic)
            _ = try ProjectStore.readPackage(staging)
            return staging
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
    static func install(_ staging: URL, at package: URL) throws {
        var coordinationError: NSError?, installError: Error?
        NSFileCoordinator().coordinate(writingItemAt: package, options: .forReplacing, error: &coordinationError) { target in
            do {
                if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staging) }
                else { try FileManager.default.moveItem(at: staging, to: target) }
            } catch { installError = error }
        }
        if let error = coordinationError ?? installError as NSError? { throw error }
    }
}
