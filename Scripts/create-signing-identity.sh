#!/bin/bash
#
# Create the local code-signing identity that Scripts/build.sh prefers.
# Adapted from ~/OpenCode/citlla-e510/Scripts/create-signing-identity.sh
# (see ~/OpenCode/signing.md for the full runbook).
#
# Why: an ad hoc signature pins the binary's cdhash, so every rebuild looks
# like a different app to TCC and the Full Disk Access grant is lost. A real
# (even self-signed) certificate gives the app a designated requirement of
#
#     identifier "com.ericng.wareaderformuse" and certificate root = H"…"
#
# which does not change when the app is rebuilt, so the grant survives.
#
#   Scripts/create-signing-identity.sh            create it (no-op if present)
#   Scripts/create-signing-identity.sh --force    delete and recreate it
#
# Files it creates, all outside the repository:
#
#   ~/Library/Keychains/wareader-signing.keychain-db
#   ~/Library/Application Support/WAReaderForMuse/signing/keychain-password
#   ~/Library/Application Support/WAReaderForMuse/signing/certificate.pem
#
# The keychain password is random and stored in that support file (mode 600).
# The private key never leaves the keychain; temporary PEM files are removed.
#
set -euo pipefail

# /usr/bin/openssl on macOS is LibreSSL, which lacks `pkcs12 -legacy`;
# prefer Homebrew's OpenSSL 3 when present (same as the citlla setup).
OPENSSL="openssl"
for cand in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    if [[ -x "$cand" ]]; then OPENSSL="$cand"; break; fi
done

IDENTITY_NAME="${WAREADER_IDENTITY_NAME:-WA Reader for Muse Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/wareader-signing.keychain-db"
SUPPORT="$HOME/Library/Application Support/WAReaderForMuse/signing"
PASSWORD_FILE="$SUPPORT/keychain-password"
CERT_FILE="$SUPPORT/certificate.pem"
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    if [[ $FORCE -eq 0 ]]; then
        echo "Identity \"$IDENTITY_NAME\" already exists in $KEYCHAIN"
        echo "Use --force to replace it. Replacing it invalidates every existing TCC grant."
        exit 0
    fi
    echo "Replacing the existing identity (existing TCC grants will stop matching)"
    security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
fi

if [[ -e "$KEYCHAIN" && $FORCE -eq 0 ]]; then
    echo "$KEYCHAIN already exists but has no usable identity." >&2
    echo "Re-run with --force to recreate it." >&2
    exit 1
fi

mkdir -p "$SUPPORT"
chmod 700 "$SUPPORT"
umask 077

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSWORD="$("$OPENSSL" rand -hex 16)"
printf '%s' "$PASSWORD" > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

echo "Generating a 10-year self-signed code-signing certificate"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$IDENTITY_NAME/O=Eric Ng" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# macOS's security tool still expects the older PKCS#12 encryption.
"$OPENSSL" pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout pass:wareader -name "$IDENTITY_NAME" >/dev/null 2>&1

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P wareader \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
cp "$WORK/cert.pem" "$CERT_FILE"
chmod 644 "$CERT_FILE"

FINGERPRINT="$("$OPENSSL" x509 -in "$CERT_FILE" -noout -fingerprint -sha1 \
    | sed 's/^.*=//; s/://g')"

echo
echo "Created \"$IDENTITY_NAME\""
echo "  keychain      $KEYCHAIN"
echo "  fingerprint   $FINGERPRINT (SHA-1)"
echo "  validity      10 years"
echo
echo "Scripts/build.sh will now sign with it automatically."
echo "One-time step: grant Full Disk Access to the installed app once"
echo "(System Settings -> Privacy & Security -> Full Disk Access)."
