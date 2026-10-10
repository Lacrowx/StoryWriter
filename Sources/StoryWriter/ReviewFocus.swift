import SwiftUI

@MainActor
final class ReviewFocus: ObservableObject {
    @Published var session: InlineGrammarSession?
    func activate(_ session: InlineGrammarSession?) { if self.session !== session { self.session = session } }
}
private struct ReviewFocusKey: EnvironmentKey { static let defaultValue: ReviewFocus? = nil }
extension EnvironmentValues {
    var reviewFocus: ReviewFocus? { get { self[ReviewFocusKey.self] } set { self[ReviewFocusKey.self] = newValue } }
}

struct FieldSuggestionBadge: View {
    @ObservedObject var session: InlineGrammarSession
    var body: some View {
        if !session.corrections.isEmpty {
            Button { session.next() } label: { Label("\(session.corrections.count)", systemImage: "text.badge.checkmark") }.buttonStyle(.plain).font(.caption2).foregroundStyle(.orange).help("Review suggestions for this field").padding(5)
        } else if session.checking { ProgressView().controlSize(.mini).padding(5) }
    }
}

enum ReadingWidth: String, CaseIterable, Identifiable {
    case narrow = "Narrow", medium = "Medium", full = "Full width"
    var id: String { rawValue }
    var points: CGFloat { switch self { case .narrow: return 600; case .medium: return 840; case .full: return .infinity } }
}
