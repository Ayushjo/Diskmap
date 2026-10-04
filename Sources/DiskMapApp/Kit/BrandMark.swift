import SwiftUI
import DiskMapBrand

/// Dusty peeking over the cleared stack, shared with the site and Dock icon.
struct DiskMapMark: View {
    var ink: Color = DiskMapTheme.ink
    var accent: Color = DiskMapTheme.accent

    static let aspect: CGFloat = 95 / 144

    var body: some View {
        Group {
            if let mark = DiskMapBrand.peekMark {
                Image(nsImage: mark)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Keep a visible mark if the resource bundle is unavailable.
                ZStack {
                    ClearedStackShape(segment: 0).fill(ink)
                    ClearedStackShape(segment: 1).fill(Color(red: 109.0 / 255.0, green: 119.0 / 255.0, blue: 130.0 / 255.0))
                    ClearedStackShape(segment: 2).fill(accent)
                }
                .aspectRatio(106.0 / 92.0, contentMode: .fit)
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct ClearedStackShape: Shape {
    let segment: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch segment {
        case 0:
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: 106, height: 22), cornerSize: CGSize(width: 11, height: 11))
        case 1:
            path.addRoundedRect(in: CGRect(x: 0, y: 35, width: 82, height: 22), cornerSize: CGSize(width: 11, height: 11))
        case 2:
            path.addRoundedRect(in: CGRect(x: 0, y: 70, width: 53, height: 22), cornerSize: CGSize(width: 11, height: 11))
        default:
            path.addRoundedRect(in: CGRect(x: 91, y: 44, width: 15, height: 4), cornerSize: CGSize(width: 2, height: 2))
            path.addRoundedRect(in: CGRect(x: 63, y: 79, width: 43, height: 4), cornerSize: CGSize(width: 2, height: 2))
        }
        let scale = min(rect.width / 106, rect.height / 92)
        let x = rect.minX + (rect.width - 106 * scale) / 2
        let y = rect.minY + (rect.height - 92 * scale) / 2
        return path
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: x, y: y))
    }
}

/// Product wordmark. Internal Swift types retain their original names for compatibility.
struct DiskMapWordmark: View {
    var height: CGFloat = 30

    var body: some View {
        HStack(alignment: .bottom, spacing: height * 0.12) {
            DiskMapMark()
                .frame(width: height * DiskMapMark.aspect, height: height)
            (Text("freedisk").foregroundColor(DiskMapTheme.ink)
             + Text(".space").foregroundColor(DiskMapTheme.accent))
                .font(.system(size: height * 0.53, weight: .bold))
                .tracking(-0.018 * height)
                .padding(.bottom, height * 0.07)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("freedisk.space")
    }
}
