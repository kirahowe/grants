package main

/*
#cgo LDFLAGS: -L/usr/lib/swift -Wl,-rpath,/usr/lib/swift -framework CryptoKit -framework Security -framework Foundation
#include <stdint.h>
#include <stddef.h>
int32_t sek_create(uint8_t *blob, long cap, long *len, uint8_t *pub);
int32_t sek_sign(const uint8_t *blob, long len, const uint8_t *msg, long mlen, uint8_t *sig);
*/
import "C"

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"fmt"
	"math/big"
	"unsafe"
)

func main() {
	blob := make([]byte, 1024)
	pub := make([]byte, 65)
	var n C.long
	if rc := C.sek_create((*C.uint8_t)(&blob[0]), 1024, &n, (*C.uint8_t)(&pub[0])); rc != 0 {
		panic(rc)
	}
	blob = blob[:n]
	msg := []byte("header.payload")
	sig := make([]byte, 64)
	if rc := C.sek_sign((*C.uint8_t)(&blob[0]), C.long(len(blob)), (*C.uint8_t)(unsafe.Pointer(&msg[0])), C.long(len(msg)), (*C.uint8_t)(&sig[0])); rc != 0 {
		panic(rc)
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), pub) //nolint:staticcheck
	d := sha256.Sum256(msg)
	fmt.Printf("TESTED Go binary with linked Swift/CryptoKit static lib: blob %d bytes, raw sig verifies: %v\n", len(blob),
		ecdsa.Verify(&ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, d[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])))
}
