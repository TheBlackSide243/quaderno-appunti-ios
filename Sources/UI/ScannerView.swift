import SwiftUI
import VisionKit

/// The system document scanner: the camera finds the sheet, straightens it and gives one picture
/// per page. `onFinish` gets the pages, or nil when the scan was cancelled or failed.
struct ScannerView: UIViewControllerRepresentable {
    let onFinish: ([UIImage]?) -> Void

    /// False where there is no camera (and in the simulator).
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]?) -> Void

        init(onFinish: @escaping ([UIImage]?) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var pages: [UIImage] = []
            for i in 0..<scan.pageCount { pages.append(scan.imageOfPage(at: i)) }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish(nil)
        }
    }
}
