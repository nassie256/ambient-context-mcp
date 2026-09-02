import CryptoKit
import Foundation

public enum PolicyVersionService {
    /// 分類 (path 昇順) と override (key 昇順) を連結した文字列の SHA-256 先頭 9 バイトを
    /// base64url (パディング無し) にしたもの。C# 実装とバイト単位で一致する。
    public static func computePolicyVersion(
        classifications: [PrivacyClassification],
        overrides: CaseInsensitiveDictionary<Bool>
    ) -> String {
        var text = ""

        for item in classifications.sorted(by: { $0.path.lowercased() < $1.path.lowercased() }) {
            text += "c|" + item.path + "|"
                + SensitivityScopeFilter.normalizeSensitivity(item.sensitivity) + "|"
                + (item.defaultTransmit ? "1" : "0") + "\n"
        }

        for pair in overrides.sortedPairs {
            text += "o|" + pair.key + "|" + (pair.value ? "1" : "0") + "\n"
        }

        let digest = SHA256.hash(data: Data(text.utf8))
        let prefix = Data(Array(digest).prefix(9))
        return Base64Url.encode(prefix)
    }
}
