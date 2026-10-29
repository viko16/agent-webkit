import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
guard let bitmap = NSBitmapImageRep(data: data) else { fatalError("Invalid image") }
let samples = arguments.dropFirst().map { point -> [Int] in
    let pair = point.split(separator: ",").map { Double($0)! }
    let x = min(bitmap.pixelsWide - 1, Int(pair[0] * Double(bitmap.pixelsWide)))
    let y = min(bitmap.pixelsHigh - 1, Int(pair[1] * Double(bitmap.pixelsHigh)))
    // Inspect the encoded channels; colorAt labels PNG RGB as calibrated RGB,
    // and converting that label again changes otherwise correct sRGB bytes.
    guard let color = bitmap.colorAt(x: x, y: y) else { fatalError("Missing pixel") }
    return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
}
let result: [String: Any] = ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "samples": samples]
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
