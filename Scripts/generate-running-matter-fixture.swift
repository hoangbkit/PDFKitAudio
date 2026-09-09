// Run from the repository root: swift Scripts/generate-running-matter-fixture.swift
import AppKit
import CoreGraphics
import Foundation

let output = URL(fileURLWithPath: "Tests/PDFKitAudioTests/TestFixtures/PDFLayout/09-repeated-header-footer.pdf")
let data = NSMutableData()
var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    fatalError("Cannot create fixture PDF")
}
func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false) {
    let font = NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)!
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: NSColor.black])
}
for number in 1...4 {
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw("REPEATED JOURNAL HEADER", x: 45, y: 750, size: 12, bold: true)
    draw("Page \(number)", x: 520, y: 727, size: 10)
    for row in 1...12 {
        draw("Unique page \(number) body \(row).", x: 45, y: 690 - CGFloat(row - 1) * 24, size: 11)
    }
    draw("Repeated footer - Journal 2026 • \(number)", x: 45, y: 25, size: 9)
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
}
context.closePDF()
try (data as Data).write(to: output, options: .atomic)
print("Generated four-page running-matter fixture at \(output.path)")
