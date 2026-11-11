import CryptoKit
import Foundation
import Security

// C ABI exported to Go. Returns 0 on success; buffers are caller-provided.
@_cdecl("sek_create")
public func sek_create(_ blob: UnsafeMutablePointer<UInt8>, _ blobCap: Int, _ blobLen: UnsafeMutablePointer<Int>,
                       _ pub: UnsafeMutablePointer<UInt8>) -> Int32 {
    var err: Unmanaged<CFError>?
    guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [.privateKeyUsage], &err),
          let k = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: ac) else { return -1 }
    let d = k.dataRepresentation
    guard d.count <= blobCap else { return -2 }
    d.copyBytes(to: blob, count: d.count); blobLen.pointee = d.count
    k.publicKey.x963Representation.copyBytes(to: pub, count: 65)
    return 0
}

@_cdecl("sek_sign")
public func sek_sign(_ blob: UnsafePointer<UInt8>, _ blobLen: Int, _ msg: UnsafePointer<UInt8>, _ msgLen: Int,
                     _ sig: UnsafeMutablePointer<UInt8>) -> Int32 {
    guard let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(bytes: blob, count: blobLen)),
          let s = try? k.signature(for: Data(bytes: msg, count: msgLen)) else { return -1 }
    s.rawRepresentation.copyBytes(to: sig, count: 64) // already JWS r||s
    return 0
}
