//
//  LandscapeCover.swift
//  Starlight
//
//  Presents a view full screen in landscape without rotating the rest of the
//  app. Only the topmost full-screen modal controller decides the orientation,
//  which fullScreenCover doesn't let us customize.
//

#if os(iOS)
import SwiftUI

extension View {
    /// Like fullScreenCover(item:), but the cover is always landscape.
    func landscapeCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        background(LandscapePresenter(item: item, content: content))
    }
}

private struct LandscapePresenter<Item: Identifiable, Content: View>: UIViewControllerRepresentable {
    let item: Binding<Item?>
    let content: (Item) -> Content

    final class Coordinator {
        var presented: UIViewController?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    // Only presents. A full-screen presentation removes the presenting views
    // from the window, which stops SwiftUI from updating them, so the cover
    // watches the item and dismisses itself.
    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.presented == nil, let current = item.wrappedValue,
              var presenter = anchor.view.window?.rootViewController else {
            return
        }
        while let next = presenter.presentedViewController {
            presenter = next
        }

        let cover = LandscapeCoverContent(item: item, shownID: current.id, content: content(current)) {
            coordinator.presented?.dismiss(animated: true)
            coordinator.presented = nil
        }
        let controller = LandscapeHostingController(rootView: cover)
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
        coordinator.presented = controller
    }
}

private struct LandscapeCoverContent<Item: Identifiable, Content: View>: View {
    let item: Binding<Item?>
    let shownID: Item.ID
    let content: Content
    let dismiss: () -> Void

    var body: some View {
        content
            .onChange(of: item.wrappedValue?.id != shownID) { _, isGone in
                if isGone {
                    dismiss()
                }
            }
    }
}

private final class LandscapeHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscape
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .landscapeRight
    }
}
#endif
