#!/bin/bash
# Update manifest when capabilities change
#
# Usage: ./manifest-update.sh [--check-only] [--manifest FILE]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

MANIFEST_FILE="manifest.yaml"
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --check-only|-c)
            CHECK_ONLY=true
            shift
            ;;
        --manifest|-m)
            MANIFEST_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: manifest-update.sh [OPTIONS]"
            echo ""
            echo "Scan for capability changes and update manifest."
            echo ""
            echo "Options:"
            echo "  --check-only, -c   Only check for changes, don't update"
            echo "  --manifest, -m     Manifest file (default: manifest.yaml)"
            echo "  --help             Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

python3 - <<EOF
import sys
import os
import shutil
import json
import yaml
from pathlib import Path
from datetime import datetime, timezone

sys.path.insert(0, "$LIB_DIR")
from manifest import AgentManifest

manifest_path = Path("$MANIFEST_FILE")
check_only = "$CHECK_ONLY" == "true"

# Load existing manifest or create new
if manifest_path.exists():
    existing = AgentManifest.from_file(manifest_path)
    old_caps = existing.capabilities.copy()
    old_hash = existing.content_hash()
    print(f"Loaded existing manifest v{existing.manifest_version}")
else:
    existing = None
    old_caps = {}
    old_hash = None
    print("No existing manifest found, creating new")

# Detect current capabilities
detected_tools = []
detected_domains = []

# === TOOL DETECTION ===

# GitHub CLI
if shutil.which("gh"):
    # Check if authenticated
    gh_auth = os.popen("gh auth status 2>&1").read()
    if "Logged in" in gh_auth:
        detected_tools.append({"id": "github_cli", "status": "active"})
    else:
        detected_tools.append({"id": "github_cli", "status": "pending"})

# Bird (Twitter CLI)
if shutil.which("bird"):
    bird_check = os.popen("bird whoami 2>&1").read()
    if "error" not in bird_check.lower():
        detected_tools.append({"id": "x_twitter", "status": "active"})
    else:
        detected_tools.append({"id": "x_twitter", "status": "pending"})

# Moltbook
moltbook_creds = Path.home() / ".config/moltbook/credentials.json"
if moltbook_creds.exists():
    detected_tools.append({
        "id": "moltbook_api",
        "status": "active",
        "scopes": ["read", "post", "comment"]
    })

# Slack (check for token)
slack_paths = [
    Path.home() / ".clawdbot/credentials/slack-token.json",
    Path.home() / ".config/slack/token",
]
for sp in slack_paths:
    if sp.exists():
        detected_tools.append({"id": "slack", "status": "active"})
        break

# Gmail
gmail_token = Path.home() / ".clawdbot/credentials/gmail-token.json"
if gmail_token.exists():
    detected_tools.append({"id": "gmail", "status": "active"})

# Web capabilities (assume available in clawdbot)
detected_tools.append({"id": "web_search", "provider": "brave", "status": "active"})
detected_tools.append({"id": "web_fetch", "status": "active"})
detected_tools.append({"id": "code_execution", "languages": ["python", "bash", "javascript"], "status": "active"})

# === SKILL DETECTION ===
skill_paths = [
    Path.home() / ".clawdbot/skills",
    Path.home() / "clawd/skills",
    Path("/root/clawd/skills"),
]

for skill_dir in skill_paths:
    if skill_dir.exists():
        for skill in skill_dir.iterdir():
            if skill.is_dir() and (skill / "SKILL.md").exists():
                skill_name = skill.name
                detected_tools.append({
                    "id": f"skill:{skill_name}",
                    "status": "active",
                    # Note: path intentionally not included (privacy)
                })

# === DOMAIN DETECTION ===
# Could be smarter about this based on skills/usage
detected_domains = ["general"]

# Check if we have agent-handshake skill
if any(t["id"] == "skill:agent-handshake" for t in detected_tools):
    detected_domains.append("agent_infrastructure")

# === COMPARE CHANGES ===
old_tool_ids = set(t.get("id", "") for t in old_caps.get("tools", []))
new_tool_ids = set(t["id"] for t in detected_tools)

added = new_tool_ids - old_tool_ids
removed = old_tool_ids - new_tool_ids

print("")
print("=== CAPABILITY SCAN ===")
print(f"Detected {len(detected_tools)} tools, {len(detected_domains)} domains")
print("")

if added:
    print(f"Added: {', '.join(added)}")
if removed:
    print(f"Removed: {', '.join(removed)}")
if not added and not removed:
    print("No changes detected")

# === UPDATE MANIFEST ===
if check_only:
    print("")
    print("(Check only mode - no changes made)")
    sys.exit(0 if not added and not removed else 1)

if added or removed or existing is None:
    # Create updated manifest
    if existing:
        # Preserve identity, update capabilities
        updated = AgentManifest(
            agent_name=existing.agent_name,
            human_handle=existing.human_handle,
            platform=existing.platform,
            claimed_at=existing.claimed_at,
        )
        updated.manifest_version = existing.manifest_version + 1
        updated.previous_hash = old_hash
        updated.trust_vouches = existing.trust_vouches
    else:
        # Get from Moltbook
        api_key_path = Path.home() / ".config/moltbook/credentials.json"
        if api_key_path.exists():
            with open(api_key_path) as f:
                creds = json.load(f)
            api_key = creds.get("api_key")
            agent_name = creds.get("agent_name", "unknown")
            
            # Fetch profile
            import urllib.request
            req = urllib.request.Request(
                f"https://www.moltbook.com/api/v1/agents/me",
                headers={"Authorization": f"Bearer {api_key}"}
            )
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    profile = json.loads(resp.read().decode())
                agent_name = profile["agent"]["name"]
                human_handle = profile["agent"]["owner"]["x_handle"]
                claimed_at = profile["agent"]["claimed_at"]
            except:
                human_handle = "unknown"
                claimed_at = None
        else:
            agent_name = "unknown"
            human_handle = "unknown"
            claimed_at = None
        
        updated = AgentManifest(
            agent_name=agent_name,
            human_handle=human_handle,
            claimed_at=claimed_at,
        )
    
    # Set detected capabilities
    updated.capabilities = {
        "tools": detected_tools,
        "domains": detected_domains,
    }
    
    # Save
    updated.save(manifest_path)
    
    print("")
    print(f"✓ Manifest updated to v{updated.manifest_version}")
    print(f"✓ Saved to: {manifest_path}")
    print(f"✓ Content hash: {updated.content_hash()}")
    
    if added:
        print(f"✓ Added: {', '.join(added)}")
    if removed:
        print(f"✓ Removed: {', '.join(removed)}")
else:
    print("")
    print("No update needed")
EOF
