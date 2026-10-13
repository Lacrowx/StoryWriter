import AppKit

extension String {
    /// Copy Cocoa text in bulk instead of walking a live text-storage proxy.
    init(copyingUTF16 source: NSString) {
        let length = source.length
        guard length > 0 else { self = ""; return }
        let units = Array<UInt16>(unsafeUninitializedCapacity: length) { buffer, initialized in
            source.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: length))
            initialized = length
        }
        self = String(decoding: units, as: UTF16.self)
    }
}

/// An immutable editing snapshot or an RTFD archive. The on-disk representation
/// remains the same base64 Data value used by existing portable projects.
struct ChapterText: Codable, Equatable {
    private let archive: Data?
    private let snapshot: Snapshot?

    private final class Snapshot {
        let text: NSAttributedString
        private var archive: Data?
        private let archiveLock = NSLock()
        init(_ text: NSAttributedString) { self.text = NSAttributedString(attributedString: text) }
        func data() throws -> Data {
            archiveLock.lock()
            defer { archiveLock.unlock() }
            if let archive { return archive }
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            archive = data
            return data
        }
    }

    init(data: Data = Data()) { archive = data; snapshot = nil }
    init(text: NSAttributedString) { archive = nil; snapshot = Snapshot(text) }

    func attributedText() throws -> NSAttributedString {
        if let snapshot { return snapshot.text }
        return try NSAttributedString(data: archive ?? Data(),
                                      options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    }

    init(from decoder: Decoder) throws {
        self.init(data: try decoder.singleValueContainer().decode(Data.self))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // Serialization failures propagate to the existing save failure handling.
        try container.encode(try snapshot?.data() ?? archive ?? Data())
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        if let left = lhs.snapshot, let right = rhs.snapshot {
            return left === right || left.text.isEqual(to: right.text)
        }
        if lhs.snapshot == nil, rhs.snapshot == nil { return lhs.archive == rhs.archive }
        guard let left = try? lhs.attributedText(), let right = try? rhs.attributedText() else { return false }
        return left.isEqual(to: right)
    }
}
