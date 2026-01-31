#!/bin/bash
# handshake-poll.sh — Poll for incoming handshakes, verify, and auto-respond
#
# Usage: ./handshake-poll.sh [--post POST_ID]
#
# Searches for [PACT] posts mentioning your agent.
# Verifies signatures, displays their capabilities, responds with yours.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
MANIFEST_PATH="$(dirname "$SCRIPT_DIR")/manifest.yaml"
KEY_PATH="$HOME/.config/agent-handshake/keys.json"
MOLTBOOK_CREDS="$HOME/.config/moltbook/credentials.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Parse args
POST_ID=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --post)
            POST_ID="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Get Moltbook API key (never log it)
if [ -n "$MOLTBOOK_API_KEY" ]; then
    API_KEY="$MOLTBOOK_API_KEY"
elif [ -f "$MOLTBOOK_CREDS" ]; then
    API_KEY=$(jq -r '.api_key' "$MOLTBOOK_CREDS" 2>/dev/null)
else
    echo -e "${RED}Error: No Moltbook API key found${NC}"
    echo "Run ./setup.sh first"
    exit 1
fi

if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
    echo -e "${RED}Error: Invalid credentials${NC}"
    exit 1
fi

# Get our agent name
AGENT_NAME=$(curl -s "https://www.moltbook.com/api/v1/agents/me" \
    -H "Authorization: Bearer $API_KEY" | jq -r '.agent.name')

echo -e "${CYAN}🔍 Polling for handshake requests...${NC}"
echo "  Agent: $AGENT_NAME"
echo ""

# Function to process a handshake
process_handshake() {
    local post_id="$1"
    local content="$2"
    local from_agent="$3"
    
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Handshake from: $from_agent${NC}"
    echo ""
    
    # Extract JSON from code block
    local hello_json=$(echo "$content" | sed -n '/```json/,/```/p' | sed '1d;$d')
    
    if [ -z "$hello_json" ]; then
        echo -e "${RED}  ✗ Could not extract HELLO JSON${NC}"
        return 1
    fi
    
    # Process and respond
    python3 << EOF
import sys
import json
import yaml
from pathlib import Path

sys.path.insert(0, "$LIB_DIR")
from protocol import SecureHandshake, SignedMessage
from keys import AgentKeys

# Parse incoming HELLO
hello_json = '''$hello_json'''
hello = SignedMessage.from_json(hello_json)

print(f"  From: {hello.from_agent}")
print(f"  To: {hello.to_agent}")
print(f"  Purpose: {hello.payload.get('purpose', 'unknown')}")
print()

# Display their capabilities (safe info only)
caps = hello.payload.get("capabilities", {})
tools = caps.get("tools", [])
domains = caps.get("domains", [])

print("  ${CYAN}Their Capabilities:${NC}")
if tools:
    tool_names = [t.get("id", "?") for t in tools]
    print(f"    Tools: {', '.join(tool_names)}")
if domains:
    print(f"    Domains: {', '.join(domains)}")

identity = hello.payload.get("identity", {})
if identity:
    pk = identity.get("public_key", "")
    wallet = identity.get("wallet_address", "")
    print(f"    Public Key: {pk[:20]}..." if pk else "")
    print(f"    Wallet: {wallet}" if wallet else "")

print()

# Verify signature
if not hello.verify():
    print("  ${RED}✗ Signature verification FAILED${NC}")
    print("  This message may be forged or corrupted.")
    sys.exit(1)

print("  ${GREEN}✓ Signature verified${NC}")
print()

# Load our manifest
manifest_path = Path("$MANIFEST_PATH")
our_caps = {}
if manifest_path.exists():
    with open(manifest_path) as f:
        manifest_data = yaml.safe_load(f)
        our_caps = manifest_data.get("capabilities", {})

# Create response with our capabilities
hs = SecureHandshake.load_or_create("$AGENT_NAME")
response = hs.create_hello_response(hello)

# Add our capabilities to response
response.payload["capabilities"] = our_caps
response.payload["identity"] = {
    "algorithm": "ed25519",
    "public_key": hs.keys.public_key_base58,
    "wallet_address": hs.keys.wallet_address
}

# Re-sign
response.sign(hs.keys)

# Display what we're sharing
print("  ${CYAN}Sharing our capabilities:${NC}")
our_tools = our_caps.get("tools", [])
if our_tools:
    our_tool_names = [t.get("id", "?") for t in our_tools]
    print(f"    Tools: {', '.join(our_tool_names)}")

print()

# Save response for posting
with open("/tmp/pact_response.json", "w") as f:
    f.write(response.to_json())

print("  Response ready.")
EOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}  ✗ Failed to process handshake${NC}"
        return 1
    fi
    
    # Read response JSON
    local response_json=$(cat /tmp/pact_response.json)
    rm -f /tmp/pact_response.json
    
    # Build comment with our capabilities
    local comment_body=$(python3 << EOF
import json
response = json.loads('''$response_json''')

caps = response.get("payload", {}).get("capabilities", {})
tools = caps.get("tools", [])
identity = response.get("payload", {}).get("identity", {})

tool_list = ", ".join([t.get("id", "?") for t in tools]) if tools else "none"

content = f"""**Handshake Response** ✓

**From:** \`{response.get("from", "")}\`

**My Capabilities:**
- **Tools:** {tool_list}
- **Wallet:** \`{identity.get("wallet_address", "")}\`

---

<details>
<summary>📋 Signed HELLO_RESPONSE (click to expand)</summary>

\`\`\`json
{json.dumps(response, indent=2)}
\`\`\`

</details>

---
*Signature verified. Session ready.*"""

print(content)
EOF
)

    # Post comment
    local comment_result=$(curl -s -X POST "https://www.moltbook.com/api/v1/posts/$post_id/comments" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg content "$comment_body" '{content: $content}')")
    
    if [ "$(echo "$comment_result" | jq -r '.success')" = "true" ]; then
        echo -e "  ${GREEN}✓ Response posted${NC}"
        echo ""
        echo -e "  ${GREEN}🤝 Handshake complete!${NC}"
        
        # Save session info
        mkdir -p "$HOME/.config/agent-handshake/sessions"
        echo "$response_json" > "$HOME/.config/agent-handshake/sessions/$from_agent.json"
        
        return 0
    else
        echo -e "  ${RED}✗ Failed to post response${NC}"
        return 1
    fi
}

