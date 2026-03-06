# fabric-forge

Forge the fabric. One script, full stack.

Provisions a k3s cluster and deploys the Fabric-SDK runtime via Helm charts. Inspired by [StackForge](https://github.com/ry-ops/stackforge)'s guided bootstrap and [git-steer](https://github.com/git-fabric/git)'s file-based governance.

## What You Get

A running Fabric-SDK environment with every OSI layer deployed:

```
Layer | Component        | Chart/Manifest      | Status
------|------------------|---------------------|-------
L7    | Workers          | (fabric-managed)    | Via fabric apps
L6    | MCP Protocol     | fabric-aiana        | 11 tools
L5    | AIANA Memory     | fabric-aiana        | Qdrant Cloud
L4    | Interceptor/DNS  | fabric-gateway      | Route selection
L3    | Gateway/F-RIB    | fabric-gateway      | Redis-backed
L2    | Firewall         | fabric-gateway      | Injection/PII
L1    | Tailscale        | manifests/tailscale | Zero-trust mesh
```

## 30-Second Quickstart

```bash
git clone https://github.com/git-fabric/fabric-forge
cd fabric-forge
bash forge.sh
```

The script detects your environment (macOS/Docker Desktop uses k3d, Linux uses bare-metal k3s) and walks you through every step.

## What Gets Deployed

```
fabric-sdk namespace
  +-- ollama          CPU inference, qwen2.5-coder:3b, 10Gi model cache
  +-- redis           Route cache, session state, 1Gi persistent
  +-- fabric-gateway  F-RIB, interceptor, DNS, firewall, port 7340
  +-- fabric-aiana    11 MCP tools, Qdrant Cloud, AS65005, port 8100
```

## Prerequisites

- `curl`, `helm`, `kubectl`
- Docker Desktop (macOS/Windows) or Linux with root access
- Qdrant Cloud instance + API key (for AIANA)
- OpenAI API key (for embeddings)

## Secrets

Before AIANA deploys, create the required secret:

```bash
kubectl create secret generic aiana-secrets -n fabric-sdk \
  --from-literal=QDRANT_URL=https://your-instance.qdrant.io:6333 \
  --from-literal=QDRANT_API_KEY=your-qdrant-key \
  --from-literal=OPENAI_API_KEY=your-openai-key
```

Optional -- for Claude escalation via the gateway:

```bash
kubectl create secret generic gateway-secrets -n fabric-sdk \
  --from-literal=ANTHROPIC_API_KEY=your-anthropic-key
```

## Helm Charts

| Chart | Description | Default Port |
|-------|-------------|-------------|
| `charts/ollama` | Ollama local LLM with init container model pull | 11434 |
| `charts/redis` | Redis 7.2 Alpine with AOF persistence | 6379 |
| `charts/fabric-gateway` | SDK gateway with F-RIB, firewall, DNS | 7340 |
| `charts/fabric-aiana` | AIANA memory fabric, Qdrant-backed, AS65005 | 8100 |
| `charts/dashboard` | Control dashboard — OSI status, routing lanes, fabric registry | 32500 |

Each chart is independently installable:

```bash
helm upgrade --install ollama charts/ollama -n fabric-sdk
helm upgrade --install redis charts/redis -n fabric-sdk
helm upgrade --install fabric-gateway charts/fabric-gateway -n fabric-sdk
helm upgrade --install fabric-aiana charts/fabric-aiana -n fabric-sdk
helm upgrade --install fabric-dashboard charts/dashboard -n fabric-sdk
```

## Commands

```bash
bash forge.sh              # Full guided install
bash forge.sh --status     # Show cluster and pod status
bash forge.sh --destroy    # Tear down cluster and all state
bash forge.sh --kubeconfig # Print kubeconfig path
```

## Tailscale (L1)

Tailscale is deployed separately via the official Kubernetes operator. See `manifests/tailscale/tailscale.yaml` for instructions. Once deployed, annotate services to expose them on your tailnet:

```bash
kubectl annotate svc fabric-gateway -n fabric-sdk tailscale.com/expose="true"
kubectl annotate svc fabric-aiana -n fabric-sdk tailscale.com/expose="true"
```

## Architecture

This maps directly to the [Fabric-SDK](https://github.com/git-fabric/sdk) OSI model and network topology. fabric-forge is the deployment vehicle; the SDK repo is the source of truth for contracts and code.

## License

MIT
