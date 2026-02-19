#!/usr/bin/env bash
set -euo pipefail

# setup-server.sh — Run on a remote server to prepare for automated registration.
# Generates an Ed25519 SSH keypair, collects server info, encrypts everything,
# and outputs a single registration token to paste into the UI.

# 1. Check dependencies
for cmd in openssl ssh-keygen hostname; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required but not installed"; exit 1; }
done

# 2. Collect server info
HOSTNAME=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOSTNAME" ] && HOSTNAME=$(hostname -f)
SSH_PORT=${SSH_PORT:-22}
SSH_USER=$(whoami)

echo "Detected: ${SSH_USER}@${HOSTNAME}:${SSH_PORT}"

# 3. Generate Ed25519 keypair in a temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT
ssh-keygen -t ed25519 -f "$TEMP_DIR/id_ed25519" -N "" -q
echo "SSH keypair generated (Ed25519)."

# 4. Install public key into authorized_keys
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat "$TEMP_DIR/id_ed25519.pub" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "Public key installed in ~/.ssh/authorized_keys"

# 5. Generate random encryption key (32 bytes hex = 64 chars)
ENC_KEY=$(openssl rand -hex 32)

# 6. Build JSON payload (awk handles newline escaping for the private key)
PUBLIC_KEY=$(tr -d '\n' < "$TEMP_DIR/id_ed25519.pub")
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Escape private key: replace \ with \\, " with \", then join lines with \n
PRIVATE_KEY_ESCAPED=$(awk '{gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "%s\\n", $0}' "$TEMP_DIR/id_ed25519")
PAYLOAD="{\"hostname\":\"$HOSTNAME\",\"sshPort\":$SSH_PORT,\"sshUsername\":\"$SSH_USER\",\"publicKey\":\"$PUBLIC_KEY\",\"privateKeyPem\":\"$PRIVATE_KEY_ESCAPED\",\"generatedAtUtc\":\"$GENERATED_AT\"}"

# 7. Encrypt with AES-256-CBC (OpenSSL PBKDF2 format)
ENCRYPTED=$(echo "$PAYLOAD" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -md sha256 -pass "pass:$ENC_KEY" -a -A)

# 8. Strip base64 padding (we'll add our own position marker)
ENCRYPTED_CLEAN=$(echo -n "$ENCRYPTED" | sed 's/=*$//')

# 9. Pick random position 10-99 and insert hex key there
POS=$(( (RANDOM % 90) + 10 ))
BEFORE=${ENCRYPTED_CLEAN:0:$POS}
AFTER=${ENCRYPTED_CLEAN:$POS}

# 10. Encode position: tens digit -> letter (A=1..I=9), ones digit stays
TENS=$((POS / 10))
ONES=$((POS % 10))
LETTERS="_ABCDEFGHI"
POS_ENCODED="${LETTERS:$TENS:1}${ONES}=="

# 11. Build single registration token
REGISTRATION_TOKEN="${BEFORE}${ENC_KEY}${AFTER}${POS_ENCODED}"

# 12. Compute fingerprint for display
FINGERPRINT=$(ssh-keygen -l -f "$TEMP_DIR/id_ed25519.pub" | awk '{print $2}')

# 13. Output
echo ""
echo "=========================================="
echo "  SERVER REGISTRATION TOKEN"
echo "=========================================="
echo ""
echo "Copy this token and paste it into the registration form:"
echo ""
echo "$REGISTRATION_TOKEN"
echo ""
echo "------------------------------------------"
echo "Server:      ${HOSTNAME}:${SSH_PORT}"
echo "User:        ${SSH_USER}"
echo "Fingerprint: ${FINGERPRINT}"
echo "Expires:     15 minutes from generation"
echo "=========================================="
