// Noninteractive identity check only. Never exports, creates or updates a key.
import CryptoKit
import Foundation
import Security

enum PreflightError: Error {
    case invalidExpectedKey, interactionControl(OSStatus), lookup(OSStatus), malformedKey, mismatch
}

func verifySparkleKey(expected: String, disableInteraction: () -> OSStatus,
                      readItem: () throws -> Data) throws {
    guard let expectedKey = Data(base64Encoded: expected), expectedKey.count == 32 else {
        throw PreflightError.invalidExpectedKey
    }
    let status = disableInteraction()
    guard status == errSecSuccess else { throw PreflightError.interactionControl(status) }
    // The callback's data stays in this process. No metadata is accepted as key proof.
    guard let secret = Data(base64Encoded: try readItem()) else { throw PreflightError.malformedKey }
    let publicKey: Data
    switch secret.count {
    case 32:
        publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret).publicKey.rawRepresentation
    case 96:
        // Sparkle 2.10.0's legacy format is the 64-byte orlp private key + public key.
        publicKey = secret.suffix(32)
    default:
        throw PreflightError.malformedKey
    }
    guard publicKey == expectedKey else { throw PreflightError.mismatch }
}

func sparkleItemQuery(account: String) -> [String: Any] {
    return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "https://sparkle-project.org",
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: kSecAttrProtocolSSH,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
}

#if !SPARKLE_PREFLIGHT_TESTS
@main
struct SparkleKeyPreflight {
    static func main() {
        // Only account and expected PUBLIC identity are arguments. No secret input/output mode.
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: sparkle-key-preflight ACCOUNT EXPECTED_PUBLIC_KEY\n", stderr)
            exit(64)
        }
        do {
            try verifySparkleKey(expected: CommandLine.arguments[2], disableInteraction: {
                // Required for the legacy login Keychain, in THIS process before lookup.
                SecKeychainSetUserInteractionAllowed(false)
            }, readItem: {
                var item: CFTypeRef?
                let status = SecItemCopyMatching(sparkleItemQuery(account: CommandLine.arguments[1]) as CFDictionary, &item)
                guard status == errSecSuccess else { throw PreflightError.lookup(status) }
                guard let data = item as? Data else { throw PreflightError.malformedKey }
                return data
            })
            print("Noninteractive Sparkle key identity matches.")
        } catch {
            // Never print errors from libraries or item contents.
            let message: String
            switch error {
            case PreflightError.interactionControl(let status):
                message = "Cannot disable Keychain interaction (OSStatus \(status)); no lookup attempted."
            case PreflightError.lookup(let status):
                message = "Existing Sparkle key unavailable without interaction (OSStatus \(status)). No credentials changed."
            case PreflightError.invalidExpectedKey: message = "Invalid expected Sparkle public identity."
            case PreflightError.mismatch: message = "Existing Sparkle key does not match the app public identity."
            default: message = "Invalid stored Sparkle key format."
            }
            fputs("Release preflight failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
#endif
