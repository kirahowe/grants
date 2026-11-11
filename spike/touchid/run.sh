#!/bin/zsh
# Touch ID two-binary test for grants. Run by the owner, at the keyboard.
# Uses only dummy values. Each step shows the system Touch ID sheet; read its text before touching.
set -u
D=${0:A:h}; cd $D
swiftc -O create.swift -o grants-issuer-test && codesign -f -s - -i dev.test.grants-issuer-test grants-issuer-test
swiftc -O use.swift -o not-the-issuer && codesign -f -s - -i com.example.not-the-issuer not-the-issuer
rm -rf blobs; mkdir blobs; ./grants-issuer-test blobs          # no prompt
print "\n== Step 1: other binary, biometric key, a fresh context per operation (expect up to 3 prompts)"
print "   Note the app name and text on the sheet. Touch the sensor each time."
./not-the-issuer blobs bio each
print "\n== Step 2: same, but press Cancel on the first sheet"
./not-the-issuer blobs bio each
print "\n== Step 3: other binary, one pre-evaluated context reused (count the prompts)"
./not-the-issuer blobs bio once
print "\n== Step 4: userPresence key (Touch ID or password), fresh context per operation"
./not-the-issuer blobs presence each
rm -rf blobs; print "\nblobs deleted"
