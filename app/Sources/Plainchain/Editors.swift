import AppKit
import AVFoundation
import CoreAudioKit

/// A plugin's editor window. Uses the plugin's own view when it has one,
/// otherwise a generic parameter view.
final class EditorWindow: NSWindow {
    var onClose: (() -> Void)?

    static func open(for unit: AVAudioUnit, title: String, completion: @escaping (EditorWindow) -> Void) {
        unit.auAudioUnit.requestViewController { controller in
            DispatchQueue.main.async {
                let vc: NSViewController
                if let controller {
                    vc = controller
                } else {
                    let generic = NSViewController()
                    let view = AUGenericView(audioUnit: unit.audioUnit)
                    view.showsExpertParameters = true
                    view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
                    generic.view = view
                    vc = generic
                }
                let window = EditorWindow(contentViewController: vc)
                window.title = title
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                completion(window)
            }
        }
    }

    override func close() {
        onClose?()
        onClose = nil
        super.close()
    }
}
