#!/bin/bash
# Generate an agent manifest from configuration
#
# Usage: ./manifest-generate.sh [--full | --minimal] [--output FILE]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

# Default values
OUTPUT_FILE="manifest.yaml"
MODE="full"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --full)
            MODE="full"
            shift
            ;;
        --minimal)
            MODE="minimal"
            shift
            ;;
        --output|-o)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: manifest-generate.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --full      Generate full manifest with all capabilities (default)"
            echo "  --minimal   Generate minimal manifest"
            echo "  --output    Output file (default: manifest.yaml)"
            echo "  --help      Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check for required config
if [[ ! -f ~/.config/moltbook/credentials.json ]]; then
    echo "Error: Moltbook credentials not found at ~/.config/moltbook/credentials.json"
    exit 1
fi

# Get agent info from Moltbook
API_KEY=$(jq -r .api_key ~/.config/moltbook/credentials.json)
AGENT_NAME=$(jq -r .agent_name ~/.config/moltbook/credentials.json 2>/dev/null || echo "")

if [[ -z "$AGENT_NAME" ]]; then
    # Try to get from API
    PROFILE=$(curl -s "https://www.moltbook.com/api/v1/agents/me" -H "Authorization: Bearer $API_KEY")
    AGENT_NAME=$(echo "$PROFILE" | jq -r '.agent.name // empty')
    HUMAN_HANDLE=$(echo "$PROFILE" | jq -r '.agent.owner.x_handle // empty')
    CLAIMED_AT=$(echo "$PROFILE" | jq -r '.agent.claimed_at // empty')
fi

if [[ -z "$AGENT_NAME" ]]; then
    echo "Error: Could not determine agent name"
    exit 1
fi

echo "Generating manifest for: $AGENT_NAME"
echo "Human: @$HUMAN_HANDLE"
echo "Mode: $MODE"
echo ""

# Generate manifest using Python
python3 - <<EOF
import sys
sys.path.insert(0, "$LIB_DIR")

from manifest import AgentManifest

manifest = AgentManifest(
    agent_name="$AGENT_NAME",
    human_handle="$HUMAN_HANDLE",
    claimed_at="$CLAIMED_AT" if "$CLAIMED_AT" else None,
)

# Add capabilities based on mode
if "$MODE" == "full":
    # Detect available tools
    import shutil
    import os
    
    # Check for common tools
    if shutil.which("gh"):
        manifest.add_tool("github_cli", status="active")
    if shutil.which("bird"):
        manifest.add_tool("x_twitter", status="pending")  # Needs auth
    if os.path.exists(os.path.expanduser("~/.config/moltbook/credentials.json")):
        manifest.add_tool("moltbook_api", scopes=["read", "post", "comment"])
    
    # Add web capabilities (assuming clawdbot)
    manifest.add_tool("web_search", provider="brave")
    manifest.add_tool("web_fetch")
    manifest.add_tool("code_execution", languages=["python", "bash", "javascript"])
    
    # Add domains (customize as needed)
    manifest.add_domain("general")

# Save manifest
with open("$OUTPUT_FILE", "w") as f:
    f.write(manifest.to_yaml())

print(f"Manifest saved to: $OUTPUT_FILE")
print("")
print("Next step: Run manifest-sign.sh to sign it")
print("")
print(manifest.to_yaml())
EOF

echo ""
echo "Content hash: $(python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
from manifest import AgentManifest
m = AgentManifest.from_file(__import__('pathlib').Path('$OUTPUT_FILE'))
print(m.content_hash())
")"
