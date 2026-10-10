import AppKit

struct PencilAnchorLine {
    var selection: NSRect
    var text: NSRect
}

struct PencilConnector {
    var start: NSPoint
    var control1: NSPoint
    var control2: NSPoint
    var end: NSPoint
    var bracket: NSRect?
    var edgeMark: Bool

    func point(at t: CGFloat) -> NSPoint {
        let u = 1 - t
        return NSPoint(x: u * u * u * start.x + 3 * u * u * t * control1.x + 3 * u * t * t * control2.x + t * t * t * end.x,
                       y: u * u * u * start.y + 3 * u * u * t * control1.y + 3 * u * t * t * control2.y + t * t * t * end.y)
    }
}

enum PencilRouting {
    /// Connect across a short, empty line tail, or use a marker in the gutter.
    /// Wrapped passages get a bracket so a short final word cannot create a page-wide leader.
    static func connector(lines: [PencilAnchorLine], textEdge: CGFloat, note: NSRect) -> PencilConnector? {
        let lines = lines.filter { $0.selection.width > 0 && $0.selection.height > 0 }.sorted { $0.selection.minY < $1.selection.minY }
        guard let first = lines.first, let last = lines.last else { return nil }
        let end = NSPoint(x: note.minX - 4, y: note.minY + 16)
        let line = lines.min { abs($0.selection.midY - end.y) < abs($1.selection.midY - end.y) }!
        let shortTail = textEdge - line.selection.maxX <= 72
        let noFollowingText = line.selection.maxX >= line.text.maxX - 3
        let direct = lines.count == 1 && shortTail && noFollowingText && abs(line.selection.maxY - end.y) <= 44
        let gutterX = min(textEdge + 6, end.x - 2)
        let bracket: NSRect? = lines.count > 1
            ? NSRect(x: textEdge + 2, y: first.selection.midY - 3, width: max(1, gutterX - textEdge - 2), height: max(10, last.selection.midY - first.selection.midY + 6))
            : nil
        let y = bracket?.midY ?? line.selection.midY
        let start = direct ? NSPoint(x: min(end.x - 2, line.selection.maxX + 4), y: line.selection.maxY + 2) : NSPoint(x: gutterX, y: y)
        let dx = max(0, end.x - start.x)
        // Horizontal tangents with ordered handles make a gentle S, never a backwards hook.
        return PencilConnector(start: start,
                               control1: NSPoint(x: start.x + dx * 0.42, y: start.y),
                               control2: NSPoint(x: end.x - dx * 0.42, y: end.y),
                               end: end, bracket: bracket, edgeMark: !direct && bracket == nil)
    }

    static func path(_ connector: PencilConnector, seed: Int) -> NSBezierPath {
        let path = NSBezierPath(); path.lineWidth = 0.9; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: connector.start)
        // A faint, deterministic wobble gives the stroke a pencil feel without doubling it.
        for index in 1...24 {
            let t = CGFloat(index) / 24
            let point = connector.point(at: t)
            let before = connector.point(at: max(0, t - 0.01)), after = connector.point(at: min(1, t + 0.01))
            let dx = after.x - before.x, dy = after.y - before.y
            let length = max(1, hypot(dx, dy))
            let wobble = sin(t * .pi) * sin(t * .pi * 3 + CGFloat(seed % 5)) * 0.28
            path.line(to: NSPoint(x: point.x - dy / length * wobble, y: point.y + dx / length * wobble))
        }
        return path
    }

    static func marker(_ connector: PencilConnector) -> NSBezierPath {
        let path = NSBezierPath(); path.lineWidth = 0.9; path.lineCapStyle = .round
        if let bracket = connector.bracket {
            path.move(to: NSPoint(x: bracket.minX - 2, y: bracket.minY))
            path.curve(to: NSPoint(x: bracket.maxX, y: bracket.midY),
                       controlPoint1: NSPoint(x: bracket.maxX + 1, y: bracket.minY + 1),
                       controlPoint2: NSPoint(x: bracket.minX + 1, y: bracket.midY - 4))
            path.curve(to: NSPoint(x: bracket.minX - 2, y: bracket.maxY),
                       controlPoint1: NSPoint(x: bracket.minX + 1, y: bracket.midY + 4),
                       controlPoint2: NSPoint(x: bracket.maxX + 1, y: bracket.maxY - 1))
        } else if connector.edgeMark {
            path.move(to: NSPoint(x: connector.start.x - 4, y: connector.start.y - 4))
            path.curve(to: NSPoint(x: connector.start.x - 4, y: connector.start.y + 4),
                       controlPoint1: NSPoint(x: connector.start.x + 1, y: connector.start.y - 3),
                       controlPoint2: NSPoint(x: connector.start.x, y: connector.start.y + 3))
        }
        return path
    }
}
