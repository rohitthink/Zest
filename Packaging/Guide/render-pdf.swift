import AppKit
import WebKit

// Render Packaging/Guide/guide.html to a paginated A4 PDF with WebKit.
// Usage: swift render-pdf.swift <guide.html> <out.pdf>

let args = CommandLine.arguments
let html = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))   // A4 at 96 dpi
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 794, height: 1123),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    var finished = false

    func start() {
        window.contentView = web
        web.navigationDelegate = self
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give images a beat to decode, then print.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.printPDF() }
    }

    func printPDF() {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595.28, height: 841.89)   // A4 in points
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0   // CSS @page sets margins
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        let op = web.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = web.bounds
        op.runModal(for: window, delegate: self, didRun: #selector(printed(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc func printed(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        print(success ? "wrote \(out.path)" : "print failed")
        finished = true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer()
renderer.start()
let deadline = Date().addingTimeInterval(60)
while !renderer.finished && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
if !renderer.finished { print("timed out"); exit(1) }
