import CryptoKit
import Foundation

// These C entry points are declared in PlatformCryptoKit.h. Each Moonlight
// crypto context owns one retained key, reused for all of its GCM packets.
private final class GCMKey {
    let value: SymmetricKey

    init(_ bytes: UnsafeRawBufferPointer) {
        value = SymmetricKey(data: bytes)
    }
}

@_cdecl("SLGCMCreateKey")
public func SLGCMCreateKey(_ bytes: UnsafePointer<UInt8>, _ length: Int32) -> UnsafeMutableRawPointer? {
    guard length == 16 else { return nil }
    let key = GCMKey(UnsafeRawBufferPointer(start: bytes, count: Int(length)))
    return Unmanaged.passRetained(key).toOpaque()
}

@_cdecl("SLGCMDestroyKey")
public func SLGCMDestroyKey(_ context: UnsafeMutableRawPointer) {
    Unmanaged<GCMKey>.fromOpaque(context).release()
}

@_cdecl("SLGCMCrypt")
public func SLGCMCrypt(
    _ context: UnsafeMutableRawPointer,
    _ encrypt: Bool,
    _ iv: UnsafePointer<UInt8>,
    _ ivLength: Int32,
    _ tag: UnsafeMutablePointer<UInt8>,
    _ tagLength: Int32,
    _ input: UnsafePointer<UInt8>?,
    _ inputLength: Int32,
    _ output: UnsafeMutablePointer<UInt8>?
) -> Bool {
    // Moonlight uses 128-bit keys/tags, 96- or 128-bit nonces, and no AAD.
    guard (ivLength == 12 || ivLength == 16), tagLength == 16, inputLength >= 0,
          inputLength == 0 || (input != nil && output != nil) else {
        return false
    }
    let key = Unmanaged<GCMKey>.fromOpaque(context).takeUnretainedValue().value
    let count = Int(inputLength)

    do {
        let nonce = try AES.GCM.Nonce(data: Data(bytes: iv, count: Int(ivLength)))
        // Borrow the packet for this synchronous call. Copy the result only
        // after CryptoKit finishes, so input and output may share storage.
        let message = input.map {
            Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0), count: count, deallocator: .none)
        } ?? Data()
        let result: Data
        if encrypt {
            let box = try AES.GCM.seal(message, using: key, nonce: nonce)
            result = box.ciphertext
            box.tag.copyBytes(to: tag, count: 16)
        } else {
            // Use separate nonce/tag fields: `combined` only supports 12-byte
            // nonces, while legacy GameStream also uses 16-byte nonces.
            let box = try AES.GCM.SealedBox(
                nonce: nonce, ciphertext: message, tag: Data(bytes: tag, count: 16)
            )
            result = try AES.GCM.open(box, using: key)
        }
        if let output, count > 0 {
            result.copyBytes(to: output, count: count)
        }
        return true
    } catch {
        if !encrypt, let output, count > 0 {
            output.update(repeating: 0, count: count)
        }
        return false
    }
}
