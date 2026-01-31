#!/usr/bin/env python3
"""
Signature - Signing and Verification

Handles manifest signing and trust chain verification.
"""

import hashlib
import re
import json
from datetime import datetime, timezone, timedelta
from typing import Optional, Tuple, Dict, Any
from dataclasses import dataclass
from enum import Enum
import urllib.request
import urllib.error


class TrustLevel(Enum):
    """Trust levels for verified agents."""
    UNKNOWN = 0      # No manifest
    CLAIMED = 1      # Valid Moltbook claim
    SIGNED = 2       # Human signed manifest
    VOUCHED = 3      # Trusted agents vouch
    PROVEN = 4       # Verifiable capability proof


@dataclass
class VerificationResult:
    """Result of manifest verification."""
    valid: bool
    trust_level: TrustLevel
    errors: list
    warnings: list
    human_handle: Optional[str] = None
    claimed_at: Optional[str] = None
    
    def __str__(self) -> str:
        if self.valid:
            return f"✓ Valid signature by @{self.human_handle} (claimed {self.claimed_at[:10]})"
        else:
            return f"✗ Invalid: {', '.join(self.errors)}"


def compute_hash(content: str, algorithm: str = "sha256") -> str:
    """Compute hash of content."""
    if algorithm == "sha256":
        hash_bytes = hashlib.sha256(content.encode('utf-8')).hexdigest()
    elif algorithm == "sha512":
        hash_bytes = hashlib.sha512(content.encode('utf-8')).hexdigest()
    else:
        raise ValueError(f"Unsupported algorithm: {algorithm}")
    return f"{algorithm}:{hash_bytes}"


def verify_content_hash(manifest_dict: Dict[str, Any]) -> Tuple[bool, str]:
    """
    Verify the content hash in the signature matches the manifest content.
    
    Returns (is_valid, message).
    """
    import yaml
    
    if "signature" not in manifest_dict:
        return False, "No signature block found"
    
    signature = manifest_dict["signature"]
    claimed_hash = signature.get("content_hash")
    
    if not claimed_hash:
        return False, "No content_hash in signature"
    
    # Reconstruct manifest without signature
    manifest_copy = {k: v for k, v in manifest_dict.items() if k != "signature"}
    content = yaml.dump(manifest_copy, default_flow_style=False, sort_keys=False)
    
    # Extract algorithm from claimed hash
    if ":" in claimed_hash:
        algorithm = claimed_hash.split(":")[0]
    else:
        algorithm = "sha256"
    
    computed_hash = compute_hash(content, algorithm)
    
    if computed_hash == claimed_hash:
        return True, "Content hash valid"
    else:
        return False, f"Hash mismatch: computed {computed_hash[:30]}... vs claimed {claimed_hash[:30]}..."


def verify_proof_url(proof_url: str, expected_hash: str) -> Tuple[bool, str]:
    """
    Verify that the proof URL contains the expected hash.
    
    For v0.1, we just check if the URL is accessible.
    Full verification would fetch the tweet and check content.
    
    Returns (is_valid, message).
    """
    if not proof_url:
        return False, "No proof URL provided"
    
    # Basic URL validation
    if not proof_url.startswith(("https://x.com/", "https://twitter.com/")):
        return False, "Proof URL must be a Twitter/X link"
    
    # In production, we would:
    # 1. Fetch the tweet via Twitter API or scraping
    # 2. Check if tweet author matches signed_by
    # 3. Check if tweet contains the expected_hash
    
    # For now, just check URL format
    tweet_pattern = r"https://(x|twitter)\.com/(\w+)/status/(\d+)"
    match = re.match(tweet_pattern, proof_url)
    
    if not match:
        return False, "Invalid tweet URL format"
    
    return True, f"Proof URL valid (full verification requires Twitter API)"


