import AppKit
import CoreImage
import Vision

let payload = "VikingBar website demo. Not a payment code."
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(Data(payload.utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
let qr = filter.outputImage!
let quietZone: CGFloat = 4
let size = qr.extent.width + quietZone * 2
let background = CIImage(color: CIColor.white).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
let padded = qr.transformed(by: CGAffineTransform(translationX: quietZone, y: quietZone)).composited(over: background)
let scaled = padded.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
let image = CIContext().createCGImage(scaled, from: scaled.extent)!
let request = VNDetectBarcodesRequest()
try VNImageRequestHandler(cgImage: image).perform([request])
precondition(request.results?.first?.payloadStringValue == payload, "Demo QR payload failed independent decoding")
let bitmap = NSBitmapImageRep(cgImage: image)
let script = URL(fileURLWithPath: #filePath)
let output = script.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("public/assets/demo-transfer-qr.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Generated and independently decoded inert demo QR")
