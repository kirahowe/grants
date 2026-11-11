# A Go binary that uses the Secure Enclave through CryptoKit

The daemon is a Go core with a small Swift library for the enclave, linked
into one binary. This is the proof that the two link and work together.

`sek.swift` exports two C functions around CryptoKit: one creates an enclave
signing key and returns its stored form and public key, and the other signs
with a stored key. `main.go` calls both through cgo and verifies the
signature with Go's own `crypto/ecdsa`.

The review built and ran it once, on 2026-11-11, with an ad-hoc signature and
no entitlements. It printed that the raw signature verified. It hasn't been
run since, and the build line below is reconstructed from the review's notes,
so check it before relying on it.

```bash
swiftc -O -parse-as-library -emit-library -static -module-name sek sek.swift -o libsek.a
CGO_LDFLAGS="$PWD/libsek.a" go build -o goswift .
./goswift
```

What the review learned from it:

- The Swift library's path has to go in through the `CGO_LDFLAGS` variable.
  Go refuses it on a `#cgo LDFLAGS` line in the source, so the real build
  needs a script and can't be a bare `go build`.
- CryptoKit's signature is already in the raw form a JWT needs, with no
  conversion.
- The key is created "after first unlock", which is what lets a background
  service sign while the screen is locked.
- Running it creates an enclave key and keeps nothing: the stored form stays
  in memory and is gone when the program exits. It doesn't touch the
  keychain and shows no prompt.

The real key code also needs to restore a key from its stored form in a later
process, to do key agreement for sealing, and to create a key that needs a
fingerprint. The review did each of those in Swift on its own, and not yet
through this bridge.
