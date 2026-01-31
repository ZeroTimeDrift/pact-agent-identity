#!/usr/bin/env python3
"""
Handshake Protocol - Secure Capability Exchange

Implements the HELLO → MANIFEST → VERIFY → AGREE protocol.
"""

import uuid
import json
from datetime import datetime, timezone, timedelta
from typing import Optional, Dict, List, Any
from dataclasses import dataclass, field
from enum import Enum

from .manifest import AgentManifest
from .signature import verify_manifest, TrustLevel, compute_hash


class MessageType(Enum):
    """Handshake message types."""
    HELLO = "HELLO"
    HELLO_RESPONSE = "HELLO_RESPONSE"
    MANIFEST = "MANIFEST"
    AGREE = "AGREE"
    REJECT = "REJECT"
    REVOKE = "REVOKE"


@dataclass
class HandshakeMessage:
    """A message in the handshake protocol."""
    type: MessageType
    version: str = "0.1.0"
    from_agent: str = ""
    to_agent: str = ""
    nonce: str = field(default_factory=lambda: str(uuid.uuid4()))
    timestamp: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    payload: Dict[str, Any] = field(default_factory=dict)
    signature: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "type": self.type.value,
            "version": self.version,
            "from": self.from_agent,
            "to": self.to_agent,
            "nonce": self.nonce,
            "timestamp": self.timestamp,
            "payload": self.payload,
            "signature": self.signature,
        }
    
    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2)
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'HandshakeMessage':
        return cls(
            type=MessageType(data["type"]),
            version=data.get("version", "0.1.0"),
            from_agent=data.get("from", ""),
            to_agent=data.get("to", ""),
            nonce=data.get("nonce", ""),
            timestamp=data.get("timestamp", ""),
            payload=data.get("payload", {}),
            signature=data.get("signature"),
        )
    
    def sign(self, content_hash: str):
        """Sign this message."""
        self.signature = content_hash


@dataclass
class CollaborationSession:
    """An active collaboration session."""
    session_id: str
    initiator: str
    responder: str
    purpose: str
    granted_scope: List[str]
    terms: Dict[str, Any]
    created_at: str
    expires_at: Optional[str] = None
    revoked: bool = False
    
    def is_valid(self) -> bool:
        """Check if session is still valid."""
        if self.revoked:
            return False
        if self.expires_at:
            expires = datetime.fromisoformat(self.expires_at.replace('Z', '+00:00'))
            if datetime.now(timezone.utc) > expires:
                return False
        return True


