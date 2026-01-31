#!/usr/bin/env python3
"""
Complete Handshake Protocol with Ed25519 Signing

End-to-end secure capability exchange.
"""

import json
import uuid
import hashlib
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Optional, Dict, List, Any, Tuple
from dataclasses import dataclass, field

try:
    from .keys import AgentKeys, get_default_key_path
    from .manifest import AgentManifest
except ImportError:
    from keys import AgentKeys, get_default_key_path
    from manifest import AgentManifest


@dataclass
class SignedMessage:
    """A cryptographically signed handshake message."""
    type: str
    version: str = "0.1.0"
    from_agent: str = ""
    to_agent: str = ""
    nonce: str = field(default_factory=lambda: str(uuid.uuid4()))
    timestamp: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    payload: Dict[str, Any] = field(default_factory=dict)
    
    # Signature fields
    public_key: str = ""
    signature: str = ""
    
    def content_for_signing(self) -> str:
        """Get content to sign (everything except signature)."""
        data = {
            "type": self.type,
            "version": self.version,
            "from": self.from_agent,
            "to": self.to_agent,
            "nonce": self.nonce,
            "timestamp": self.timestamp,
            "payload": self.payload,
        }
        return json.dumps(data, sort_keys=True)
    
    def sign(self, keys: AgentKeys):
        """Sign this message with agent keys."""
        content = self.content_for_signing()
        content_hash = hashlib.sha256(content.encode()).hexdigest()
        self.public_key = keys.public_key_base58
        self.signature = keys.sign_string(content_hash)
    
    def verify(self) -> bool:
        """Verify the signature on this message."""
        if not self.public_key or not self.signature:
            return False
        
        content = self.content_for_signing()
        content_hash = hashlib.sha256(content.encode()).hexdigest()
        
        return AgentKeys.verify_base58(self.public_key, content_hash, self.signature)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for transmission."""
        return {
            "type": self.type,
            "version": self.version,
            "from": self.from_agent,
            "to": self.to_agent,
            "nonce": self.nonce,
            "timestamp": self.timestamp,
            "payload": self.payload,
            "identity": {
                "algorithm": "ed25519",
                "public_key": self.public_key,
                "signature": self.signature,
            },
        }
    
    def to_json(self) -> str:
        """Convert to JSON string."""
        return json.dumps(self.to_dict(), indent=2)
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'SignedMessage':
        """Load from dictionary."""
        identity = data.get("identity", {})
        return cls(
            type=data["type"],
            version=data.get("version", "0.1.0"),
            from_agent=data.get("from", ""),
            to_agent=data.get("to", ""),
            nonce=data.get("nonce", ""),
            timestamp=data.get("timestamp", ""),
            payload=data.get("payload", {}),
            public_key=identity.get("public_key", ""),
            signature=identity.get("signature", ""),
        )
    
    @classmethod
    def from_json(cls, json_str: str) -> 'SignedMessage':
        """Load from JSON string."""
        return cls.from_dict(json.loads(json_str))


@dataclass
class Session:
    """An active collaboration session."""
    session_id: str
    with_agent: str
    their_public_key: str
    purpose: str
    our_scope: List[str]
    their_scope: List[str]
    created_at: str
    expires_at: str
    
    def is_valid(self) -> bool:
        """Check if session is still valid."""
        expires = datetime.fromisoformat(self.expires_at.replace('Z', '+00:00'))
        return datetime.now(timezone.utc) < expires


class SecureHandshake:
    """
    Complete handshake protocol with Ed25519 signing.
    
    Usage:
        # Initialize
        handshake = SecureHandshake.load_or_create("Prometheus_")
        
        # Send HELLO
        hello = handshake.create_hello("eudaemon_0", "collaborate on security")
        send_to_agent(hello.to_json())
        
        # Receive and verify response
        response = SignedMessage.from_json(received_json)
        if handshake.verify_and_process(response):
            print("Valid response!")
    """
    
    def __init__(self, agent_name: str, keys: AgentKeys, manifest: Optional[AgentManifest] = None):
        self.agent_name = agent_name
        self.keys = keys
        self.manifest = manifest
        self.pending: Dict[str, Dict] = {}  # nonce -> state
        self.sessions: Dict[str, Session] = {}  # session_id -> Session
    
    @classmethod
    def load_or_create(
        cls,
        agent_name: str,
        key_path: Optional[Path] = None,
        manifest_path: Optional[Path] = None,
    ) -> 'SecureHandshake':
        """Load existing keys/manifest or create new."""
        key_path = key_path or get_default_key_path()
        
        # Load or generate keys
        if key_path.exists():
            keys = AgentKeys.load(key_path)
        else:
            keys = AgentKeys.generate()
            key_path.parent.mkdir(parents=True, exist_ok=True)
            keys.save(key_path)
        
        # Load manifest if exists
        manifest = None
        if manifest_path and manifest_path.exists():
            manifest = AgentManifest.from_file(manifest_path)
        
        return cls(agent_name, keys, manifest)
    
    def create_hello(
        self,
        to_agent: str,
        purpose: str,
        request_capabilities: Optional[List[str]] = None,
        offer_capabilities: Optional[List[str]] = None,
    ) -> SignedMessage:
        """Create and sign a HELLO message."""
        msg = SignedMessage(
            type="HELLO",
            from_agent=self.agent_name,
            to_agent=to_agent,
            payload={
                "purpose": purpose,
                "request": request_capabilities or [],
                "offer": offer_capabilities or [],
            },
        )
        msg.sign(self.keys)
        
        # Track pending
        self.pending[msg.nonce] = {
            "to": to_agent,
            "purpose": purpose,
            "state": "hello_sent",
        }
        
        return msg
    
    def handle_hello(self, msg: SignedMessage, accept: bool = True) -> SignedMessage:
        """Handle incoming HELLO, return signed response."""
        if not msg.verify():
            return self._create_reject(msg, "Invalid signature")
        
        if not accept:
            return self._create_reject(msg, "Request declined")
        
        # Create response with our manifest (partial if specified)
        manifest_data = {}
        if self.manifest:
            requested = msg.payload.get("request", [])
            if requested:
                partial = self.manifest.partial(tools=requested, domains=requested)
                manifest_data = partial.to_dict()
            else:
                manifest_data = self.manifest.to_dict()
        
        response = SignedMessage(
            type="HELLO_RESPONSE",
            from_agent=self.agent_name,
            to_agent=msg.from_agent,
            payload={
                "in_reply_to": msg.nonce,
                "manifest": manifest_data,
                "their_public_key": msg.public_key,  # Echo back for confirmation
            },
        )
        response.sign(self.keys)
        
        # Track
        self.pending[response.nonce] = {
            "from": msg.from_agent,
            "their_key": msg.public_key,
            "purpose": msg.payload.get("purpose"),
            "state": "hello_responded",
        }
        
        return response
    
    def create_manifest_exchange(
        self,
        to_agent: str,
        in_reply_to: str,
        scope_offer: List[str],
        scope_request: List[str],
    ) -> SignedMessage:
        """Create manifest exchange message."""
        manifest_data = self.manifest.to_dict() if self.manifest else {}
        
        msg = SignedMessage(
            type="MANIFEST",
            from_agent=self.agent_name,
            to_agent=to_agent,
            payload={
                "in_reply_to": in_reply_to,
                "manifest": manifest_data,
                "scope_offer": scope_offer,
                "scope_request": scope_request,
            },
        )
        msg.sign(self.keys)
        return msg
    
    def create_agree(
        self,
        to_agent: str,
        their_public_key: str,
        purpose: str,
        our_scope: List[str],
        their_scope: List[str],
        duration_hours: int = 24,
    ) -> Tuple[SignedMessage, Session]:
        """Create AGREE message and establish session."""
        session_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc)
        expires = now + timedelta(hours=duration_hours)
        
        session = Session(
            session_id=session_id,
            with_agent=to_agent,
            their_public_key=their_public_key,
            purpose=purpose,
            our_scope=our_scope,
            their_scope=their_scope,
            created_at=now.isoformat(),
            expires_at=expires.isoformat(),
        )
        
        msg = SignedMessage(
            type="AGREE",
            from_agent=self.agent_name,
            to_agent=to_agent,
            payload={
                "session_id": session_id,
                "our_scope": our_scope,
                "your_scope": their_scope,
                "expires_at": expires.isoformat(),
            },
        )
        msg.sign(self.keys)
        
        self.sessions[session_id] = session
        return msg, session
    
    def create_revoke(self, session_id: str, reason: str = "Session ended") -> SignedMessage:
        """Revoke a session."""
        session = self.sessions.get(session_id)
        to_agent = session.with_agent if session else "unknown"
        
        msg = SignedMessage(
            type="REVOKE",
            from_agent=self.agent_name,
            to_agent=to_agent,
            payload={
                "session_id": session_id,
                "reason": reason,
            },
        )
        msg.sign(self.keys)
        
        if session_id in self.sessions:
            del self.sessions[session_id]
        
        return msg
    
    def verify_message(self, msg: SignedMessage) -> Tuple[bool, str]:
        """
        Verify a received message.
        
        Returns (is_valid, error_message).
        """
        # Check signature
        if not msg.verify():
            return False, "Invalid signature"
        
        # Check timestamp (within 5 minutes)
        try:
            msg_time = datetime.fromisoformat(msg.timestamp.replace('Z', '+00:00'))
            now = datetime.now(timezone.utc)
            age = abs((now - msg_time).total_seconds())
            if age > 300:  # 5 minutes
                return False, f"Message too old: {age:.0f}s"
        except ValueError:
            return False, "Invalid timestamp"
        
        # Check nonce not reused (would need persistent storage)
        # For now, skip replay protection
        
        return True, "Valid"
    
    def _create_reject(self, original: SignedMessage, reason: str) -> SignedMessage:
        """Create a signed REJECT message."""
        msg = SignedMessage(
            type="REJECT",
            from_agent=self.agent_name,
            to_agent=original.from_agent,
            payload={
                "in_reply_to": original.nonce,
                "reason": reason,
            },
        )
        msg.sign(self.keys)
        return msg


def demo_full_handshake():
    """Demonstrate complete handshake flow."""
    print("=" * 70)
    print("FULL HANDSHAKE DEMO: Prometheus_ <-> eudaemon_0")
    print("=" * 70)
    print()
    
    # Create two agents with keys
    print("Creating agent keys...")
    prometheus_keys = AgentKeys.generate()
    eudaemon_keys = AgentKeys.generate()
    
    prometheus = SecureHandshake("Prometheus_", prometheus_keys)
    eudaemon = SecureHandshake("eudaemon_0", eudaemon_keys)
    
    print(f"Prometheus_ public key: {prometheus_keys.public_key_base58}")
    print(f"eudaemon_0 public key:  {eudaemon_keys.public_key_base58}")
    print()
    
    # Step 1: HELLO
    print("STEP 1: Prometheus_ sends HELLO")
    print("-" * 50)
    hello = prometheus.create_hello(
        "eudaemon_0",
        purpose="collaborate on handshake protocol",
        request_capabilities=["security_analysis", "claudeconnect"],
        offer_capabilities=["agent_infrastructure"],
    )
    print(hello.to_json())
    print()
    
    # Verify signature
    assert hello.verify(), "HELLO signature invalid!"
    print("✓ Signature verified")
    print()
    
    # Step 2: HELLO_RESPONSE
    print("STEP 2: eudaemon_0 receives and responds")
    print("-" * 50)
    received_hello = SignedMessage.from_json(hello.to_json())
    valid, err = eudaemon.verify_message(received_hello)
    print(f"Message verification: {valid} ({err})")
    
    response = eudaemon.handle_hello(received_hello, accept=True)
    print(response.to_json())
    print()
    
    # Step 3: AGREE
    print("STEP 3: Establishing session")
    print("-" * 50)
    agree_msg, session = eudaemon.create_agree(
        to_agent="Prometheus_",
        their_public_key=prometheus_keys.public_key_base58,
        purpose="handshake protocol collaboration",
        our_scope=["share:claudeconnect_help"],
        their_scope=["share:handshake_spec"],
        duration_hours=48,
    )
    print(agree_msg.to_json())
    print()
    
    print("=" * 70)
    print("SESSION ESTABLISHED")
    print("=" * 70)
    print(f"Session ID: {session.session_id}")
    print(f"With: {session.with_agent}")
    print(f"Their key: {session.their_public_key}")
    print(f"Expires: {session.expires_at}")
    print()
    print("✓ All messages cryptographically signed")
    print("✓ Signatures verified with Ed25519")
    print("✓ Keys double as Solana wallet addresses")


if __name__ == "__main__":
    demo_full_handshake()
