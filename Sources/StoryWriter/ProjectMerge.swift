import AppKit
import Foundation

enum MergeChoice: String { case local, incoming }

struct MergeConflict: Identifiable {
    var id: String
    var title: String
    var local: String
    var incoming: String
    var chapterID: UUID?
    var localWriting: NSAttributedString?
    var incomingWriting: NSAttributedString?
}

struct ProjectMergeResult {
    var project: StoryProject
    var conflicts: [MergeConflict]
}

/// A three-way merge. Identity comes from stored UUIDs, never names or timestamps.
enum ProjectMerge {
    static func merge(base: StoryProject, local: StoryProject, incoming: StoryProject,
                      choices: [String: MergeChoice] = [:]) throws -> ProjectMergeResult {
        guard base.id == local.id, local.id == incoming.id else { throw ProjectError.invalid("These versions belong to different stories.") }
        let b = try object(base), l = try object(local), r = try object(incoming)
        var names: [String: String] = [:]
        func collect(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let id = dict["id"] as? String, let name = (dict["title"] ?? dict["name"]) as? String { names[id] = name }
                for child in dict.values { collect(child) }
            } else if let values = value as? [Any] { for child in values { collect(child) } }
        }
        collect(b); collect(r); collect(l)
        var worker = Worker(choices: choices, names: names)
        let value = worker.merge(b, l, r, path: "Story")
        do {
            let data = try JSONSerialization.data(withJSONObject: value!, options: [.sortedKeys])
            return ProjectMergeResult(project: try ProjectStore.decode(data), conflicts: worker.conflicts)
        } catch {
            // Independent edits can create dependent-record conflicts (e.g. deleting
            // a topic while another Mac adds an event). Never install invalid data.
            let id = "Story/dependent records"
            worker.conflicts.append(MergeConflict(id: id, title: "Related story records need review", local: summary(local), incoming: summary(incoming)))
            return ProjectMergeResult(project: choices[id] == .incoming ? incoming : local, conflicts: worker.conflicts)
        }
    }

    static func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    static func summary(_ project: StoryProject) -> String {
        project.title + "\n\n" + project.chapters.map { $0.title + "\n" + $0.plainText }.joined(separator: "\n\n")
    }
    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return (a as? NSObject)?.isEqual(b) == true
        default: return false
        }
    }

    private struct Worker {
        var choices: [String: MergeChoice]
        var conflicts: [MergeConflict] = []
        var names: [String: String]

        mutating func conflict(_ base: Any?, _ local: Any?, _ remote: Any?, path: String, title: String? = nil) -> Any? {
            conflicts.append(MergeConflict(id: path, title: friendly(title ?? path), local: preview(local), incoming: preview(remote)))
            return choices[path] == .incoming ? remote : local
        }
        func friendly(_ path: String) -> String {
            path.replacingOccurrences(of: #" \[[A-Fa-f0-9-]{36}\]"#, with: "", options: .regularExpression)
                .components(separatedBy: "/").map(label).joined(separator: " › ")
        }
        func label(_ key: String) -> String {
            let names = ["worldNotes": "World", "continuityItems": "Shared continuity items", "initialContinuity": "Before the story",
                         "continuityEvents": "Continuity changes", "writingBrief": "Writing brief", "targetWords": "Word goal",
                         "ignoredObjectNames": "Ignored names", "viewpointID": "Viewpoint", "locationID": "Location",
                         "plainText": "Writing", "relativePath": "Reference file", "snapshotPath": "Saved web page",
                         "timelineOrder": "Timeline order", "storyTime": "Story time", "publishingNotes": "Publishing notes",
                         "worldObjectID": "Linked world item", "parentID": "Parent topic", "characterID": "Character", "itemID": "Tracked item"]
            return names[key] ?? key.prefix(1).uppercased() + key.dropFirst()
        }
        func preview(_ value: Any?) -> String {
            guard let value else { return "Deleted" }
            if let string = value as? String { return names[string] ?? string }
            if let dict = value as? [String: Any], let body = dict["plainText"] as? String { return (dict["title"] as? String ?? "Chapter") + "\n\n" + body }
            if let dict = value as? [String: Any] {
                let hidden: Set<String> = ["id", "richText", "createdAt", "modifiedAt", "schemaVersion"]
                return dict.keys.sorted().filter { !hidden.contains($0) }.map { key in label(key) + ": " + preview(dict[key]) }.joined(separator: "\n\n")
            }
            if let values = value as? [String] { return values.joined(separator: "\n") }
            if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { return text }
            return String(describing: value)
        }
        mutating func merge(_ base: Any?, _ local: Any?, _ remote: Any?, path: String) -> Any? {
            if equal(local, remote) { return local }
            if equal(local, base) { return remote }
            if equal(remote, base) { return local }
            if let b = base as? [String: Any], let l = local as? [String: Any], let r = remote as? [String: Any] {
                if b["richText"] != nil { return chapter(b, l, r, path: path) }
                var result: [String: Any] = [:]
                let anchorKeys: Set<String> = ["start", "length", "quote", "detached"]
                let anchored = b["length"] != nil && b["start"] != nil
                if anchored {
                    let ba = b.filter { anchorKeys.contains($0.key) }, la = l.filter { anchorKeys.contains($0.key) }, ra = r.filter { anchorKeys.contains($0.key) }
                    let anchor: [String: Any]
                    if equal(la, ra) || equal(ra, ba) { anchor = la }
                    else if equal(la, ba) { anchor = ra }
                    else { anchor = conflict(ba, la, ra, path: path + "/passage anchor") as? [String: Any] ?? la }
                    result.merge(anchor) { _, new in new }
                }
                for key in Set(b.keys).union(l.keys).union(r.keys).sorted() where !anchored || !anchorKeys.contains(key) {
                    if key == "modifiedAt" { result[key] = l[key]; continue }
                    result[key] = merge(b[key], l[key], r[key], path: path + "/" + key)
                }
                return result
            }
            if let l = local as? [Any], let r = remote as? [Any] {
                let b = base as? [Any] ?? []
                if (b + l + r).allSatisfy({ ($0 as? [String: Any])?["id"] is String }) { return records(b, l, r, path: path) }
                if (b + l + r).allSatisfy({ $0 is String }) {
                    let bs = Set(b.compactMap { $0 as? String }), ls = Set(l.compactMap { $0 as? String }), rs = Set(r.compactMap { $0 as? String })
                    return bs.intersection(ls).intersection(rs).union(ls.subtracting(bs)).union(rs.subtracting(bs)).sorted()
                }
            }
            return conflict(base, local, remote, path: path)
        }

        mutating func records(_ base: [Any], _ local: [Any], _ remote: [Any], path: String) -> [Any] {
            func keyed(_ values: [Any]) -> [String: Any] { Dictionary(uniqueKeysWithValues: values.map { (($0 as! [String: Any])["id"] as! String, $0) }) }
            func ids(_ values: [Any]) -> [String] { values.map { ($0 as! [String: Any])["id"] as! String } }
            let b = keyed(base), l = keyed(local), r = keyed(remote)
            var values: [String: Any] = [:]
            for id in Set(b.keys).union(l.keys).union(r.keys).sorted() {
                let label = ((l[id] ?? r[id] ?? b[id]) as? [String: Any]).flatMap { ($0["title"] ?? $0["name"]) as? String } ?? "Record"
                values[id] = merge(b[id], l[id], r[id], path: path + "/" + label + " [" + id + "]")
            }
            let retained = Set(values.keys)
            let bi = ids(base).filter { retained.contains($0) }, li = ids(local).filter { retained.contains($0) }, ri = ids(remote).filter { retained.contains($0) }
            let order = mergeOrder(base: bi, local: li, remote: ri, retained: retained, path: path)
            if let index = conflicts.firstIndex(where: { $0.id == path + "/order" }) {
                func titles(_ ids: [String]) -> String {
                    ids.map { id in ((values[id] as? [String: Any]).flatMap { ($0["title"] ?? $0["name"]) as? String }) ?? "Entry" }.joined(separator: "\n")
                }
                conflicts[index].local = titles(li); conflicts[index].incoming = titles(ri)
            }
            return order.compactMap { values[$0] }
        }

        /// Combine compatible ordering constraints; concurrent additions retain
        /// their neighbors and use UUID order only to break otherwise equal ties.
        mutating func mergeOrder(base: [String], local: [String], remote: [String], retained: Set<String>, path: String) -> [String] {
            let all = retained.sorted()
            let bp = Dictionary(uniqueKeysWithValues: base.enumerated().map { ($0.element, $0.offset) })
            let lp = Dictionary(uniqueKeysWithValues: local.enumerated().map { ($0.element, $0.offset) })
            let rp = Dictionary(uniqueKeysWithValues: remote.enumerated().map { ($0.element, $0.offset) })
            func before(_ map: [String: Int], _ a: String, _ b: String) -> Bool? { guard let x = map[a], let y = map[b] else { return nil }; return x < y }
            var edges: [String: Set<String>] = [:]
            for (i, a) in all.enumerated() {
                for b in all.dropFirst(i + 1) {
                    let bv = before(bp, a, b), lv = before(lp, a, b), rv = before(rp, a, b)
                    let directions: [Bool]
                    if let bv { directions = [lv != nil && lv != bv ? lv! : (rv ?? lv ?? bv)] }
                    else { directions = Array(Set([lv, rv].compactMap { $0 })) }
                    for forward in directions { edges[forward ? a : b, default: []].insert(forward ? b : a) }
                }
            }
            var pending = retained, result: [String] = []
            while !pending.isEmpty {
                guard let next = pending.sorted().first(where: { candidate in !pending.contains(where: { edges[$0]?.contains(candidate) == true }) }) else {
                    _ = conflict(base, local, remote, path: path + "/order", title: path + ": conflicting order")
                    let preferred = choices[path + "/order"] == .incoming ? remote : local
                    return preferred + all.filter { !preferred.contains($0) }
                }
                result.append(next); pending.remove(next)
            }
            return result
        }

        mutating func chapter(_ b: [String: Any], _ l: [String: Any], _ r: [String: Any], path: String) -> [String: Any] {
            func decode(_ value: [String: Any]) -> Chapter? {
                guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                return try? decoder.decode(Chapter.self, from: data)
            }
            guard let bc = decode(b), let lc = decode(l), let rc = decode(r) else { return conflict(b, l, r, path: path) as? [String: Any] ?? l }
            let bodyID = path + "/writing and formatting"
            let writing = RichTextMerge.resolve(base: bc.attributedText, local: lc.attributedText, incoming: rc.attributedText, path: bodyID, title: lc.title, choices: choices)
            let text = writing.text
            conflicts.append(contentsOf: writing.conflicts.map { conflict in var conflict = conflict; conflict.chapterID = lc.id; return conflict })
            func aligned(_ chapter: Chapter) -> [String: Any] {
                var copy = chapter
                RichTextMerge.rebase(&copy, to: text.string)
                return (try? object(copy) as? [String: Any]) ?? [:]
            }
            let ba = aligned(bc), la = aligned(lc), ra = aligned(rc)
            var result: [String: Any] = [:]
            for key in Set(b.keys).union(l.keys).union(r.keys).sorted() where key != "richText" && key != "plainText" {
                result[key] = merge(ba[key], la[key], ra[key], path: path + "/" + key)
            }
            if let data = try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) { result["richText"] = data.base64EncodedString() }
            else { return conflict(b, l, r, path: bodyID) as? [String: Any] ?? l }
            result["plainText"] = text.string
            if let scenes = result["scenes"] as? [[String: Any]] { result["scenes"] = scenes.sorted { ($0["start"] as? Int ?? 0) < ($1["start"] as? Int ?? 0) } }
            return result
        }
    }
}

