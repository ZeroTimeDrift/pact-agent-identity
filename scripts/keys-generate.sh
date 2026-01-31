#!/bin/bash
# Generate Ed25519 keypair for agent identity
#
# This creates a Solana-compatible wallet that can:
# - Sign handshake messages
# - Receive/send SOL and SPL tokens
#
# Usage: ./keys-generate.sh [--force]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
KEY_PATH="$HOME/.config/agent-handshake/keys.json"

FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        --path|-p)
            KEY_PATH="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: keys-generate.sh [OPTIONS]"
            echo ""
            echo "Generate Ed25519 keypair for agent identity."
            echo "Key doubles as a Solana wallet address."
            echo ""
            echo "Options:"
            echo "  --force, -f    Overwrite existing keys"
            echo "  --path, -p     Key file path (default: ~/.config/agent-handshake/keys.json)"
            echo "  --help         Show this help"
            echo ""
            echo "⚠️  IMPORTANT: Back up your keys! Lost keys = lost identity + funds."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Create directory if needed
mkdir -p "$(dirname "$KEY_PATH")"

# Check if keys exist
if [[ -f "$KEY_PATH" && "$FORCE" != "true" ]]; then
    echo "Keys already exist at: $KEY_PATH"
    echo ""
    echo "Current key info:"
    python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from keys import AgentKeys
from pathlib import Path
keys = AgentKeys.load(Path('$KEY_PATH'))
print(f'  Public Key:     {keys.public_key_base58}')
print(f'  Wallet Address: {keys.wallet_address}')
"
    echo ""
    echo "Use --force to regenerate (WARNING: old key will be lost!)"
    exit 0
fi

# Check for cryptography library
if ! python3 -c "from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey" 2>/dev/null; then
    echo "Installing cryptography library..."
    pip install cryptography -q
fi

# Generate keys
python3 << EOF
import sys
sys.path.insert(0, "$LIB_DIR")
from keys import AgentKeys
from pathlib import Path

print("Generating Ed25519 keypair...")
print("")

keys = AgentKeys.generate()

# Save
key_path = Path("$KEY_PATH")
keys.save(key_path)

print("=" * 60)
print("AGENT KEYPAIR GENERATED")
print("=" * 60)
print("")
print(f"Public Key:     {keys.public_key_base58}")
print(f"Wallet Address: {keys.wallet_address}")
print("")
print(f"Saved to: {key_path}")
print(f"Permissions: 600 (owner read/write only)")
print("")
print("=" * 60)
print("⚠️  BACKUP YOUR KEYS!")
print("=" * 60)
print("")
print("Your private key is stored in the file above.")
print("If you lose it, you lose:")
print("  - Your agent identity")
print("  - Any funds in the wallet")
print("")
print("Back it up securely!")
print("")
print("Next steps:")
print("  1. Add public key to your Moltbook profile")
print("  2. Run manifest-update.sh to include key in manifest")
print("  3. Start signing your handshake messages")
EOF
