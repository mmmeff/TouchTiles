import CryptoKit
import Foundation

// Verify against the public key actually shipped in the app. Verifying with
// the signing tool's private key alone wouldn't detect a mismatched app key.
let arguments = CommandLine.arguments
guard arguments.count == 4,
      let publicKey = Data(base64Encoded: arguments[2]),
      let signature = Data(base64Encoded: arguments[3]) else {
    FileHandle.standardError.write(Data("Expected an update ZIP, base64 public key and base64 signature\n".utf8))
    exit(2)
}
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
guard key.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("Update signature does not match SUPublicEDKey in the release app\n".utf8))
    exit(1)
}
