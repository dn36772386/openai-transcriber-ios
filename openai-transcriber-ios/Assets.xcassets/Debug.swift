import Foundation

struct Debug {
    /// Info.plist の DEBUG_LOG が true なら有効
    static let enabled: Bool = {
        if let boolVal = Bundle.main.object(forInfoDictionaryKey: "DEBUG_LOG") as? Bool {
            return boolVal
        }
        if let str = Bundle.main.object(forInfoDictionaryKey: "DEBUG_LOG") as? String {
            return ["1", "true", "yes"].contains(str.lowercased())
        }
        return false
    }()

    /// 有効時のみ標準出力
    static func log(_ items: Any...) {
        guard enabled else { return }
        let msg = items.map { String(describing: $0) }.joined(separator: " ")
        print("🛠", msg)
    }
}

// このファイルは不要になったため削除してOK
