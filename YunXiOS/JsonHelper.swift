import Foundation

func jsonString(_ dict: [String: Any]?, _ key: String) -> String {
    guard let value = dict?[key] as? String, value != "null" else { return "" }
    return value
}
