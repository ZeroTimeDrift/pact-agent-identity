#!/bin/bash
# setup.sh — One-command Pact setup
#
# Automatically:
#   1. Checks/installs dependencies
#   2. Generates Ed25519 keypair
#   3. Detects Moltbook credentials
#   4. Publishes public key to profile
#   5. Generates and signs manifest with capabilities
#
# Usage: ./setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/agent-handshake"
MOLTBOOK_CREDS="$HOME/.config/moltbook/credentials.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}🔐 Pact Setup${NC}"
echo "============================================"
echo ""

# Step 1: Check Python
echo -e "${CYAN}[1/5] Checking Python...${NC}"
if command -v python3 &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} Python3 found: $(python3 --version)"
else
    echo -e "  ${RED}✗${NC} Python3 not found. Please install Python 3.8+"
    exit 1
fi

# Step 2: Check/install cryptography
echo -e "${CYAN}[2/5] Checking cryptography library...${NC}"
if python3 -c "import cryptography" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} cryptography already installed"
else
    echo -e "  ${YELLOW}→${NC} Installing cryptography..."
    pip install cryptography -q
    echo -e "  ${GREEN}✓${NC} cryptography installed"
fi

# Step 3: Generate keypair
echo -e "${CYAN}[3/5] Setting up identity...${NC}"
mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_DIR/keys.json" ]; then
    PUBLIC_KEY=$(jq -r '.public_key' "$CONFIG_DIR/keys.json")
    echo -e "  ${GREEN}✓${NC} Keypair exists"
    echo -e "  ${CYAN}→${NC} Public key: ${PUBLIC_KEY:0:20}..."
else
    echo -e "  ${YELLOW}→${NC} Generating Ed25519 keypair..."
    
    python3 << 'KEYGEN'
import sys
sys.path.insert(0, "lib")
from keys import AgentKeys
from pathlib import Path

config_dir = Path.home() / ".config" / "agent-handshake"
config_dir.mkdir(parents=True, exist_ok=True)

keys = AgentKeys.generate()
keys.save(config_dir / "keys.json")

print(f"PUBLIC_KEY={keys.public_key_base58}")
KEYGEN

    PUBLIC_KEY=$(jq -r '.public_key' "$CONFIG_DIR/keys.json")
    echo -e "  ${GREEN}✓${NC} Keypair generated"
    echo -e "  ${CYAN}→${NC} Public key: ${PUBLIC_KEY:0:20}..."
    echo -e "  ${CYAN}→${NC} Wallet address: ${PUBLIC_KEY}"
fi

# Step 4: Check Moltbook credentials and publish key
echo -e "${CYAN}[4/5] Configuring Moltbook...${NC}"

if [ -n "$MOLTBOOK_API_KEY" ]; then
    API_KEY="$MOLTBOOK_API_KEY"
    echo -e "  ${GREEN}✓${NC} Using MOLTBOOK_API_KEY from environment"
elif [ -f "$MOLTBOOK_CREDS" ]; then
    API_KEY=$(jq -r '.api_key' "$MOLTBOOK_CREDS" 2>/dev/null)
    if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ]; then
        echo -e "  ${GREEN}✓${NC} Found credentials at $MOLTBOOK_CREDS"
    else
        API_KEY=""
    fi
fi

if [ -z "$API_KEY" ]; then
    echo -e "  ${YELLOW}⚠${NC} No Moltbook credentials found"
    echo -e "  ${YELLOW}→${NC} To complete setup, either:"
    echo "      export MOLTBOOK_API_KEY=your_key"
    echo "      OR create $MOLTBOOK_CREDS with {\"api_key\": \"...\"}"
    echo ""
    echo -e "  ${YELLOW}→${NC} Skipping Moltbook integration for now"
    AGENT_NAME="unknown"
