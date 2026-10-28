import CoreGraphics
import Foundation

// `koid-control [NAME]` prints the window id of the named app's main window.
// `koid-control shot PATH` asks the running Koid to write a PNG of its
// window to PATH (see Dev.writeScreenshot). `popup NAME` opens a Koi floating
// control in Koid without sending input to the screen. `palette [QUERY]`
// opens the palette; `palette run ID [VALUE]` exercises one of its entries.
// `palette inspect PATH [QUERY]` writes selected IDs and matching entry IDs.
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "shot", args.count == 2 {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.fschrhunt.koid.shot"), object: args[1], userInfo: nil, deliverImmediately: true)
    exit(0)
}
if args.first == "popup", args.count == 2 {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.fschrhunt.koid.popup"), object: args[1], userInfo: nil, deliverImmediately: true)
    exit(0)
}
if args.first == "palette" {
    let request: [String: String]
    if args.count >= 3, args[1] == "inspect" {
        request = ["inspect": args[2], "query": args.count > 3 ? args[3] : ""]
    } else if args.count >= 3, args[1] == "run" {
        var run = ["id": args[2]]
        if args.count > 3 { run["value"] = args[3] }
        request = run
    } else {
        request = ["query": args.dropFirst().joined(separator: " ")]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: request),
          let json = String(data: data, encoding: .utf8) else { exit(1) }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.fschrhunt.koid.palette"), object: json, userInfo: nil, deliverImmediately: true)
    exit(0)
}
let name = args.first ?? "Koid"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter { ($0[kCGWindowOwnerName as String] as? String) == name && ($0[kCGWindowLayer as String] as? Int) == 0 }
guard let best = windows.max(by: { a, b in
    let ab = a[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let bb = b[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return (ab["Width"] ?? 0) * (ab["Height"] ?? 0) < (bb["Width"] ?? 0) * (bb["Height"] ?? 0)
}), let id = best[kCGWindowNumber as String] as? Int else { exit(1) }
print(id)
