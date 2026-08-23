#if canImport(SwiftUI)
import AppKit
import SwiftUI

enum ArchivePalette {
    static let jade = Color(red: 0.04, green: 0.48, blue: 0.39)
    static let ocean = Color(red: 0.08, green: 0.30, blue: 0.49)
    static let ink = Color(red: 0.08, green: 0.13, blue: 0.16)
    static let mist = Color(red: 0.94, green: 0.97, blue: 0.96)
    static let gold = Color(red: 0.91, green: 0.66, blue: 0.23)
}

struct ArchiveBrandMark: View {
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [ArchivePalette.jade, ArchivePalette.ocean], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
            Image(systemName: "archivebox.fill")
                .font(.system(size: size * 0.47, weight: .semibold))
                .foregroundStyle(.white)
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.20, weight: .bold))
                .foregroundStyle(ArchivePalette.gold)
                .offset(x: size * 0.26, y: -size * 0.25)
        }
        .frame(width: size, height: size)
        .shadow(color: ArchivePalette.ocean.opacity(0.25), radius: size * 0.13, y: size * 0.07)
        .accessibilityLabel("微信聊天归档")
    }
}

struct ArchiveBrandHeader: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 9 : 11) {
            ArchiveBrandMark(size: compact ? 31 : 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("微信聊天归档")
                    .font(compact ? .headline : .title3.weight(.semibold))
                if !compact {
                    Text("只在本机保存，随时离线查看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ArchiveSectionTitle: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(ArchivePalette.jade, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ArchiveCanvas: View {
    var body: some View {
        LinearGradient(
            colors: [ArchivePalette.mist, Color(nsColor: .windowBackgroundColor)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

extension View {
    func archiveCard() -> some View {
        padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }
}

@MainActor
enum ArchiveApplicationIcon {
    static func install() {
        NSApplication.shared.applicationIconImage = makeImage()
    }

    private static func makeImage() -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size)
        image.lockFocus()
        let canvas = NSRect(origin: .zero, size: size)
        let shape = NSBezierPath(roundedRect: canvas.insetBy(dx: 44, dy: 44), xRadius: 225, yRadius: 225)
        NSGradient(starting: NSColor(calibratedRed: 0.04, green: 0.48, blue: 0.39, alpha: 1), ending: NSColor(calibratedRed: 0.08, green: 0.30, blue: 0.49, alpha: 1))?.draw(in: shape, angle: -45)
        if let symbol = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 470, weight: .bold)) {
            symbol.draw(in: NSRect(x: 266, y: 245, width: 492, height: 492))
        }
        NSColor(calibratedRed: 0.91, green: 0.66, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 690, y: 670, width: 116, height: 116)).fill()
        image.unlockFocus()
        return image
    }
}
#endif
