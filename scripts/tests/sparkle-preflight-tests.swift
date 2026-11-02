import CryptoKit
import Foundation
import Security

@main
struct SyntheticTests {
    static func main() throws {
        // RFC 8032 test vector 1; public test data only.
        let seed = Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let expected = Data(hex: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a").base64EncodedString()
        var reads = 0
        func check(_ data: Data, expectedKey: String = expected, status: OSStatus = errSecSuccess) throws {
            try verifySparkleKey(expected: expectedKey, disableInteraction: { status }, readItem: {
                reads += 1
                return data
            })
        }
        func reject(_ body: () throws -> Void) {
            do { try body(); fatalError("Expected rejection") } catch {}
        }
        try check(seed.base64EncodedData())
        let legacy = Data(repeating: 17, count: 64) + Data(base64Encoded: expected)!
        try check(legacy.base64EncodedData())
        reject { try check(Data("bad base64!".utf8)) }
        for count in [0, 31, 33, 64, 95, 97] {
            reject { try check(Data(repeating: 0, count: count).base64EncodedData()) }
        }
        reject { try check(seed.base64EncodedData(), expectedKey: Data(repeating: 0, count: 32).base64EncodedString()) }
        let before = reads
        reject { try check(seed.base64EncodedData(), status: errSecAuthFailed) }
        assert(reads == before, "Interaction-disable failure must prevent lookup")
        reject { try check(seed.base64EncodedData(), expectedKey: "invalid") }
        assert(reads == before, "Invalid public identity must prevent lookup")
        var deniedReads = 0
        reject {
            try verifySparkleKey(expected: expected, disableInteraction: { errSecSuccess }, readItem: {
                deniedReads += 1
                throw PreflightError.lookup(errSecInteractionNotAllowed)
            })
        }
        assert(deniedReads == 1, "Denied lookup must not retry")
        let query = sparkleItemQuery(account: "synthetic-account")
        assert(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        assert(query[kSecAttrService as String] as? String == "https://sparkle-project.org")
        assert(query[kSecAttrAccount as String] as? String == "synthetic-account")
        assert(query[kSecAttrProtocol as String] as? String == kSecAttrProtocolSSH as String)
        assert(query[kSecReturnData as String] as? Bool == true)
        assert(query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
        assert(query[kSecReturnAttributes as String] == nil)
        print("Synthetic Sparkle preflight checks passed; no Keychain API invoked.")
    }
}
extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