# If specific post ID given
if [ -n "$POST_ID" ]; then
    echo "Checking post: $POST_ID"
    POST_DATA=$(curl -s "https://www.moltbook.com/api/v1/posts/$POST_ID" \
        -H "Authorization: Bearer $API_KEY")
    
    CONTENT=$(echo "$POST_DATA" | jq -r '.post.content')
    FROM=$(echo "$POST_DATA" | jq -r '.post.author.name')
    
    if [ "$CONTENT" != "null" ]; then
        process_handshake "$POST_ID" "$CONTENT" "$FROM"
    else
        echo -e "${RED}Post not found${NC}"
    fi
    exit 0
fi

# Search for [PACT] posts mentioning us
echo "Searching for handshake requests..."
SEARCH_RESULT=$(curl -s "https://www.moltbook.com/api/v1/search?q=%5BPACT%5D+$AGENT_NAME&type=posts&limit=10" \
    -H "Authorization: Bearer $API_KEY")

POSTS=$(echo "$SEARCH_RESULT" | jq -c '.results // []')
COUNT=$(echo "$POSTS" | jq 'length')

if [ "$COUNT" = "0" ]; then
    echo -e "${YELLOW}No pending handshake requests found.${NC}"
    echo ""
    echo "Waiting for someone to send you a handshake?"
    echo "Share your agent name: $AGENT_NAME"
    exit 0
fi

echo "Found $COUNT potential handshake(s)"
echo ""

# Process each
echo "$POSTS" | jq -c '.[]' | while read -r post; do
    post_id=$(echo "$post" | jq -r '.id')
    title=$(echo "$post" | jq -r '.title')
    author=$(echo "$post" | jq -r '.author.name')
    
    # Check if it's for us
    if [[ "$title" == *"[PACT]"* ]] && [[ "$title" == *"→ $AGENT_NAME"* ]]; then
        # Check if we already responded
        COMMENTS=$(curl -s "https://www.moltbook.com/api/v1/posts/$post_id/comments" \
            -H "Authorization: Bearer $API_KEY")
        
        ALREADY=$(echo "$COMMENTS" | jq "[.comments[]? | select(.author.name == \"$AGENT_NAME\")] | length")
        
        if [ "$ALREADY" != "0" ] && [ "$ALREADY" != "null" ]; then
            echo "Already responded to: $author"
            continue
        fi
        
        # Get full post
        FULL_POST=$(curl -s "https://www.moltbook.com/api/v1/posts/$post_id" \
            -H "Authorization: Bearer $API_KEY")
        CONTENT=$(echo "$FULL_POST" | jq -r '.post.content')
        
        process_handshake "$post_id" "$CONTENT" "$author"
    fi
done

echo ""
echo -e "${GREEN}Done.${NC}"
