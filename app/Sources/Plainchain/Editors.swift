import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit

/// A plugin's editor window, created on the main thread. Tries, in order: the
/// plugin's own v2 Cocoa view, a v3 plugin's view controller, then a generic parameter view.
final class EditorWindow: NSWindow {
    var onClose: (() -> Void)?
    /// The plugin stays loaded while its view is up.
    private var plugin: PluginInstance?

    static func open(for unit: PluginInstance, title: String, completion: @escaping (EditorWindow) -> Void) {
        precondition(Thread.isMainThread)
        func present(_ vc: NSViewController) {
            let window = EditorWindow(contentViewController: vc)
            window.plugin = unit
            window.title = title
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            completion(window)
        }
        if let view = cocoaView(for: unit.audioUnit) {
            let vc = NSViewController()
            vc.view = view
            present(vc)
            return
        }
        func presentGeneric() {
            let generic = NSViewController()
            let view = AUGenericView(audioUnit: unit.audioUnit)
            view.showsExpertParameters = true
            view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
            generic.view = view
            present(generic)
        }
        guard let av = unit.avUnit else { presentGeneric(); return }
        av.auAudioUnit.requestViewController { controller in
            DispatchQueue.main.async {
                if let controller { present(controller) } else { presentGeneric() }
            }
        }
    }

    /// The plugin's own view via `kAudioUnitProperty_CocoaUI`: load the view
    /// bundle, make the factory, ask it for a view bound to this instance.
    private static func cocoaView(for unit: AudioUnit) -> NSView? {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { raw.deallocate() }
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }
        let info = raw.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee
        let url = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.mCocoaAUViewClass.takeRetainedValue() as String
        guard let bundle = Bundle(url: url), bundle.load(),
              let cls = (bundle.classNamed(className) ?? NSClassFromString(className)) as? NSObject.Type
        else { return nil }
        let factory = cls.init()
        // AUCocoaUIBase is not exported to Swift; message the factory directly.
        let versionSel = NSSelectorFromString("interfaceVersion")
        let viewSel = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard factory.responds(to: versionSel), factory.responds(to: viewSel),
              let msgSend = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend") else { return nil }
        typealias VersionFn = @convention(c) (AnyObject, Selector) -> UInt32
        typealias ViewFn = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> NSView?
        guard unsafeBitCast(msgSend, to: VersionFn.self)(factory, versionSel) == 0 else { return nil }
        return unsafeBitCast(msgSend, to: ViewFn.self)(factory, viewSel, unit, NSSize(width: 0, height: 0))
    }

    override func close() {
        onClose?()
        onClose = nil
        super.close()
        contentViewController = nil
        plugin = nil
    }
}
