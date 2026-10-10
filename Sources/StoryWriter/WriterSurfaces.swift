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
        Color(nsColor: dimPaper ? NSColor(srgbRed: 0.13, green: 0.14, blue: 0.15, alpha: 1) : Self.color)
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
