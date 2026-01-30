import Foundation

// Singleton para garantir persistência em memória e disco
class CallCorrelationStore {
    // Cache em memória (RAM) - Acesso instantâneo
    static var memoryUUID: String?

    // Nome do App Group (Verifique se é EXATAMENTE este no seu projeto > Signing & Capabilities)
    private static let appGroup = "group.com.brdsoft.brdphone"

    static func save(_ uuid: String) {
        // 1. Salva na RAM
        memoryUUID = uuid

        // 2. Salva no Disco (App Group)
        if let defaults = UserDefaults(suiteName: appGroup) {
            defaults.set(uuid, forKey: "last_push_uuid")
            defaults.synchronize()
            print("[STORE] UUID salvo no AppGroup: \(uuid)")
        } else {
            print("[STORE] ERRO: Não foi possível acessar o App Group: \(appGroup)")
        }
    }

    static func get() -> String? {
        // 1. Tenta RAM
        if let uuid = memoryUUID {
            print("[STORE] UUID recuperado da RAM: \(uuid)")
            return uuid
        }

        // 2. Tenta Disco
        if let defaults = UserDefaults(suiteName: appGroup),
            let uuid = defaults.string(forKey: "last_push_uuid")
        {
            // Re-hidrata a RAM
            memoryUUID = uuid
            print("[STORE] UUID recuperado do Disco: \(uuid)")
            return uuid
        }

        print("[STORE] Nenhum UUID encontrado.")
        return nil
    }

    static func clear() {
        memoryUUID = nil
        if let defaults = UserDefaults(suiteName: appGroup) {
            defaults.removeObject(forKey: "last_push_uuid")
        }
    }
}
