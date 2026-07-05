# Code signing

The build script creates a local `.app` bundle and signs it ad-hoc by default.
It never searches for named certificates in your Keychain. Set an identity explicitly
when you want a consistent signing identity across builds:

```sh
OATMEAL_SIGNING_IDENTITY="Your code signing identity" bash Scripts/build-app.sh release
```

Use an identity you have installed and are authorized to use. The value is passed
directly to `codesign`; it is not stored in the repository. If signing fails, the
script fails instead of silently substituting another identity.

macOS permission decisions depend on application identity and other system state.
Ad-hoc rebuilding, switching identities, or moving installations can require fresh
permissions. Consistent signing can reduce repeated prompts but does not guarantee
that grants survive every OS update or rebuild. Reopen the app after granting
Screen & System Audio Recording access.

Local signing is not a distribution pipeline. The script does not enable a complete
Developer ID release workflow, notarize, staple, create a DMG, or build a universal
binary. Public binary distribution needs a separately validated packaging/signing
process. Do not commit certificates, private keys, provisioning profiles, or
notarization credentials.
