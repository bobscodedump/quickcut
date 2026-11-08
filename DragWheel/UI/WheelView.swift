import SwiftUI
import AppKit

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct SliceShape: Shape {
    let geometry: WheelGeometry
    let ring: WheelRing
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        geometry.slicePath(ring: ring, index: index, count: count, center: CGPoint(x: rect.midX, y: rect.midY))
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel

    private var accent: Color { Color(nsColor: .controlAccentColor) }

    var body: some View {
        if let message = model.message {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(VisualEffectBackground().clipShape(Capsule()))
                .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                .scaleEffect(model.isPresented ? 1 : 0.7)
                .opacity(model.isPresented ? 1 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.isPresented)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            wheel
        }
    }

    private var wheel: some View {
        let g = WheelGeometry(scale: model.scale)
        return GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            ZStack {
                VisualEffectBackground()
                    .mask { glassMask(g, size) }
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)

                ForEach(Array(model.primary.enumerated()), id: \.element.id) { index, slice in
                    sliceView(slice, ring: .primary, index: index, count: model.primary.count, g: g, size: size, center: center)
                }
                if model.expanded {
                    ForEach(Array(model.secondary.enumerated()), id: \.element.id) { index, slice in
                        sliceView(slice, ring: .secondary, index: index, count: model.secondary.count, g: g, size: size, center: center)
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                hub(g).position(center)
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(model.isPresented ? 1 : 0.4)
            .opacity(model.isPresented ? 1 : 0)
            .animation(.spring(response: 0.38, dampingFraction: 0.72), value: model.isPresented)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.expanded)
        }
    }

    private func glassMask(_ g: WheelGeometry, _ size: CGSize) -> some View {
        ZStack {
            ForEach(Array(model.primary.enumerated()), id: \.element.id) { index, _ in
                SliceShape(geometry: g, ring: .primary, index: index, count: model.primary.count).fill(.black)
            }
            if model.expanded {
                ForEach(Array(model.secondary.enumerated()), id: \.element.id) { index, _ in
                    SliceShape(geometry: g, ring: .secondary, index: index, count: model.secondary.count).fill(.black)
                }
            }
            Circle().fill(.black).frame(width: g.hubRadius * 2, height: g.hubRadius * 2)
        }
        .frame(width: size.width, height: size.height)
    }

    private func sliceView(_ slice: WheelSlice, ring: WheelRing, index: Int, count: Int, g: WheelGeometry, size: CGSize, center: CGPoint) -> some View {
        let isHovered = model.hovered == SliceRef(ring: ring, index: index) && slice.isEnabled
        let highlighted = isHovered || (slice.isMore && model.expanded)
        let labelPoint = g.labelCenter(ring: ring, index: index, count: count, center: center)
        let shape = SliceShape(geometry: g, ring: ring, index: index, count: count)
        let stagger = Double(index) * 0.018

        return ZStack {
            shape.fill(highlighted ? accent.opacity(0.9) : Color.white.opacity(slice.isEnabled ? 0.07 : 0.02))
            shape.stroke(Color.white.opacity(highlighted ? 0.6 : 0.16), lineWidth: 1)
            VStack(spacing: 3 * g.scale) {
                Image(systemName: slice.symbol)
                    .font(.system(size: 22 * g.scale, weight: .medium))
                Text(slice.title)
                    .font(.system(size: 12 * g.scale, weight: .semibold))
            }
            .foregroundStyle(.white)
            .opacity(slice.isEnabled ? 1 : 0.35)
            .position(labelPoint)
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(highlighted ? 1.07 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: highlighted)
        .scaleEffect(model.isPresented ? 1 : 0.3)
        .animation(.spring(response: 0.4, dampingFraction: 0.7).delay(stagger), value: model.isPresented)
    }

    private func hub(_ g: WheelGeometry) -> some View {
        let subtitle: String = {
            if let slice = model.slice(at: model.hovered) {
                if !slice.isEnabled { return slice.disabledReason ?? "Unavailable" }
                return slice.isMore ? "More formats" : "Convert to \(slice.title)"
            }
            return model.centerSubtitle
        }()
        return VStack(spacing: 2) {
            Text(model.centerTitle)
                .font(.system(size: 12 * g.scale, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(subtitle)
                .font(.system(size: 9.5 * g.scale))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(3)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(width: g.hubRadius * 1.75, height: g.hubRadius * 1.75)
    }
}