enum RichTextMerge {
    private struct Unit: Equatable {
        var text: NSAttributedString
        static func == (lhs: Self, rhs: Self) -> Bool {
            if lhs.text.isEqual(to: rhs.text) { return true }
            guard lhs.text.string == rhs.text.string else { return false }
            // RTFD decoding creates new attachment objects. Compare their files,
            // otherwise an untouched image would look like an overlapping edit.
            for i in 0..<lhs.text.length {
                var a = lhs.text.attributes(at: i, effectiveRange: nil), b = rhs.text.attributes(at: i, effectiveRange: nil)
                if let aa = a[.attachment] as? NSTextAttachment, let bb = b[.attachment] as? NSTextAttachment,
                   let af = aa.fileWrapper, let bf = bb.fileWrapper {
                    guard sameFile(af, bf) else { return false }
                    a[.attachment] = nil; b[.attachment] = nil
                }
                guard NSDictionary(dictionary: a).isEqual(to: b) else { return false }
            }
            return true
        }
        private static func sameFile(_ a: FileWrapper, _ b: FileWrapper) -> Bool {
            if a.isRegularFile && b.isRegularFile { return a.regularFileContents == b.regularFileContents && a.preferredFilename == b.preferredFilename }
            if a.isDirectory && b.isDirectory {
                let aa = a.fileWrappers ?? [:], bb = b.fileWrappers ?? [:]
                return Set(aa.keys) == Set(bb.keys) && aa.allSatisfy { key, file in bb[key].map { sameFile(file, $0) } == true }
            }
            return false
        }
    }
    struct Edit { var old: NSRange; var replacement: NSAttributedString }

