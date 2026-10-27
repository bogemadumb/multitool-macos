import Foundation
@testable import MultitulCore

final class ScriptedKeychain: KeychainStore, @unchecked Sendable {
    var items: [String: JSON] = [:]
    var deleteResults: [Bool]
    var deleteCalls: [String] = []
    init(deleteResults: [Bool] = []) { self.deleteResults = deleteResults }
    func read(_ service: String) -> JSON? { items[service] }
    func write(_ service: String, _ payload: JSON) -> Bool { items[service] = payload; return true }
    func deleteOnce(_ service: String) -> Bool {
        deleteCalls.append(service)
        return deleteResults.isEmpty ? false : deleteResults.removeFirst()
    }
}

