import Foundation
import CryptoKit

// Verify against the public key embedded in the shipped app, so an accidental
// mismatch between the repository key and CI secret cannot publish unusable updates.
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let publicKey = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fatalError("Invalid public key or signature")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
guard key.isValidSignature(signature, for: archive) else {
    fatalError("The update signature does not match the public key in the app")
}
