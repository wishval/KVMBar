import AppKit
import SwiftUI

/// Build date = the executable's modification timestamp (Swift has no
/// compile-time date facility; this survives `swift build` and `make` alike).
var appBuildDateString: String {
    guard let url = Bundle.main.executableURL,
          let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let date = attributes[.modificationDate] as? Date else { return "?" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .padding(.top, 4)

            Text("KVMBar")
                .font(.title2.weight(.semibold))

            Text("Version \(kAppVersion) · built \(appBuildDateString)")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Tames a KVM monitor shared between two Macs: hands the display and peripherals to the other computer in one click — or fully automatically — cleaning up macOS phantom-display quirks on the way.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Divider()
                .padding(.vertical, 6)
                .padding(.horizontal, 40)

            VStack(spacing: 5) {
                Text("Made by \(kAuthorName)")
                    .font(.callout.weight(.medium))
                if let mail = URL(string: "mailto:\(kAuthorEmail)?subject=KVMBar") {
                    Link(kAuthorEmail, destination: mail)
                }
                if let linkedIn = URL(string: kAuthorLinkedInURLString) {
                    Link("linkedin.com/in/valerii-bakalenko", destination: linkedIn)
                }
                if let urlString = kProjectURLString, let project = URL(string: urlString) {
                    Link("Source on GitHub", destination: project)
                }
            }
            .font(.callout)

            Text("© 2026 \(kAuthorName) · MIT License")
                .font(.caption2)
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .padding(.top, 10)
        }
        .padding(24)
        .frame(width: 360)
    }
}

final class AboutWindowController: NSObject {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView())
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "About KVMBar"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            window = newWindow
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
