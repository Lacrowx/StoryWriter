import AppKit
import SwiftUI

/// Real desktop vibrancy lets the wallpaper inform the workspace and sidebars.
struct DesktopMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct WriterBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                DesktopMaterial(material: .underWindowBackground)
                LinearGradient(colors: [
                    AppTheme.accent.opacity(colorScheme == .dark ? 0.07 : 0.04),
                    Color.clear,
                    Color(red: 0.73, green: 0.65, blue: 0.51).opacity(0.05)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

private struct WriterGlass: ViewModifier {
    var radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.12)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.22)))
        }
    }
}

extension View {
    func writerGlass(radius: CGFloat = 18) -> some View {
        modifier(WriterGlass(radius: radius))
    }
}

/// A restrained, warm sheet. The grain is visual only and never enters the manuscript.
struct ManuscriptPaper: View {
    @AppStorage("dimPaper") private var dimPaper = false
    static let color = NSColor(srgbRed: 0.992, green: 0.981, blue: 0.956, alpha: 1)

    var body: some View {
        Color(nsColor: dimPaper ? NSColor(srgbRed: 0.105, green: 0.115, blue: 0.13, alpha: 1) : Self.color)
            .overlay {
                Canvas { context, size in
                    for row in stride(from: 0, to: Int(size.height), by: 6) {
                        for column in stride(from: 0, to: Int(size.width), by: 6) {
                            let seed = (row &* 31 &+ column &* 17) % 11
                            let rect = CGRect(x: CGFloat(column) + CGFloat(seed) / 3,
                                              y: CGFloat(row), width: 0.7, height: 0.7)
                            context.fill(Path(ellipseIn: rect), with: .color(.brown.opacity(0.025)))
                        }
                    }
                }.allowsHitTesting(false)
            }
    }
}


/// Shared, understated surfaces for planning, research and utility sheets.
private struct WriterCard: ViewModifier {
    var inset: CGFloat
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.padding(inset)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(scheme == .dark ? 0.10 : 0.06)))
            .shadow(color: .black.opacity(scheme == .dark ? 0.08 : 0.025), radius: 8, y: 3)
    }
}

extension View {
    func cardSurface(inset: CGFloat = 20) -> some View { modifier(WriterCard(inset: inset)) }
    func writerSheet() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
            .controlSize(.regular)
    }
}

struct WriterSearchField: View {
    var title: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(title, text: $text).textFieldStyle(.plain).focused($focused)
                .accessibilityLabel(title)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 9)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.07), lineWidth: focused ? 2 : 1))
    }
}

struct WriterSymbol: View {
    var name: String
    var body: some View {
        Image(systemName: name).font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.accentColor).frame(width: 34, height: 34)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

struct WriterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary).frame(width: 28, height: 28)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.045), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
