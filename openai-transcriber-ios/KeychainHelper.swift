import Foundation
import Security

final class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = Bundle.main.bundleIdentifier ?? "openai.transcriber"

    // 保存
    func save(apiKey: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "OPENAI_API_KEY"]
        SecItemDelete(query as CFDictionary)               // 既存削除
        var add = query
        add[kSecValueData as String] = Data(apiKey.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    // 取得
    func apiKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "OPENAI_API_KEY",
                                    kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }
}
