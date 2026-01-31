#!/bin/bash
# Verify an incoming handshake request or manifest
#
# Usage: ./handshake-verify.sh <manifest.yaml|message.json>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

# Default values
INPUT_FILE=""
SKIP_MOLTBOOK=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-moltbook)
            SKIP_MOLTBOOK=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: handshake-verify.sh <FILE> [OPTIONS]"
            echo ""
            echo "Verify a manifest or handshake message."
            echo ""
            echo "Options:"
            echo "  --skip-moltbook   Skip Moltbook claim verification"
            echo "  --verbose, -v     Show detailed verification steps"
            echo "  --help            Show this help"
            echo ""
            echo "Examples:"
            echo "  ./handshake-verify.sh their-manifest.yaml"
            echo "  ./handshake-verify.sh incoming-hello.json"
            exit 0
            ;;
        *)
            if [[ -f "$1" ]]; then
                INPUT_FILE="$1"
            else
                echo "File not found: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$INPUT_FILE" ]]; then
    echo "Error: Input file required"
    echo "Usage: handshake-verify.sh <manifest.yaml|message.json>"
    exit 1
fi

echo "Verifying: $INPUT_FILE"
echo ""

# Get Moltbook API key if available
API_KEY=""
if [[ -f ~/.config/moltbook/credentials.json ]]; then
    API_KEY=$(jq -r .api_key ~/.config/moltbook/credentials.json 2>/dev/null || echo "")
fi

# Run verification
python3 - <<EOF
import sys
import json
import yaml
sys.path.insert(0, "$LIB_DIR")

from signature import verify_manifest, TrustLevel
from pathlib import Path

# Load file
input_path = Path("$INPUT_FILE")
content = input_path.read_text()

# Detect format
if input_path.suffix in ['.yaml', '.yml']:
    data = yaml.safe_load(content)
else:
    data = json.loads(content)

# Check if it's a handshake message or manifest
if "type" in data and data["type"] in ["HELLO", "HELLO_RESPONSE", "MANIFEST"]:
    print("Detected: Handshake message")
    msg_type = data["type"]
    from_agent = data.get("from", "unknown")
    print(f"  Type: {msg_type}")
    print(f"  From: {from_agent}")
    print(f"  Nonce: {data.get('nonce', 'none')}")
    print("")
    
    # Extract manifest if present
    if "payload" in data and "manifest" in data["payload"]:
        print("Extracting embedded manifest...")
        manifest_data = data["payload"]["manifest"]
    else:
        print("No manifest in message payload")
        sys.exit(0)
else:
    # Assume it's a raw manifest
    print("Detected: Manifest")
    manifest_data = data

# Run verification
api_key = "$API_KEY" if "$API_KEY" else None
skip_moltbook = "$SKIP_MOLTBOOK" == "true"
verbose = "$VERBOSE" == "true"

if verbose:
    print("")
    print("Verification steps:")
    print("-" * 40)

result = verify_manifest(
    manifest_data,
    moltbook_api_key=api_key,
    verify_moltbook=not skip_moltbook,
)

# Print result
print("")
print("=" * 50)
print(f"Result: {result}")
print("=" * 50)
print("")

print(f"Trust Level: {result.trust_level.name} ({result.trust_level.value})")
print("")

if result.errors:
    print("Errors:")
    for err in result.errors:
        print(f"  ✗ {err}")
    print("")

if result.warnings:
    print("Warnings:")
    for warn in result.warnings:
        print(f"  ⚠ {warn}")
    print("")

if verbose:
    print("Manifest details:")
    print(f"  Agent: {manifest_data.get('agent', {}).get('name')}")
    print(f"  Human: @{manifest_data.get('human', {}).get('x_handle')}")
    print(f"  Claimed: {manifest_data.get('human', {}).get('claimed_at', 'unknown')[:10]}")
    
    caps = manifest_data.get('capabilities', {})
    if caps.get('tools'):
        print(f"  Tools: {', '.join(t['id'] for t in caps['tools'])}")
    if caps.get('domains'):
        print(f"  Domains: {', '.join(caps['domains'])}")

# Exit code
sys.exit(0 if result.valid else 1)
EOF
