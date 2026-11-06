import AppKit
import Foundation
import Testing
@testable import systat

@MainActor @Test func iconsetHasEveryMacOSSizeWithATransparentMargin() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("systat-iconset-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try AppIcon.writeIconset(to: dir)

    let expected = [
        "icon_16x16.png": 16, "icon_16x16@2x.png": 32, "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128, "icon_128x128@2x.png": 256, "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512, "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
    ]
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == expected.keys.sorted())
    for (name, pixels) in expected {
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: dir.appendingPathComponent(name))))
        #expect(rep.pixelsWide == pixels && rep.pixelsHigh == pixels, "\(name)")
    }

    // The tile sits on the macOS grid: clear outside it, opaque inside it.
    let big = try #require(NSBitmapImageRep(data: Data(contentsOf: dir.appendingPathComponent("icon_512x512@2x.png"))))
    #expect(big.colorAt(x: 40, y: 512)?.alphaComponent == 0)
    #expect(big.colorAt(x: 150, y: 512)?.alphaComponent == 1)
}
