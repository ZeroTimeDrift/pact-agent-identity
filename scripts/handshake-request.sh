#!/bin/bash
# Request a handshake with another agent
#
# Usage: ./handshake-request.sh <agent_name> --purpose "description" [OPTIONS]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

# Default values
TARGET_AGENT=""
PURPOSE=""
REQUEST_CAPS=""
SHARE_CAPS=""
MANIFEST_FILE="manifest.yaml"
OUTPUT_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --purpose|-p)
            PURPOSE="$2"
            shift 2
            ;;
        --request|-r)
            REQUEST_CAPS="$2"
            shift 2
            ;;
        --share|-s)
            SHARE_CAPS="$2"
            shift 2
            ;;
        --manifest|-m)
            MANIFEST_FILE="$2"
            shift 2
            ;;
        --output|-o)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: handshake-request.sh <AGENT_NAME> [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --purpose, -p    Purpose of collaboration (required)"
            echo "  --request, -r    Capabilities to request (comma-separated)"
            echo "  --share, -s      Capabilities to share (comma-separated)"
            echo "  --manifest, -m   Your manifest file (default: manifest.yaml)"
            echo "  --output, -o     Output file for HELLO message"
            echo "  --help           Show this help"
            echo ""
            echo "Example:"
            echo "  ./handshake-request.sh eudaemon_0 -p 'security audit' -r 'security_analysis'"
            exit 0
            ;;
        *)
            if [[ -z "$TARGET_AGENT" ]]; then
                TARGET_AGENT="$1"
            else
                echo "Unknown option: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$TARGET_AGENT" ]]; then
    echo "Error: Target agent name required"
    echo "Usage: handshake-request.sh <agent_name> --purpose 'description'"
    exit 1
fi

if [[ -z "$PURPOSE" ]]; then
    echo "Error: Purpose required (--purpose)"
    exit 1
fi

if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "Warning: Manifest file not found: $MANIFEST_FILE"
    echo "Run manifest-generate.sh first"
fi

echo "Creating handshake request..."
echo "  Target: $TARGET_AGENT"
echo "  Purpose: $PURPOSE"
[[ -n "$REQUEST_CAPS" ]] && echo "  Requesting: $REQUEST_CAPS"
[[ -n "$SHARE_CAPS" ]] && echo "  Sharing: $SHARE_CAPS"
echo ""

# Generate HELLO message
python3 - <<EOF
import sys
import json
sys.path.insert(0, "$LIB_DIR")

from manifest import AgentManifest
from handshake import HandshakeProtocol
from pathlib import Path

# Load manifest
if Path("$MANIFEST_FILE").exists():
    my_manifest = AgentManifest.from_file(Path("$MANIFEST_FILE"))
else:
    # Create minimal manifest
    my_manifest = AgentManifest("unknown", "unknown")

# Initialize protocol
protocol = HandshakeProtocol(my_manifest)

# Parse capabilities
request_caps = [c.strip() for c in "$REQUEST_CAPS".split(",") if c.strip()]
share_caps = [c.strip() for c in "$SHARE_CAPS".split(",") if c.strip()]

# Create HELLO
hello = protocol.create_hello(
    to_agent="$TARGET_AGENT",
    purpose="$PURPOSE",
    requested_capabilities=request_caps or None,
)

# Add share intent to payload
if share_caps:
    hello.payload["offering_capabilities"] = share_caps

print("HELLO Message:")
print("=" * 50)
print(hello.to_json())
print("=" * 50)
print("")

# Save if output file specified
output_file = "$OUTPUT_FILE"
if output_file:
    with open(output_file, "w") as f:
        f.write(hello.to_json())
    print(f"Saved to: {output_file}")
else:
    print("To save, re-run with --output <filename>")

print("")
print("Next step: Send this message to $TARGET_AGENT via:")
print("  - ClaudeConnect (if set up)")
print("  - Moltbook DM (when available)")
print("  - Or share via another channel")
EOF
