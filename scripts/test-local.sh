#!/bin/bash
# test-local.sh — Test Pact handshake locally between two agents
#
# Usage: ./test-local.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

echo "🔐 Pact Local Handshake Test"
echo "============================"
echo ""

python3 << EOF
import sys
from pathlib import Path
sys.path.insert(0, "$LIB_DIR")

from keys import AgentKeys
from protocol import SecureHandshake, SignedMessage

# Setup temp directories
alice_dir = Path("/tmp/pact_test_alice")
bob_dir = Path("/tmp/pact_test_bob")
alice_dir.mkdir(parents=True, exist_ok=True)
bob_dir.mkdir(parents=True, exist_ok=True)

# Generate fresh keys
print("Setting up test agents...")
alice_keys = AgentKeys.generate()
alice_keys.save(alice_dir / "keys.json")

bob_keys = AgentKeys.generate()
bob_keys.save(bob_dir / "keys.json")

print(f"  Alice: {alice_keys.public_key_base58}")
print(f"  Bob:   {bob_keys.public_key_base58}")
print()

# Create handshake instances
alice = SecureHandshake("Alice", alice_keys)
bob = SecureHandshake("Bob", bob_keys)

# Step 1: Alice sends HELLO
print("─" * 50)
print("1. Alice → Bob: HELLO")
hello = alice.create_hello("Bob", "local test")
print(f"   ✓ Created and signed")

# Step 2: Bob receives and verifies
print("─" * 50)
print("2. Bob verifies Alice's signature")
received = SignedMessage.from_json(hello.to_json())
if not received.verify():
    print("   ✗ FAILED")
    sys.exit(1)
print(f"   ✓ Valid signature from Alice")

# Bob responds
response = bob.handle_hello(received)
print(f"   ✓ Bob created HELLO_RESPONSE")

# Step 3: Alice verifies Bob's response
print("─" * 50)
print("3. Alice verifies Bob's signature")
received_resp = SignedMessage.from_json(response.to_json())
if not received_resp.verify():
    print("   ✗ FAILED")
    sys.exit(1)
print(f"   ✓ Valid signature from Bob")

# Step 4: Create session
print("─" * 50)
print("4. Session established")
agree, session = alice.create_agree(
    to_agent="Bob",
    their_public_key=bob_keys.public_key_base58,
    purpose="local test",
    our_scope=["all"],
    their_scope=["all"],
    duration_hours=48
)
print(f"   Session: {session.session_id[:16]}...")
print(f"   Expires: {session.expires_at}")

# Done
print()
print("═" * 50)
print("🤝 HANDSHAKE COMPLETE")
print("═" * 50)
print(f"  Alice ↔ Bob: Mutually verified")
print(f"  Crypto: Ed25519")
print(f"  Session: 48h")
print()
print("Test passed. ✓")
EOF
