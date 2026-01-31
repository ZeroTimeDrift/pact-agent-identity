#!/bin/bash
# Sign manifest with Ed25519 key and add public key
#
# Usage: ./manifest-sign-ed25519.sh [manifest.yaml]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
MANIFEST_FILE="${1:-manifest.yaml}"
KEY_PATH="$HOME/.config/agent-handshake/keys.json"

if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "Error: Manifest not found: $MANIFEST_FILE"
    exit 1
fi

if [[ ! -f "$KEY_PATH" ]]; then
    echo "Error: Keys not found. Run keys-generate.sh first."
    exit 1
fi

python3 << EOF
import sys
import yaml
import hashlib
sys.path.insert(0, "$LIB_DIR")
from keys import AgentKeys
from pathlib import Path

# Load keys
keys = AgentKeys.load(Path("$KEY_PATH"))
print(f"Using key: {keys.public_key_base58}")

# Load manifest
with open("$MANIFEST_FILE") as f:
    manifest = yaml.safe_load(f)

# Remove old signature if present
if "signature" in manifest:
    del manifest["signature"]

# Add identity block with public key
if "identity" not in manifest:
    manifest["identity"] = {}

manifest["identity"] = {
    "algorithm": "ed25519",
    "public_key": keys.public_key_base58,
    "wallet_address": keys.wallet_address,
}

# Compute content hash (without signature)
content = yaml.dump(manifest, default_flow_style=False, sort_keys=False)
content_hash = hashlib.sha256(content.encode()).hexdigest()

# Sign the hash
signature = keys.sign_string(content_hash)

# Add signature block
manifest["signature"] = {
    "algorithm": "ed25519",
    "content_hash": f"sha256:{content_hash}",
    "public_key": keys.public_key_base58,
    "signature": signature,
}

# Save
with open("$MANIFEST_FILE", "w") as f:
    yaml.dump(manifest, f, default_flow_style=False, sort_keys=False)

print("")
print("✓ Manifest signed with Ed25519")
print(f"✓ Public key: {keys.public_key_base58}")
print(f"✓ Content hash: sha256:{content_hash[:16]}...")
print(f"✓ Saved to: $MANIFEST_FILE")
EOF
