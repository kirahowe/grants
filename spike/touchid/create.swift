// Run as the "issuer". Creates enclave keys that need a fingerprint. Never prompts:
// creating a key with an access control does not evaluate it.
import CryptoKit
import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
func w(_ d: Data, _ n: String) throws { try d.write(to: dir.appendingPathComponent(n)) }
func seal(_ pub: P256.KeyAgreement.PublicKey, _ tag: String) throws {
  let eph = P256.KeyAgreement.PrivateKey()
  let k = try eph.sharedSecretFromKeyAgreement(with: pub).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("grants-test".utf8), outputByteCount: 32)
  try w(eph.publicKey.x963Representation, "\(tag).eph"); try w(try AES.GCM.seal(Data("DUMMY-LIVE-KEY-\(tag)".utf8), using: k).combined!, "\(tag).sealed")
}
do {
  for (tag, flags) in [("bio", SecAccessControlCreateFlags([.privateKeyUsage, .biometryCurrentSet])),
                       ("presence", SecAccessControlCreateFlags([.privateKeyUsage, .userPresence]))] {
    var err: Unmanaged<CFError>?
    guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &err) else { print("ac error", err!.takeRetainedValue()); exit(1) }
    let sk = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ac)
    let ka = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
    try w(sk.dataRepresentation, "\(tag)-sign.blob"); try w(sk.publicKey.x963Representation, "\(tag)-sign.pub")
    try w(ka.dataRepresentation, "\(tag)-ka.blob"); try seal(ka.publicKey, tag)
    print("created \(tag) keys: OK")
  }
} catch { print("create ERROR:", error); exit(1) }
