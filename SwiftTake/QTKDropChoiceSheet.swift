import SwiftUI

/// Owns the bytes captured while Finder grants access to the dropped files.
struct QTKDropBatch: Identifiable {
    let id = UUID()
    let files: [URL: Data]
}

struct QTKDropChoiceSheet: View {
    let count: Int
    let canMakePanorama: Bool
    let onConvert: () -> Void
    let onPanorama: () -> Void
    let onCancel: () -> Void
    @Environment(\.isClassicTheme) private var classic

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Use These QTK Files")
                .font(classic ? .classic(18, weight: .bold) : .title2.weight(.semibold))
            Text("Convert these \(count) files into individual photos, or combine overlapping shots into a panorama.")
                .font(classic ? .classic(12) : .body)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Button("Convert Photos", action: onConvert)
                    .modifier(PrimaryButtonModifier())
                    .keyboardShortcut(.defaultAction)
                Text("Use your current photo format and save location.")
                    .font(classic ? .classic(11) : .callout).foregroundStyle(.secondary)
                Divider()
                Button("Make Panorama", action: onPanorama)
                    .modifier(SecondaryButtonModifier())
                    .disabled(!canMakePanorama || count > PanoramaStitcher.maxFrameCount)
                Text(panoramaHint)
                    .font(classic ? .classic(11) : .callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .modifier(SecondaryButtonModifier()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(28).frame(width: 480)
        .background(classic ? AnyShapeStyle(AppTheme.platinumFace) : AnyShapeStyle(.background))
    }

    private var panoramaHint: String {
        if count > PanoramaStitcher.maxFrameCount {
            return "A panorama supports up to \(PanoramaStitcher.maxFrameCount) photos. Drop a smaller set to stitch."
        }
        if !canMakePanorama { return "Finish the current camera or panorama operation first." }
        return "Review the photo order before stitching."
    }
}
