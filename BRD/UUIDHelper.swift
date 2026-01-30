import CryptoKit
import Foundation

class UUIDHelper {
    /// Transforma qualquer string em um UUID determinístico e válido.
    static func createDeterministicUUID(from string: String) -> UUID {
        // Se já for um UUID válido, retorna ele mesmo
        if let validUUID = UUID(uuidString: string) {
            return validUUID
        }
        // Gera hash MD5 da string
        guard let data = string.data(using: .utf8) else { return UUID() }
        let hash = Insecure.MD5.hash(data: data)
        var uuidBytes:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8
            ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuidBytes) { buffer in
            _ = hash.withUnsafeBytes { hashBuffer in
                buffer.copyMemory(
                    from: UnsafeRawBufferPointer(
                        start: hashBuffer.baseAddress, count: min(buffer.count, hashBuffer.count)))
            }
        }
        return UUID(uuid: uuidBytes)
    }
}