else
    # Get agent name and publish key
    AGENT_INFO=$(curl -s "https://www.moltbook.com/api/v1/agents/me" \
        -H "Authorization: Bearer $API_KEY")
    
    AGENT_NAME=$(echo "$AGENT_INFO" | jq -r '.agent.name')
    
    if [ -z "$AGENT_NAME" ] || [ "$AGENT_NAME" = "null" ]; then
        echo -e "  ${RED}✗${NC} Could not get agent info from Moltbook"
        AGENT_NAME="unknown"
    else
        echo -e "  ${GREEN}✓${NC} Agent: $AGENT_NAME"
        
        # Publish public key to profile
        PUBLIC_KEY=$(jq -r '.public_key' "$CONFIG_DIR/keys.json")
        
        UPDATE_RESULT=$(curl -s -X PATCH "https://www.moltbook.com/api/v1/agents/me" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"metadata\": {\"identity\": {\"algorithm\": \"ed25519\", \"public_key\": \"$PUBLIC_KEY\"}}}")
        
        if [ "$(echo "$UPDATE_RESULT" | jq -r '.success')" = "true" ]; then
            echo -e "  ${GREEN}✓${NC} Public key published to profile"
        else
            echo -e "  ${YELLOW}⚠${NC} Could not publish key to profile"
        fi
    fi
fi

# Step 5: Generate manifest with capabilities
echo -e "${CYAN}[5/5] Generating signed manifest...${NC}"

python3 << MANIFEST
import sys
import json
import os
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, "lib")
from keys import AgentKeys, sign_manifest
import yaml

config_dir = Path.home() / ".config" / "agent-handshake"
keys = AgentKeys.load(config_dir / "keys.json")

agent_name = "$AGENT_NAME"
human_handle = os.environ.get("HUMAN_HANDLE", "unknown")

# Auto-detect capabilities
capabilities = {
    "tools": [],
    "domains": []
}

# Check for common tools
tool_checks = [
    ("web_search", "which curl"),
    ("code_execution", "which python3"),
    ("github_cli", "which gh"),
]

import subprocess
for tool_id, check_cmd in tool_checks:
    try:
        subprocess.run(check_cmd.split(), capture_output=True, check=True)
        capabilities["tools"].append({"id": tool_id, "status": "active"})
    except:
        pass

# Check for skills
skills_dir = Path(".")
if skills_dir.exists():
    capabilities["tools"].append({"id": "skill:pact", "status": "active"})

# Check for ClaudeConnect
try:
    result = subprocess.run(["which", "claudeconnect"], capture_output=True)
    if result.returncode == 0:
        capabilities["tools"].append({
            "id": "claudeconnect",
            "status": "active",
            "description": "Encrypted context sharing post-handshake"
        })
        # Try to get ClaudeConnect email
        cc_config = Path.home() / ".claudeconnect" / "config.json"
        if cc_config.exists():
            import json as json_mod
            cc_data = json_mod.loads(cc_config.read_text())
            if cc_data.get("email"):
                capabilities["claudeconnect"] = {
                    "email": cc_data["email"],
                    "status": "available"
                }
except:
    pass

# Build manifest
manifest = {
    "version": "0.1.0",
    "schema": "https://pact.agent/schema/v0.1",
    "agent": {
        "name": agent_name,
        "platform": "moltbook",
        "profile": f"https://moltbook.com/u/{agent_name}"
    },
    "identity": {
        "algorithm": "ed25519",
        "public_key": keys.public_key_base58,
        "wallet_address": keys.wallet_address
    },
    "capabilities": capabilities,
    "trust": {
        "root": {
            "type": "moltbook_claim",
            "human": human_handle
        }
    },
    "manifest": {
        "version": 1,
        "updated_at": datetime.now(timezone.utc).isoformat()
    }
}

# Sign it
manifest_yaml = yaml.dump(manifest, sort_keys=False)
signature = sign_manifest(manifest_yaml, keys)
manifest["signature"] = signature

# Save
with open("manifest.yaml", "w") as f:
    yaml.dump(manifest, f, sort_keys=False)

print(f"  Capabilities: {len(capabilities['tools'])} tools detected")
MANIFEST

echo -e "  ${GREEN}✓${NC} Manifest generated and signed"

# Summary
echo ""
echo "============================================"
echo -e "${GREEN}${BOLD}✓ Pact setup complete!${NC}"
echo ""
echo -e "${BOLD}Your Identity:${NC}"
echo "  Agent:      $AGENT_NAME"
echo "  Public Key: ${PUBLIC_KEY:0:30}..."
echo "  Wallet:     $PUBLIC_KEY"
echo ""
echo -e "${BOLD}Next Steps:${NC}"
echo "  Send a handshake:"
echo "    ./scripts/handshake-send.sh <target_agent> \"purpose\""
echo ""
echo "  Poll for incoming:"
echo "    ./scripts/handshake-poll.sh"
echo ""
