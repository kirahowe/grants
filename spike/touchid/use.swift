// A DIFFERENT binary. Loads the blobs made by create, then signs and unseals.
// Every enclave operation below can show a Touch ID prompt.
import CryptoKit
import Foundation
import LocalAuthentication
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let tag = CommandLine.arguments[2]               // bio | presence
let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "each"  // each | once | noui
func r(_ n: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(n)) }
let ctx = LAContext()
ctx.localizedReason = "TEST ONLY (grants experiment, \(tag), \(mode)): approve to check whether another binary can use the key"
if mode == "noui" { ctx.interactionNotAllowed = true }
if mode == "once" {
  // evaluate once, then reuse the context for several operations
  var e: Unmanaged<CFError>?
  let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
     tag == "bio" ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage, .userPresence], &e)!
  let sem = DispatchSemaphore(value: 0); var ok = false
  ctx.evaluateAccessControl(ac, operation: .useKeySign, localizedReason: ctx.localizedReason) { s, err in ok = s; if let err { print("evaluate error:", err) }; sem.signal() }
  sem.wait(); print("pre-evaluated context:", ok)
}
func ctxFor() -> LAContext { mode == "each" ? { let c = LAContext(); c.localizedReason = ctx.localizedReason; return c }() : ctx }
do {
  let sk = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: r("\(tag)-sign.blob"), authenticationContext: ctxFor())
  print("loaded signing blob (no prompt expected yet)")
  let sig = try sk.signature(for: Data("hello".utf8))
  print("SIGN as other binary:", try P256.Signing.PublicKey(x963Representation: r("\(tag)-sign.pub")).isValidSignature(sig, for: Data("hello".utf8)) ? "OK, valid" : "invalid")
} catch { print("SIGN ERROR:", error) }
do {
  let ka = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: r("\(tag)-ka.blob"), authenticationContext: ctxFor())
  let k = try ka.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: r("\(tag).eph"))).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("grants-test".utf8), outputByteCount: 32)
  print("UNSEAL as other binary:", String(decoding: try AES.GCM.open(AES.GCM.SealedBox(combined: r("\(tag).sealed")), using: k), as: UTF8.self))
  // second key-agreement with the same key object: does it prompt again?
  _ = try ka.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: r("\(tag).eph")))
  print("second unseal on same key object: OK")
} catch { print("UNSEAL ERROR:", error) }