class HandshakeProtocol:
    """
    Implements the agent handshake protocol.
    
    Usage:
        protocol = HandshakeProtocol(my_manifest)
        
        # Initiating a handshake
        hello = protocol.create_hello("other_agent", "security audit", ["code_review"])
        # Send hello via transport...
        
        # Receiving a response
        response = HandshakeMessage.from_dict(received_data)
        if protocol.handle_message(response):
            # Handshake progressing...
    """
    
    def __init__(self, my_manifest: AgentManifest):
        self.my_manifest = my_manifest
        self.pending_handshakes: Dict[str, Dict] = {}  # nonce -> state
        self.active_sessions: Dict[str, CollaborationSession] = {}
        
    def create_hello(
        self,
        to_agent: str,
        purpose: str,
        requested_capabilities: Optional[List[str]] = None,
    ) -> HandshakeMessage:
        """Create a HELLO message to initiate handshake."""
        msg = HandshakeMessage(
            type=MessageType.HELLO,
            from_agent=self.my_manifest.agent_name,
            to_agent=to_agent,
            payload={
                "purpose": purpose,
                "requested_capabilities": requested_capabilities or [],
            },
        )
        
        # Track pending handshake
        self.pending_handshakes[msg.nonce] = {
            "to_agent": to_agent,
            "purpose": purpose,
            "state": "hello_sent",
            "created_at": msg.timestamp,
        }
        
        return msg
    
    def handle_hello(
        self,
        msg: HandshakeMessage,
        accept: bool = True,
    ) -> HandshakeMessage:
        """
        Handle an incoming HELLO message.
        
        Returns HELLO_RESPONSE with our manifest (if accepting) or REJECT.
        """
        if not accept:
            return HandshakeMessage(
                type=MessageType.REJECT,
                from_agent=self.my_manifest.agent_name,
                to_agent=msg.from_agent,
                payload={
                    "in_reply_to": msg.nonce,
                    "reason": "Handshake declined",
                },
            )
        
        # Create partial manifest based on requested capabilities
        requested = msg.payload.get("requested_capabilities", [])
        if requested:
            partial = self.my_manifest.partial(tools=requested, domains=requested)
        else:
            partial = self.my_manifest
        
        response = HandshakeMessage(
            type=MessageType.HELLO_RESPONSE,
            from_agent=self.my_manifest.agent_name,
            to_agent=msg.from_agent,
            payload={
                "in_reply_to": msg.nonce,
                "manifest": partial.to_dict(),
            },
        )
        
        # Track this handshake
        self.pending_handshakes[response.nonce] = {
            "from_agent": msg.from_agent,
            "purpose": msg.payload.get("purpose"),
            "state": "hello_responded",
            "their_nonce": msg.nonce,
            "created_at": response.timestamp,
        }
        
        return response
    
    def create_manifest_message(
        self,
        to_agent: str,
        in_reply_to: str,
        share_capabilities: Optional[List[str]] = None,
        scope_request: Optional[List[str]] = None,
    ) -> HandshakeMessage:
        """Create a MANIFEST message with our capabilities."""
        if share_capabilities:
            manifest = self.my_manifest.partial(tools=share_capabilities, domains=share_capabilities)
        else:
            manifest = self.my_manifest
        
        return HandshakeMessage(
            type=MessageType.MANIFEST,
            from_agent=self.my_manifest.agent_name,
            to_agent=to_agent,
            payload={
                "in_reply_to": in_reply_to,
                "manifest": manifest.to_dict(),
                "scope_request": scope_request or [],
            },
        )
    
    def handle_manifest(
        self,
        msg: HandshakeMessage,
        moltbook_api_key: Optional[str] = None,
    ) -> tuple[bool, 'VerificationResult', Optional[HandshakeMessage]]:
        """
        Handle an incoming MANIFEST message.
        
        Verifies the manifest and returns (success, verification_result, agree_message).
        """
        from .signature import verify_manifest
        
        manifest_dict = msg.payload.get("manifest", {})
        result = verify_manifest(manifest_dict, moltbook_api_key)
        
        if not result.valid:
            reject = HandshakeMessage(
                type=MessageType.REJECT,
                from_agent=self.my_manifest.agent_name,
                to_agent=msg.from_agent,
                payload={
                    "in_reply_to": msg.nonce,
                    "reason": "Manifest verification failed",
                    "errors": result.errors,
                },
            )
            return False, result, reject
        
        # Manifest verified - update pending state
        nonce = msg.payload.get("in_reply_to")
        if nonce in self.pending_handshakes:
            self.pending_handshakes[nonce]["their_manifest"] = manifest_dict
            self.pending_handshakes[nonce]["state"] = "manifest_received"
        
        return True, result, None
    
    def create_agree(
        self,
        to_agent: str,
        in_reply_to: str,
        granted_scope: List[str],
        duration_hours: int = 24,
        terms: Optional[Dict] = None,
    ) -> tuple[HandshakeMessage, CollaborationSession]:
        """Create an AGREE message to finalize handshake."""
        session_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc)
        expires = now + timedelta(hours=duration_hours)
        
        session = CollaborationSession(
            session_id=session_id,
            initiator=self.my_manifest.agent_name,
            responder=to_agent,
            purpose=self.pending_handshakes.get(in_reply_to, {}).get("purpose", ""),
            granted_scope=granted_scope,
            terms=terms or {},
            created_at=now.isoformat(),
            expires_at=expires.isoformat(),
        )
        
        msg = HandshakeMessage(
            type=MessageType.AGREE,
            from_agent=self.my_manifest.agent_name,
            to_agent=to_agent,
            payload={
                "in_reply_to": in_reply_to,
                "session_id": session_id,
                "granted_scope": granted_scope,
                "terms": {
                    "duration_hours": duration_hours,
                    "revocable": True,
                    "attribution": terms.get("attribution", "optional") if terms else "optional",
                },
                "expires_at": expires.isoformat(),
            },
        )
        
        # Store active session
        self.active_sessions[session_id] = session
        
        return msg, session
    
    def create_revoke(self, session_id: str, reason: str = "Session ended") -> HandshakeMessage:
        """Create a REVOKE message to end a collaboration."""
        session = self.active_sessions.get(session_id)
        if session:
            session.revoked = True
            to_agent = session.responder if session.initiator == self.my_manifest.agent_name else session.initiator
        else:
            to_agent = "unknown"
        
        return HandshakeMessage(
            type=MessageType.REVOKE,
            from_agent=self.my_manifest.agent_name,
            to_agent=to_agent,
            payload={
                "session_id": session_id,
                "reason": reason,
            },
        )
    
    def get_session(self, session_id: str) -> Optional[CollaborationSession]:
        """Get an active session by ID."""
        session = self.active_sessions.get(session_id)
        if session and session.is_valid():
            return session
        return None


if __name__ == "__main__":
    # Example usage
    from .manifest import AgentManifest
    
    # Create my manifest
    my_manifest = AgentManifest("Prometheus_", "karakcapital")
    my_manifest.add_tool("code_review")
    my_manifest.add_domain("security")
    
    # Initialize protocol
    protocol = HandshakeProtocol(my_manifest)
    
    # Create a hello
    hello = protocol.create_hello(
        "eudaemon_0",
        purpose="security audit collaboration",
        requested_capabilities=["security_analysis"],
    )
    
    print("HELLO message:")
    print(hello.to_json())
