# Stable signing identity (Szept Dev)

Ad-hoc signed builds get a fresh code identity on every rebuild, so macOS
TCC treats each one as a new app and re-prompts for microphone access.
Signing every build with the same self-signed certificate makes the
identity stable: one permission grant persists across rebuilds and
release installs. The certificate needs no CA and no Apple Developer
Program; nothing has to trust it, it only has to be the same one.

## Test Mac setup (one time)

1. `scripts/package.sh` looks for the keychain at
   `~/Library/Keychains/szept-dev.keychain-db` (in the user keychain
   search list) holding a codesigning identity named "Szept Dev".
2. Import the p12 into that keychain, unlock it non-interactively
   (`security set-keychain-settings -lu`), add the keychain to the
   user search list, and run
   `security set-key-partition-list -S apple-tool:,apple:,codesign: -k <keychain-password> <keychain>`
   so codesign can use the key over SSH without a GUI prompt.
3. Trust the self-signed root once:
   `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain szept-dev.crt`
   (codesign refuses untrusted identities).

Falls back to ad-hoc signing when the keychain is absent.

## CI (GitHub Actions)

`release.yml` reconstructs the keychain on the ephemeral runner from two
repository secrets, signs, and deletes it in a cleanup step:

- `SZP_CERT_P12_B64` - base64 of the p12 (cert + key)
- `SZP_CERT_PASSWORD` - the p12/keychain password

Runners have passwordless sudo, so the trust step is automatic there.
