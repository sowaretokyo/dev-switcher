import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: swift verify-sparkle-update.swift <archive> <public-key-base64> <signature-base64>\n", stderr)
    exit(2)
}

do {
    guard let publicKeyData = Data(base64Encoded: CommandLine.arguments[2]),
          publicKeyData.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[3]),
          signature.count == 64 else {
        throw VerificationError.invalidInput
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    let archive = try Data(
        contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe
    )
    guard publicKey.isValidSignature(signature, for: archive) else {
        throw VerificationError.signatureMismatch
    }
} catch {
    fputs("Sparkle update signature verification failed: \(error)\n", stderr)
    exit(1)
}

private enum VerificationError: Error {
    case invalidInput
    case signatureMismatch
}
