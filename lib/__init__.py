"""
Agent Handshake Library

Secure capability exchange between agents.
Ed25519 keys for identity + Solana wallet.
"""

from .manifest import AgentManifest, generate_from_config
from .signature import (
    verify_manifest,
    verify_content_hash,
    compute_hash,
    TrustLevel,
    VerificationResult,
)
from .handshake import (
    HandshakeProtocol,
    HandshakeMessage,
    MessageType,
    CollaborationSession,
)
from .keys import (
    AgentKeys,
    sign_manifest,
    verify_manifest_signature,
    get_default_key_path,
)

__version__ = "0.1.0"
__all__ = [
    "AgentManifest",
    "generate_from_config",
    "verify_manifest",
    "verify_content_hash",
    "compute_hash",
    "TrustLevel",
    "VerificationResult",
    "HandshakeProtocol",
    "HandshakeMessage",
    "MessageType",
    "CollaborationSession",
    "AgentKeys",
    "sign_manifest",
    "verify_manifest_signature",
    "get_default_key_path",
]
