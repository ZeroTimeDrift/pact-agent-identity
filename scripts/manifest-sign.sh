#!/bin/bash
# Sign an agent manifest
#
# Usage: ./manifest-sign.sh [manifest.yaml] [--proof URL]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

# Default values
MANIFEST_FILE="manifest.yaml"
PROOF_URL=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --proof|-p)
            PROOF_URL="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: manifest-sign.sh [MANIFEST_FILE] [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --proof URL   URL to proof tweet (human's tweet containing the hash)"
            echo "  --help        Show this help"
            echo ""
            echo "If no proof URL is provided, the script will output the hash"
            echo "for your human to tweet, then you can re-run with --proof."
            exit 0
            ;;
        *)
            if [[ -f "$1" ]]; then
                MANIFEST_FILE="$1"
            else
                echo "Unknown option or file not found: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "Error: Manifest file not found: $MANIFEST_FILE"
    exit 1
fi

# Compute content hash
CONTENT_HASH=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from manifest import AgentManifest
from pathlib import Path
m = AgentManifest.from_file(Path('$MANIFEST_FILE'))
print(m.content_hash())
")

echo "Manifest: $MANIFEST_FILE"
echo "Content Hash: $CONTENT_HASH"
echo ""

if [[ -z "$PROOF_URL" ]]; then
    # No proof yet - prompt human to tweet
    HUMAN_HANDLE=$(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import yaml
with open('$MANIFEST_FILE') as f:
    m = yaml.safe_load(f)
print(m.get('human', {}).get('x_handle', 'YOUR_HANDLE'))
")
    
    echo "=========================================="
    echo "HUMAN ACTION REQUIRED"
    echo "=========================================="
    echo ""
    echo "Please have @$HUMAN_HANDLE tweet the following:"
    echo ""
    echo "---"
    echo "I verify my agent's manifest: $CONTENT_HASH"
    echo "---"
    echo ""
    echo "After posting, re-run this script with:"
    echo "  ./manifest-sign.sh $MANIFEST_FILE --proof https://x.com/$HUMAN_HANDLE/status/TWEET_ID"
    echo ""
    
else
    # Proof provided - add signature to manifest
    echo "Proof URL: $PROOF_URL"
    echo ""
    echo "Adding signature to manifest..."
    
    python3 - <<EOF
import sys
sys.path.insert(0, "$LIB_DIR")
from manifest import AgentManifest
from pathlib import Path

m = AgentManifest.from_file(Path("$MANIFEST_FILE"))

# Get human handle from manifest
import yaml
with open("$MANIFEST_FILE") as f:
    data = yaml.safe_load(f)
human_handle = data.get("human", {}).get("x_handle", "unknown")

# Set signature
m.set_signature(human_handle, "$PROOF_URL")

# Save signed manifest
m.save(Path("$MANIFEST_FILE"))

print(f"✓ Manifest signed by @{human_handle}")
print(f"✓ Saved to: $MANIFEST_FILE")
print("")
print("Signed manifest:")
print(m.to_yaml())
EOF

fi
