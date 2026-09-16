import Foundation
import Vision

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: decode-payment-qr IMAGE EXPECTED\n".utf8))
    exit(2)
}
let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
let expectedURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let expected = try? String(contentsOf: expectedURL, encoding: .utf8) else { exit(2) }
let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
do {
    try VNImageRequestHandler(url: imageURL).perform([request])
    let payloads = request.results?.compactMap(\.payloadStringValue) ?? []
    guard payloads.contains(expected) else {
        FileHandle.standardError.write(Data("expected QR payload not found\n".utf8))
        exit(1)
    }
    let result = try JSONSerialization.data(withJSONObject: ["decoded": true, "payloadMatches": true])
    FileHandle.standardOutput.write(result + Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("QR decode failed\n".utf8))
    exit(1)
}