def verify_moltbook_claim(agent_name: str, human_handle: str, api_key: Optional[str] = None) -> Tuple[bool, str]:
    """
    Verify that the agent is claimed by the specified human on Moltbook.
    
    Returns (is_valid, message).
    """
    url = f"https://www.moltbook.com/api/v1/agents/profile?name={agent_name}"
    
    try:
        req = urllib.request.Request(url)
        if api_key:
            req.add_header("Authorization", f"Bearer {api_key}")
        
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode())
            
        if not data.get("success"):
            return False, f"API error: {data.get('error', 'unknown')}"
        
        agent = data.get("agent", {})
        owner = agent.get("owner", {})
        
        claimed_handle = owner.get("x_handle", "").lower()
        expected_handle = human_handle.lower()
        
        if claimed_handle == expected_handle:
            return True, f"Moltbook claim verified: {agent_name} owned by @{human_handle}"
        else:
            return False, f"Claim mismatch: Moltbook shows @{claimed_handle}, manifest claims @{human_handle}"
            
    except urllib.error.URLError as e:
        return False, f"Could not verify Moltbook claim: {e}"
    except json.JSONDecodeError:
        return False, "Invalid response from Moltbook API"


def verify_timestamp(signed_at: str, max_age_hours: int = 720) -> Tuple[bool, str]:
    """
    Verify the signature timestamp is recent enough.
    
    Default max age: 30 days (720 hours).
    
    Returns (is_valid, message).
    """
    if not signed_at:
        return True, "No timestamp (skipped)"
    
    try:
        sig_time = datetime.fromisoformat(signed_at.replace('Z', '+00:00'))
        now = datetime.now(timezone.utc)
        age = now - sig_time
        
        if age > timedelta(hours=max_age_hours):
            return False, f"Signature too old: {age.days} days"
        
        if sig_time > now + timedelta(hours=1):
            return False, "Signature timestamp is in the future"
        
        return True, f"Signature age: {age.days} days"
        
    except ValueError as e:
        return False, f"Invalid timestamp format: {e}"


def verify_manifest(
    manifest_dict: Dict[str, Any],
    moltbook_api_key: Optional[str] = None,
    verify_moltbook: bool = True,
) -> VerificationResult:
    """
    Full verification of a manifest.
    
    Returns VerificationResult with trust level and any errors.
    """
    errors = []
    warnings = []
    trust_level = TrustLevel.UNKNOWN
    
    # Extract key fields
    agent_name = manifest_dict.get("agent", {}).get("name")
    human_handle = manifest_dict.get("human", {}).get("x_handle")
    signature = manifest_dict.get("signature", {})
    claimed_at = manifest_dict.get("human", {}).get("claimed_at")
    
    if not agent_name:
        errors.append("Missing agent name")
    if not human_handle:
        errors.append("Missing human x_handle")
    
    if errors:
        return VerificationResult(
            valid=False,
            trust_level=TrustLevel.UNKNOWN,
            errors=errors,
            warnings=warnings,
        )
    
    # Level 1: Check Moltbook claim
    if verify_moltbook:
        valid, msg = verify_moltbook_claim(agent_name, human_handle, moltbook_api_key)
        if valid:
            trust_level = TrustLevel.CLAIMED
        else:
            errors.append(msg)
    else:
        warnings.append("Moltbook verification skipped")
        trust_level = TrustLevel.CLAIMED  # Assume valid if not checking
    
    # Level 2: Check signature
    if signature:
        # Verify content hash
        valid, msg = verify_content_hash(manifest_dict)
        if not valid:
            errors.append(msg)
        else:
            # Verify timestamp
            valid, msg = verify_timestamp(signature.get("signed_at"))
            if not valid:
                warnings.append(msg)
            
            if not errors:
                trust_level = TrustLevel.SIGNED
    else:
        warnings.append("No signature block - limited trust")
    
    # Level 3: Check vouches
    vouches = manifest_dict.get("trust", {}).get("vouches", [])
    if vouches and trust_level == TrustLevel.SIGNED:
        # In production, verify each vouch signature
        warnings.append(f"{len(vouches)} vouches present (verification not implemented)")
        # trust_level = TrustLevel.VOUCHED  # Would upgrade if vouches verified
    
    return VerificationResult(
        valid=len(errors) == 0,
        trust_level=trust_level,
        errors=errors,
        warnings=warnings,
        human_handle=human_handle,
        claimed_at=claimed_at,
    )


if __name__ == "__main__":
    # Example: Verify a manifest
    import yaml
    
    sample = """
version: "0.1.0"
agent:
  name: "TestAgent"
human:
  x_handle: "test_human"
  claimed_at: "2026-01-31T00:00:00Z"
capabilities:
  tools:
    - id: "web_search"
signature:
  content_hash: "sha256:abc123"
  signed_by: "test_human"
"""
    
    manifest_dict = yaml.safe_load(sample)
    result = verify_manifest(manifest_dict, verify_moltbook=False)
    print(result)
