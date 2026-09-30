//
//  DisplayMetrics.swift
//  Starlight
//

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
enum DisplayMetrics {
    /// Pixel size of the area the stream will fill, always in landscape since
    /// that's how streams are presented. Returns `nil` when there's no display
    /// to measure.
    static func streamSize(useSafeArea: Bool) -> PixelSize? {
#if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.keyWindow ?? scene.windows.first else {
            return nil
        }

        var size = window.bounds.size
        let insets = window.safeAreaInsets
        var horizontalInsets = insets.left + insets.right
        if size.width < size.height {
            size = CGSize(width: size.height, height: size.width)
            // In landscape the sensor housing is inset on both sides
            horizontalInsets = window.traitCollection.userInterfaceIdiom == .phone
                ? 2 * max(insets.top, insets.bottom)
                : 0
        }
        if !useSafeArea {
            horizontalInsets = 0
        }
        return makeSize(width: size.width - horizontalInsets, height: size.height, scale: scene.screen.scale)
#elseif os(macOS)
        guard let screen = NSScreen.main else {
            return nil
        }

        var size = screen.frame.size
        if useSafeArea {
            let insets = screen.safeAreaInsets
            size.width -= insets.left + insets.right
            size.height -= insets.top + insets.bottom
        }
        return makeSize(width: size.width, height: size.height, scale: screen.backingScaleFactor)
#else
        return nil
#endif
    }

    /// Converts points to pixels, rounding down to even numbers since video
    /// encoders require even dimensions.
    private static func makeSize(width: CGFloat, height: CGFloat, scale: CGFloat) -> PixelSize {
        PixelSize(width: Int(width * scale) & ~1, height: Int(height * scale) & ~1)
    }
}
