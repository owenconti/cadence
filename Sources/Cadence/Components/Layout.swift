import SwiftUI

/// Scrollable page body with consistent gutters and an automatic back button
/// when the current route was pushed onto the navigation stack.
struct PageScroll<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                content
            }
            .padding(.horizontal, 36)
            .padding(.top, Theme.titlebarInset + 18)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .overlay(alignment: .topLeading) {
            if !model.stack.isEmpty {
                Button(action: model.back) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .background(Circle().fill(.ultraThinMaterial))
                .help("Back (⌘[)")
                .padding(.leading, 28)
                .padding(.top, 12)
            }
        }
    }
}

struct SectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.display(21))
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Square (or circular) card with a hover play button.
struct MediaCard: View {
    let title: String
    let subtitle: String
    let artwork: ArtworkSource
    var circular = false
    var width: CGFloat? = 164
    let open: () -> Void
    var play: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: circular ? .center : .leading, spacing: 10) {
            ArtworkView(source: artwork, cornerRadius: 10, circular: circular, resolution: 360)
                .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 16 : 8, y: hovering ? 10 : 4)
                .overlay(alignment: .bottomTrailing) {
                    if let play, hovering {
                        PlayFab(size: 38, action: play)
                            .padding(10)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            VStack(alignment: circular ? .center : .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
        }
        .padding(10)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hovering ? Theme.card : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
    }
}

struct CardRow<Item: Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 6) {
                ForEach(items) { card($0) }
            }
            .padding(.horizontal, 26)
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -36)
    }
}

struct LoadingRows: View {
    var count = 6
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 10).fill(Theme.card).frame(height: 44)
            }
        }
        .opacity(pulse ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
        .onAppear { pulse = true }
    }
}

struct EmptyNote: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}
