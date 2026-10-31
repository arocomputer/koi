#if KOID
import AppKit

/// Koid-only preview support. The normal Koi app contains no screenshot
/// receiver or call to the legacy window-capture API.
@MainActor enum Dev {
    private static weak var previewWindow: NSWindow?
    /// Shows the development window without activating it, optionally at a
    /// fixed size, and listens for screenshot and synthetic-prediction
    /// requests from `koid`.
    static func configure(_ window: NSWindow, palette: @escaping @MainActor ([String: String]) -> Void,
                          predict: @escaping @MainActor (String?) -> Void) {
        previewWindow = window
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated { previewWindow = window }
        }
        if let size = ProcessInfo.processInfo.environment["KOID_SIZE"] {
            let parts = size.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2, parts.allSatisfy({ $0 > 0 }) {
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
            }
        }
        window.orderFront(nil)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.fschrhunt.koid.palette"), object: nil, queue: .main
        ) { [weak window] notification in
            guard let json = notification.object as? String, let data = json.data(using: .utf8),
                  let request = try? JSONDecoder().decode([String: String].self, from: data) else { return }
            MainActor.assumeIsolated {
                guard let window, previewWindow === window else { return }
                palette(request)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.fschrhunt.koid.predict"), object: nil, queue: .main
        ) { [weak window] notification in
            guard let text = notification.object as? String else { return }
            MainActor.assumeIsolated {
                guard let window, previewWindow === window else { return }
                predict(text.isEmpty ? nil : text)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.fschrhunt.koid.shot"), object: nil, queue: .main
        ) { [weak window] notification in
            guard let path = notification.object as? String else { return }
            MainActor.assumeIsolated {
                if let window, previewWindow === window { writeScreenshot(of: window, to: path) }
            }
        }
    }

    /// Writes a PNG of Koid's own window without Screen Recording permission.
    /// Kept in the development build because the current SDK no longer
    /// declares CGWindowListCreateImage.
    private static func writeScreenshot(of window: NSWindow, to path: String) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let includingWindow: UInt32 = 1 << 3, ignoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        guard let image = capture(.null, includingWindow, UInt32(window.windowNumber), ignoreFraming | bestResolution)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
