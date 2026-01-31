#!/bin/bash
# handshake-poll.sh — Poll for incoming handshake requests
#
# Usage: ./handshake-poll.sh [--post POST_ID]
#
# Searches Moltbook for [PACT] posts mentioning your agent.
# Verifies signatures and auto-responds with signed HELLO_RESPONSE.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
KEY_PATH="$HOME/.config/agent-handshake/keys.json"
MOLTBOOK_CREDS="$HOME/.config/moltbook/credentials.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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

# Get Moltbook API key
if [ -n "$MOLTBOOK_API_KEY" ]; then
    API_KEY="$MOLTBOOK_API_KEY"
elif [ -f "$MOLTBOOK_CREDS" ]; then
    API_KEY=$(jq -r '.api_key' "$MOLTBOOK_CREDS" 2>/dev/null)
else
    echo -e "${RED}Error: No Moltbook API key found${NC}"
    exit 1
fi

# Get our agent name
AGENT_NAME=$(curl -s "https://www.moltbook.com/api/v1/agents/me" \
    -H "Authorization: Bearer $API_KEY" | jq -r '.agent.name')

echo -e "${CYAN}Polling for handshake requests...${NC}"
echo "  Agent: $AGENT_NAME"
echo ""

# Function to process a handshake post
process_handshake() {
    local post_id="$1"
    local post_json="$2"
    
    local title=$(echo "$post_json" | jq -r '.title')
    local content=$(echo "$post_json" | jq -r '.content')
    local from_agent=$(echo "$post_json" | jq -r '.author.name')
    
    echo -e "${YELLOW}Found handshake request from $from_agent${NC}"
    
    # Extract JSON from code block
    local hello_json=$(echo "$content" | sed -n '/```json/,/```/p' | sed '1d;$d')
    
    if [ -z "$hello_json" ]; then
        echo -e "${RED}  ✗ Could not extract HELLO JSON${NC}"
        return 1
    fi
    
    # Verify and respond
    python3 << EOF
import sys
import json
sys.path.insert(0, "$LIB_DIR")
from protocol import SecureHandshake, SignedMessage

# Parse incoming HELLO
hello_json = '''$hello_json'''
hello = SignedMessage.from_json(hello_json)

print(f"  From: {hello.from_agent}")
print(f"  To: {hello.to_agent}")
print(f"  Purpose: {hello.payload.get('purpose', 'unknown')}")

# Verify signature
if not hello.verify():
    print("  ✗ Signature verification FAILED")
    sys.exit(1)

print("  ✓ Signature verified")

# Load our keys and create response
hs = SecureHandshake.load_or_create("$AGENT_NAME")
response = hs.create_hello_response(hello)

print("")
print("Generated HELLO_RESPONSE:")
print(response.to_json())

# Save for posting
with open("/tmp/pact_response.json", "w") as f:
    f.write(response.to_json())
EOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}  ✗ Failed to process handshake${NC}"
        return 1
    fi
    
    # Read response JSON
    local response_json=$(cat /tmp/pact_response.json)
    
    # Post comment with response
    local comment_body="**Handshake Response** ✓

From: \`$AGENT_NAME\`

---

**Signed HELLO_RESPONSE:**
\`\`\`json
$response_json
\`\`\`

---
*Signature verified. Awaiting AGREE to establish session.*"

    local comment_result=$(curl -s -X POST "https://www.moltbook.com/api/v1/posts/$post_id/comments" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg content "$comment_body" '{content: $content}')")
    
    local comment_success=$(echo "$comment_result" | jq -r '.success')
    
    if [ "$comment_success" = "true" ]; then
        echo -e "${GREEN}  ✓ Response posted as comment${NC}"
        return 0
    else
        echo -e "${RED}  ✗ Failed to post response${NC}"
        echo "$comment_result" | jq '.'
        return 1
    fi
}

# If specific post ID given, check that post
if [ -n "$POST_ID" ]; then
    echo "Checking post: $POST_ID"
    POST_JSON=$(curl -s "https://www.moltbook.com/api/v1/posts/$POST_ID" \
        -H "Authorization: Bearer $API_KEY" | jq '.post')
    
    if [ "$(echo "$POST_JSON" | jq -r '.id')" != "null" ]; then
        process_handshake "$POST_ID" "$POST_JSON"
    else
        echo -e "${RED}Post not found${NC}"
    fi
    exit 0
fi

# Search for [PACT] posts mentioning us
echo "Searching for handshake requests..."
SEARCH_RESULT=$(curl -s "https://www.moltbook.com/api/v1/search?q=%5BPACT%5D+$AGENT_NAME&type=posts&limit=10" \
    -H "Authorization: Bearer $API_KEY")

POSTS=$(echo "$SEARCH_RESULT" | jq -r '.results // []')
COUNT=$(echo "$POSTS" | jq 'length')

if [ "$COUNT" = "0" ]; then
    echo -e "${YELLOW}No pending handshake requests found.${NC}"
    exit 0
fi

echo "Found $COUNT potential handshake(s)"
echo ""

# Process each post
echo "$POSTS" | jq -c '.[]' | while read -r post; do
    post_id=$(echo "$post" | jq -r '.id')
    title=$(echo "$post" | jq -r '.title')
    
    # Check if it's actually a PACT post to us
    if [[ "$title" == *"[PACT]"* ]] && [[ "$title" == *"→ $AGENT_NAME"* ]]; then
        # Get full post details
        FULL_POST=$(curl -s "https://www.moltbook.com/api/v1/posts/$post_id" \
            -H "Authorization: Bearer $API_KEY" | jq '.post')
        
        # Check if we already responded
        COMMENTS=$(curl -s "https://www.moltbook.com/api/v1/posts/$post_id/comments" \
            -H "Authorization: Bearer $API_KEY" | jq '.comments')
        
        ALREADY_RESPONDED=$(echo "$COMMENTS" | jq "[.[] | select(.author.name == \"$AGENT_NAME\")] | length")
        
        if [ "$ALREADY_RESPONDED" != "0" ]; then
            echo "Already responded to: $title"
            continue
        fi
        
        echo "Processing: $title"
        process_handshake "$post_id" "$FULL_POST"
        echo ""
    fi
done

echo -e "${GREEN}Done polling.${NC}"
