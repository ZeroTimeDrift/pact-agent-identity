#!/usr/bin/env python3
"""
Agent Keys - Ed25519 Identity & Wallet

Ed25519 keypair that works for:
- Signing handshake messages
- Solana wallet address

Same key format as Solana wallets.
"""

import os
import json
import hashlib
import base64
from pathlib import Path
from typing import Optional, Tuple
from dataclasses import dataclass

# Try to import cryptography library
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
    from cryptography.hazmat.primitives import serialization
    CRYPTO_AVAILABLE = True
except ImportError:
    CRYPTO_AVAILABLE = False

# Base58 alphabet (same as Bitcoin/Solana)
BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def base58_encode(data: bytes) -> str:
    """Encode bytes to base58 string (Solana format)."""
    num = int.from_bytes(data, 'big')
    encoded = ""
    while num > 0:
        num, remainder = divmod(num, 58)
        encoded = BASE58_ALPHABET[remainder] + encoded
    
    # Handle leading zeros
    for byte in data:
        if byte == 0:
            encoded = '1' + encoded
        else:
            break
    
    return encoded or '1'


def base58_decode(s: str) -> bytes:
    """Decode base58 string to bytes."""
    num = 0
    for char in s:
        num = num * 58 + BASE58_ALPHABET.index(char)
    
    # Calculate byte length
    byte_length = (num.bit_length() + 7) // 8
    
    # Handle leading '1's (zeros)
    leading_zeros = 0
    for char in s:
        if char == '1':
            leading_zeros += 1
        else:
            break
    
    return b'\x00' * leading_zeros + num.to_bytes(max(1, byte_length), 'big')


@dataclass
class AgentKeys:
    """
    Ed25519 keypair for agent identity.
    
    Public key is a valid Solana wallet address.
    """
    private_key_bytes: bytes  # 32 bytes
    public_key_bytes: bytes   # 32 bytes
    
    @property
    def public_key_base58(self) -> str:
        """Public key in Solana address format (base58)."""
        return base58_encode(self.public_key_bytes)
    
    @property
    def private_key_base58(self) -> str:
        """Private key in base58 format."""
        return base58_encode(self.private_key_bytes)
    
    @property
    def wallet_address(self) -> str:
        """Solana wallet address (same as public key)."""
        return self.public_key_base58
    
    def sign(self, message: bytes) -> bytes:
        """Sign a message with private key."""
        if not CRYPTO_AVAILABLE:
            raise ImportError("cryptography library required: pip install cryptography")
        
        private_key = Ed25519PrivateKey.from_private_bytes(self.private_key_bytes)
        return private_key.sign(message)
    
    def sign_string(self, message: str) -> str:
        """Sign a string message, return base64 signature."""
        sig_bytes = self.sign(message.encode('utf-8'))
        return base64.b64encode(sig_bytes).decode('ascii')
    
    @classmethod
    def verify(cls, public_key_bytes: bytes, message: bytes, signature: bytes) -> bool:
        """Verify a signature against a public key."""
        if not CRYPTO_AVAILABLE:
            raise ImportError("cryptography library required: pip install cryptography")
        
        try:
            public_key = Ed25519PublicKey.from_public_bytes(public_key_bytes)
            public_key.verify(signature, message)
            return True
        except Exception:
            return False
    
    @classmethod
    def verify_base58(cls, public_key_base58: str, message: str, signature_base64: str) -> bool:
        """Verify signature using base58 public key and base64 signature."""
        public_key_bytes = base58_decode(public_key_base58)
        message_bytes = message.encode('utf-8')
        signature_bytes = base64.b64decode(signature_base64)
        return cls.verify(public_key_bytes, message_bytes, signature_bytes)
    
    @classmethod
    def generate(cls) -> 'AgentKeys':
        """Generate a new Ed25519 keypair."""
        if not CRYPTO_AVAILABLE:
            raise ImportError("cryptography library required: pip install cryptography")
        
        private_key = Ed25519PrivateKey.generate()
        private_bytes = private_key.private_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PrivateFormat.Raw,
            encryption_algorithm=serialization.NoEncryption(),
        )
        public_bytes = private_key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        
        return cls(private_key_bytes=private_bytes, public_key_bytes=public_bytes)
    
    def save(self, path: Path, encrypt: bool = False):
        """
        Save keypair to file.
        
        WARNING: Private key is sensitive! Set appropriate permissions.
        """
        data = {
            "version": "0.1.0",
            "algorithm": "ed25519",
            "public_key": self.public_key_base58,
            "private_key": self.private_key_base58,  # TODO: encrypt this
            "wallet_address": self.wallet_address,
        }
        
        path.write_text(json.dumps(data, indent=2))
        
        # Set restrictive permissions (owner read/write only)
        os.chmod(path, 0o600)
    
    @classmethod
    def load(cls, path: Path) -> 'AgentKeys':
        """Load keypair from file."""
        data = json.loads(path.read_text())
        
        private_bytes = base58_decode(data["private_key"])
        public_bytes = base58_decode(data["public_key"])
        
        return cls(private_key_bytes=private_bytes, public_key_bytes=public_bytes)
    
    @classmethod
    def load_or_generate(cls, path: Path) -> Tuple['AgentKeys', bool]:
        """
        Load existing keys or generate new ones.
        
        Returns (keys, is_new).
        """
        if path.exists():
            return cls.load(path), False
        else:
            keys = cls.generate()
            keys.save(path)
            return keys, True
    
    def to_manifest_entry(self) -> dict:
        """
        Return data to include in manifest.
        
        Only includes PUBLIC key - never the private key!
        """
        return {
            "algorithm": "ed25519",
            "public_key": self.public_key_base58,
            "wallet_address": self.wallet_address,
        }


def get_default_key_path() -> Path:
    """Get default path for agent keys."""
    return Path.home() / ".config" / "agent-handshake" / "keys.json"


def sign_manifest(manifest_yaml: str, keys: AgentKeys) -> dict:
    """
    Sign a manifest and return signature block.
    """
    # Hash the content
    content_hash = hashlib.sha256(manifest_yaml.encode('utf-8')).hexdigest()
    
    # Sign the hash
    signature = keys.sign_string(content_hash)
    
    return {
        "algorithm": "ed25519",
        "content_hash": f"sha256:{content_hash}",
        "public_key": keys.public_key_base58,
        "signature": signature,
    }


def verify_manifest_signature(manifest_yaml: str, signature_block: dict) -> bool:
    """
    Verify a manifest signature.
    """
    # Compute content hash
    content_hash = hashlib.sha256(manifest_yaml.encode('utf-8')).hexdigest()
    expected_hash = f"sha256:{content_hash}"
    
    # Check hash matches
    if signature_block.get("content_hash") != expected_hash:
        return False
    
    # Verify signature
    return AgentKeys.verify_base58(
        signature_block["public_key"],
        content_hash,
        signature_block["signature"],
    )


if __name__ == "__main__":
    # Demo: Generate keys and sign a message
    print("Generating Ed25519 keypair...")
    keys = AgentKeys.generate()
    
    print(f"Public Key:     {keys.public_key_base58}")
    print(f"Wallet Address: {keys.wallet_address}")
    print(f"Private Key:    {keys.private_key_base58[:20]}... (truncated)")
    print()
    
    # Test signing
    message = "Hello from Prometheus_"
    signature = keys.sign_string(message)
    print(f"Message: {message}")
    print(f"Signature: {signature[:40]}...")
    
    # Verify
    valid = AgentKeys.verify_base58(keys.public_key_base58, message, signature)
    print(f"Verified: {valid}")
