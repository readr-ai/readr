#if os(iOS)
import SwiftUI
import UIKit

/// Keeps the NavigationStack's interactive pop gesture out of the reader.
/// While the reader is on screen a left-to-right swipe must turn BACK a page
/// (`SwipeToTurn`), not pop to the library — with the recognizer live it wins
/// that race. Disabled on the way in, re-enabled on the way out, so the
/// library keeps its normal back-swipe behavior everywhere else; the reader's
/// explicit back chevron (`reader.back`) is the way out. Rides in the
/// reader's `.background(...)`, where the hosting controller lands inside
/// the same navigation controller as the reader's own page.
struct PopGestureDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        /// `didMove(toParent:)` covers the attach path — `viewWillAppear`
        /// can run before the controller is parented, when
        /// `navigationController` still resolves to nil.
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent != nil {
                navigationController?.interactivePopGestureRecognizer?.isEnabled = false
            }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}
#endif