    /// Diff whole graphemes, including their attributes and project links.
    static func edits(from old: NSAttributedString, to new: NSAttributedString) -> [Edit]? {
        func units(_ text: NSAttributedString) -> ([Unit], [Int]) {
            var result: [Unit] = [], offsets = [0]
            for character in text.string {
                let start = offsets.last!, length = String(character).utf16.count
                result.append(Unit(text: text.attributedSubstring(from: NSRange(location: start, length: length))))
                offsets.append(start + length)
            }
            return (result, offsets)
        }
        // Bound pathological diffs. Large overlapping rewrites go to review.
        guard old.string.count + new.string.count <= 80_000 else { return nil }
        let (a, ao) = units(old), (b, bo) = units(new)
        guard let (removed, inserted) = changedIndices(a, b) else { return nil }
        var i = 0, j = 0, result: [Edit] = []
        while i < a.count || j < b.count {
            if removed.contains(i) || inserted.contains(j) {
                let si = i, sj = j
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
                result.append(Edit(old: NSRange(location: ao[si], length: ao[i] - ao[si]), replacement: new.attributedSubstring(from: NSRange(location: bo[sj], length: bo[j] - bo[sj]))))
            } else {
                guard i < a.count, j < b.count, a[i] == b[j] else { return nil }
                i += 1; j += 1
            }
        }
        return result
    }
    /// Bounded Myers diff: small edits remain cheap even far apart in a chapter;
    /// extensive rewrites cannot allocate an unbounded diff or stall writing.
    private static func changedIndices(_ a: [Unit], _ b: [Unit]) -> (Set<Int>, Set<Int>)? {
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        let limit = min(1024, n + m), offset = limit + 1
        guard abs(n - m) <= limit else { return nil }
        var frontier = [Int](repeating: -1, count: 2 * limit + 3), trace: [[Int]] = []
        frontier[offset + 1] = 0
        for depth in 0...limit {
            trace.append(frontier)
            for diagonal in stride(from: -depth, through: depth, by: 2) {
                let index = offset + diagonal
                var x = diagonal == -depth || (diagonal != depth && frontier[index - 1] < frontier[index + 1]) ? frontier[index + 1] : frontier[index - 1] + 1
                var y = x - diagonal
                while x >= 0, y >= 0, x < n, y < m, a[prefix + x] == b[prefix + y] { x += 1; y += 1 }
                frontier[index] = x
                if x >= n, y >= m {
                    var removed = Set<Int>(), inserted = Set<Int>()
                    for d in stride(from: depth, through: 0, by: -1) {
                        let previous = trace[d], k = x - y, i = offset + k
                        let pk = k == -d || (k != d && previous[i - 1] < previous[i + 1]) ? k + 1 : k - 1
                        let px = previous[offset + pk], py = px - pk
                        while x > px, y > py { x -= 1; y -= 1 }
                        if d > 0 {
                            if x == px { y -= 1; inserted.insert(prefix + y) }
                            else { x -= 1; removed.insert(prefix + x) }
                        }
                    }
                    return (removed, inserted)
                }
            }
        }
        return nil
    }
    static func overlap(_ a: NSRange, _ b: NSRange) -> Bool {
        if a.length == 0 { return a.location >= b.location && a.location <= NSMaxRange(b) }
        if b.length == 0 { return overlap(b, a) }
        return NSIntersectionRange(a, b).length > 0
    }
    static func merge(base: NSAttributedString, local: NSAttributedString, incoming: NSAttributedString) -> NSAttributedString? {
        let result = resolve(base: base, local: local, incoming: incoming, path: "Writing", title: "Writing", choices: [:])
        return result.conflicts.isEmpty ? result.text : nil
    }
    static func resolve(base: NSAttributedString, local: NSAttributedString, incoming: NSAttributedString,
                        path: String, title: String, choices: [String: MergeChoice]) -> (text: NSAttributedString, conflicts: [MergeConflict]) {
        if Unit(text: local) == Unit(text: incoming) || Unit(text: incoming) == Unit(text: base) { return (local, []) }
        if Unit(text: local) == Unit(text: base) { return (incoming, []) }
        guard let le = edits(from: base, to: local), let re = edits(from: base, to: incoming) else {
            let conflict = MergeConflict(id: path, title: title + ": review writing and formatting", local: local.string, incoming: incoming.string, localWriting: local, incomingWriting: incoming)
            return (choices[path] == .incoming ? incoming : local, [conflict])
        }
        struct BranchEdit { var edit: Edit; var side: MergeChoice }
        var entries = le.map { BranchEdit(edit: $0, side: .local) }
        for edit in re where !le.contains(where: { $0.old == edit.old && Unit(text: $0.replacement) == Unit(text: edit.replacement) }) {
            entries.append(BranchEdit(edit: edit, side: .incoming))
        }
        var groups: [[BranchEdit]] = []
        for entry in entries.sorted(by: { $0.edit.old.location < $1.edit.old.location }) {
            if let last = groups.last, last.contains(where: { overlap($0.edit.old, entry.edit.old) }) { groups[groups.count - 1].append(entry) }
            else { groups.append([entry]) }
        }
        var combined: [Edit] = [], conflicts: [MergeConflict] = []
        for group in groups {
            if Set(group.map { $0.side.rawValue }).count == 1 { combined.append(contentsOf: group.map(\.edit)); continue }
            let range = group.map { $0.edit.old }.reduce(group[0].edit.old, NSUnionRange)
            let id = path + "/\(range.location):\(range.length)"
            // Include the paragraph around the overlap so the writer can assess
            // punctuation, links and formatting rather than a contextless fragment.
            let context = (base.string as NSString).paragraphRange(for: range)
            func preview(_ side: MergeChoice) -> NSAttributedString {
                let result = NSMutableAttributedString(attributedString: base.attributedSubstring(from: context))
                for entry in group.filter({ $0.side == side }).sorted(by: { $0.edit.old.location > $1.edit.old.location }) {
                    result.replaceCharacters(in: NSRange(location: entry.edit.old.location - context.location, length: entry.edit.old.length), with: entry.edit.replacement)
                }
                return result
            }
            let lp = preview(.local), rp = preview(.incoming)
            conflicts.append(MergeConflict(id: id, title: title + ": overlapping passage", local: lp.string, incoming: rp.string, localWriting: lp, incomingWriting: rp))
            combined.append(contentsOf: group.filter { $0.side == (choices[id] ?? .local) }.map(\.edit))
        }
        let result = NSMutableAttributedString(attributedString: base)
        for edit in combined.sorted(by: { $0.old.location > $1.old.location }) { result.replaceCharacters(in: edit.old, with: edit.replacement) }
        return (result, conflicts)
    }
    static func rebase(_ chapter: inout Chapter, to new: String) {
        guard chapter.plainText != new else { return }
        // Rebase one hunk at a time so edits on either side of an anchor do not
        // turn the entire span between them into a deleted passage.
        let old = NSAttributedString(string: chapter.plainText), target = NSAttributedString(string: new)
        guard let changes = edits(from: old, to: target) else { chapter.rebaseAnnotations(from: chapter.plainText, to: new); chapter.plainText = new; return }
        var current = chapter.plainText
        for change in changes.sorted(by: { $0.old.location > $1.old.location }) {
            let next = (current as NSString).replacingCharacters(in: change.old, with: change.replacement.string)
            chapter.rebaseAnnotations(from: current, to: next); current = next
        }
        chapter.plainText = new
    }
}
