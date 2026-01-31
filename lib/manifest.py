#!/usr/bin/env python3
"""
Agent Manifest - Generation and Parsing

Create, load, and validate agent capability manifests.
"""

import json
import yaml
import hashlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Dict, List, Any


class AgentManifest:
    """Represents an agent capability manifest."""
    
    VERSION = "0.1.0"
    SCHEMA_URI = "https://agentmanifest.org/schema/v0.1"
    
    def __init__(
        self,
        agent_name: str,
        human_handle: str,
        capabilities: Optional[Dict] = None,
        platform: str = "moltbook",
        claimed_at: Optional[str] = None,
    ):
        self.agent_name = agent_name
        self.human_handle = human_handle
        self.platform = platform
        self.claimed_at = claimed_at or datetime.now(timezone.utc).isoformat()
        self.capabilities = capabilities or {}
        self.trust_vouches: List[Dict] = []
        self.manifest_version = 1
        self.previous_hash: Optional[str] = None
        self._signature: Optional[Dict] = None
        
    def to_dict(self, include_signature: bool = True) -> Dict[str, Any]:
        """Convert manifest to dictionary."""
        data = {
            "version": self.VERSION,
            "schema": self.SCHEMA_URI,
            "agent": {
                "name": self.agent_name,
                "platform": self.platform,
                "profile": f"https://moltbook.com/u/{self.agent_name}",
            },
            "human": {
                "x_handle": self.human_handle,
                "claimed_at": self.claimed_at,
            },
            "capabilities": self.capabilities,
            "trust": {
                "root": {
                    "type": "moltbook_claim",
                    "human": self.human_handle,
                    "verified_at": self.claimed_at,
                },
                "vouches": self.trust_vouches,
            },
            "manifest": {
                "version": self.manifest_version,
                "updated_at": datetime.now(timezone.utc).isoformat(),
                "previous_hash": self.previous_hash,
            },
        }
        
        if include_signature and self._signature:
            data["signature"] = self._signature
            
        return data
    
    def to_yaml(self, include_signature: bool = True) -> str:
        """Convert manifest to YAML string."""
        return yaml.dump(
            self.to_dict(include_signature),
            default_flow_style=False,
            sort_keys=False,
            allow_unicode=True,
        )
    
    def to_json(self, include_signature: bool = True) -> str:
        """Convert manifest to JSON string."""
        return json.dumps(self.to_dict(include_signature), indent=2)
    
    def content_hash(self) -> str:
        """Compute SHA256 hash of manifest content (excluding signature)."""
        content = self.to_yaml(include_signature=False)
        hash_bytes = hashlib.sha256(content.encode('utf-8')).hexdigest()
        return f"sha256:{hash_bytes}"
    
    def set_signature(self, signed_by: str, proof_url: Optional[str] = None):
        """Set the signature block."""
        self._signature = {
            "algorithm": "sha256",
            "content_hash": self.content_hash(),
            "signed_by": signed_by,
            "signed_at": datetime.now(timezone.utc).isoformat(),
            "proof": proof_url,
        }
        
    def add_vouch(self, agent: str, vouch_type: str, capability: Optional[str] = None):
        """Add a vouch from another agent."""
        vouch = {
            "agent": agent,
            "type": vouch_type,
            "vouched_at": datetime.now(timezone.utc).isoformat(),
        }
        if capability:
            vouch["capability"] = capability
        self.trust_vouches.append(vouch)
        
    def add_tool(self, tool_id: str, status: str = "active", **kwargs):
        """Add a tool capability."""
        if "tools" not in self.capabilities:
            self.capabilities["tools"] = []
        tool = {"id": tool_id, "status": status, **kwargs}
        self.capabilities["tools"].append(tool)
        
    def add_domain(self, domain: str):
        """Add a domain expertise."""
        if "domains" not in self.capabilities:
            self.capabilities["domains"] = []
        if domain not in self.capabilities["domains"]:
            self.capabilities["domains"].append(domain)
    
    def partial(self, tools: Optional[List[str]] = None, domains: Optional[List[str]] = None) -> 'AgentManifest':
        """Create a partial manifest with only specified capabilities."""
        partial_caps = {}
        
        if tools and "tools" in self.capabilities:
            partial_caps["tools"] = [
                t for t in self.capabilities["tools"]
                if t["id"] in tools
            ]
            
        if domains and "domains" in self.capabilities:
            partial_caps["domains"] = [
                d for d in self.capabilities["domains"]
                if d in domains
            ]
            
        partial = AgentManifest(
            agent_name=self.agent_name,
            human_handle=self.human_handle,
            capabilities=partial_caps,
            platform=self.platform,
            claimed_at=self.claimed_at,
        )
        partial._signature = self._signature
        return partial
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'AgentManifest':
        """Load manifest from dictionary."""
        manifest = cls(
            agent_name=data["agent"]["name"],
            human_handle=data["human"]["x_handle"],
            capabilities=data.get("capabilities", {}),
            platform=data["agent"].get("platform", "moltbook"),
            claimed_at=data["human"].get("claimed_at"),
        )
        
        if "trust" in data and "vouches" in data["trust"]:
            manifest.trust_vouches = data["trust"]["vouches"]
            
        if "manifest" in data:
            manifest.manifest_version = data["manifest"].get("version", 1)
            manifest.previous_hash = data["manifest"].get("previous_hash")
            
        if "signature" in data:
            manifest._signature = data["signature"]
            
        return manifest
    
    @classmethod
    def from_yaml(cls, yaml_str: str) -> 'AgentManifest':
        """Load manifest from YAML string."""
        data = yaml.safe_load(yaml_str)
        return cls.from_dict(data)
    
    @classmethod
    def from_file(cls, path: Path) -> 'AgentManifest':
        """Load manifest from file."""
        content = path.read_text()
        if path.suffix in ['.yaml', '.yml']:
            return cls.from_yaml(content)
        else:
            return cls.from_dict(json.loads(content))
    
    def save(self, path: Path):
        """Save manifest to file."""
        if path.suffix in ['.yaml', '.yml']:
            path.write_text(self.to_yaml())
        else:
            path.write_text(self.to_json())


def generate_from_config(
    agent_name: str,
    human_handle: str,
    tools: Optional[List[Dict]] = None,
    domains: Optional[List[str]] = None,
) -> AgentManifest:
    """Generate a manifest from configuration."""
    manifest = AgentManifest(agent_name, human_handle)
    
    if tools:
        for tool in tools:
            manifest.add_tool(**tool)
            
    if domains:
        for domain in domains:
            manifest.add_domain(domain)
            
    return manifest


if __name__ == "__main__":
    # Example usage
    manifest = AgentManifest(
        agent_name="Prometheus_",
        human_handle="karakcapital",
    )
    manifest.add_tool("web_search", provider="brave")
    manifest.add_tool("moltbook_api", scopes=["read", "post", "comment"])
    manifest.add_tool("github_cli", status="active")
    manifest.add_domain("crypto/fintech")
    manifest.add_domain("agent_infrastructure")
    
    print(manifest.to_yaml())
    print(f"\nContent hash: {manifest.content_hash()}")
