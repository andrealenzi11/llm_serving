# llm_serving

Self-hosted LLM serving stack for open weights models, built with **vLLM** and **LiteLLM**.   
Designed for security, reliability, and ease of maintenance in production environments.   

---

## Architecture

```
                  ┌─────────────────────────────────────────────────────────┐
                  │  Docker host                                            │
                  │                                                         │
 Clients ────►  :4000 ──► LiteLLM ──────backend (internal)──────► vLLM      │
                  │      frontend          172.30.0.0/24         (GPU)      │
                  │    (non-internal)                              |        │
                  |    172.30.2.0/24                               |        │
                  │                                             egress      |
                  |                                         (non-internal)  │
                  │                                        172.30.1.0/24    │
                  │                                                │        │
                  └────────────────────────────────────────────────┼────────┘
                                                                   │
                                                             HuggingFace Hub
                                                       (model weight downloads)
```

| Service | Image | Role |
|---------|-------|------|
| **vLLM** | `vllm/vllm-openai:v0.20.0-cu130` | **OpenAI-compatible inference engine** serving the model set by `HF_MODEL_ID` with optional quantization and prefix caching. No published port — reachable only by LiteLLM via the internal `backend` network. |
| **LiteLLM** | `ghcr.io/berriai/litellm:v1.83.10-stable` | **API gateway** on port `4000`. Handles bearer-token authentication (`LITELLM_MASTER_KEY`), per-model concurrency gating (`max_parallel_requests: 4`), in-memory response caching (1 h TTL), and structured JSON logging with Docker log rotation. External access is rate-limited by the `DOCKER-USER` iptables chain. |

### Network isolation

| Network | Subnet | `internal` | Members | Purpose |
|---------|--------|------------|---------|---------|
| `frontend` | `172.30.2.0/24` | no | LiteLLM | Non-internal bridge required for Docker to wire the host-port `4000` NAT rule. |
| `backend` | `172.30.0.0/24` | yes | vLLM, LiteLLM | Internal bridge with no default gateway — containers cannot initiate internet connections through it. |
| `egress` | `172.30.1.0/24` | no | vLLM | Non-internal bridge — allows vLLM to download model weights from HuggingFace. |

LiteLLM is attached to `backend` (to reach vLLM) and to `frontend` (for the published-port NAT rule). vLLM is attached to `backend` and `egress`. LiteLLM has no `egress` attachment, limiting its outbound reach to what the host firewall allows.

---

## Project structure

```
.
├── conf/                  # configuration files for different environments
│   ├── .env                   # secrets (not committed — created from conf/.env.example)
│   └── .env.example           # template for all required and optional env variables
├── scripts/               # utility scripts for setup and maintenance
│   ├── download_model.sh      # utility to download model weights into the Docker volume
│   └── firewall.sh            # UFW + iptables DOCKER-USER chain setup
├── .gitignore             # ignores .env and other sensitive/generated files
├── docker-compose.yaml    # service orchestration (vLLM + LiteLLM, networks, volumes)
├── LICENSE                # project license
├── litellm_config.yaml    # LiteLLM routing, concurrency, caching, logging
├── README.md              # this file
└── version.txt            # project version
```

---

## Prerequisites

- Docker Engine ≥ 24 with the Compose plugin
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) installed and configured
- A HuggingFace account with access to your target model accepted (for gated repos)

---

## OS Dependencies Installation

### Docker Engine + Compose plugin

```bash
# Remove old versions
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Install prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

# Add Docker GPG key & repository
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Let your user run docker without sudo
sudo usermod -aG docker $USER
newgrp docker
```

### NVIDIA Container Toolkit

The NVIDIA Container Toolkit is **required** — it provides the runtime hook that exposes GPU devices inside Docker containers. Without it, `--gpus all` and the `deploy.resources.reservations.devices` directive in Compose won't work.

You do **not** need a host-level CUDA toolkit installation: the vLLM image ships its own CUDA libraries. The host only needs:

1. **NVIDIA GPU driver** (already installed if `nvidia-smi` works on the host)
2. **NVIDIA Container Toolkit** (bridges the driver into containers)

#### Check driver compatibility

```bash
nvidia-smi
# Look at "CUDA Version: XX.X" in the top-right corner of the output.
# The official vLLM images bundle CUDA 12.x.
# As long as your driver reports CUDA ≥ 12.0 (driver ≥ 525), the default image works.
```

#### Install the toolkit

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

#### Verify GPU access inside Docker

```bash
docker run --rm --gpus all nvidia/cuda:13.0.3-base-ubuntu24.04 nvidia-smi
```

---

## Firewall setup

The server uses **UFW** as the frontend and **iptables** as the backend. Because Docker manipulates `iptables` directly (bypassing UFW), the script also inserts rules in the `DOCKER-USER` chain to control access to published container ports.

```bash
sudo bash scripts/firewall.sh
```

What the script does:

| Layer | Rule | Purpose |
|-------|------|---------|
| UFW | `deny incoming` / `allow outgoing` | Default policy |
| UFW | `limit 22/tcp` | SSH access (rate-limited brute-force protection) |
| UFW | `allow 4000/tcp` | LiteLLM API |
| DOCKER-USER | `INVALID → DROP` | Drop malformed/orphaned packets (conntrack bypass prevention) |
| DOCKER-USER | `ESTABLISHED,RELATED → RETURN` | Allow return traffic for existing connections |
| DOCKER-USER | `lo → RETURN` | Allow host → container traffic via loopback |
| DOCKER-USER | `docker0 → RETURN` | Allow host → container traffic via the default bridge |
| DOCKER-USER | `br+ → br+ → RETURN` | Allow inter-container traffic across Docker bridges |
| DOCKER-USER | `br+ → !br+ → RETURN` | Allow container → internet traffic (model downloads) |
| DOCKER-USER | `tcp/4000 SYN hashlimit 30/s/IP → RETURN` | Per-source-IP rate-limited external access to LiteLLM |
| DOCKER-USER | `LOG` | Log dropped packets (rate-limited to 5/min to prevent log flooding) |
| DOCKER-USER | `DROP` | Block all other external → container traffic |

All rules are mirrored for both **IPv4** and **IPv6** (if Docker IPv6 is enabled).

**Persistence:** Rules survive reboots via `iptables-persistent` and Docker daemon restarts via a systemd `ExecStartPost` drop-in that re-runs the script with `--docker-user-only`.

---

## Fail2Ban (SSH brute-force protection)

Fail2Ban monitors log files and bans IPs that show repeated failed login attempts.

### Install

```bash
sudo apt-get update && sudo apt-get install -y fail2ban
```

### Configure the SSH jail

Create a local override (never edit the stock `jail.conf` — it gets overwritten on upgrades):

```bash
sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[sshd]
enabled   = true
port      = ssh
filter    = sshd
logpath   = /var/log/auth.log
backend   = systemd
maxretry  = 5
findtime  = 600
bantime   = 3600
EOF
```

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `maxretry` | `5` | Ban after 5 failed attempts |
| `findtime` | `600` | …within a 10-minute window |
| `bantime` | `3600` | Ban duration: 1 hour (`-1` = permanent) |

### Enable and start

```bash
sudo systemctl enable fail2ban
sudo systemctl restart fail2ban
```

### Verify

```bash
sudo fail2ban-client status sshd
```

---

## Quick start

#### 1. **Configure secrets** 

Copy the template and fill in the values:
```bash
cp conf/.env.example conf/.env   # or edit conf/.env directly
chmod 600 conf/.env               # restrict to owner-only (file contains secrets)
```

**Model configuration** (update all three together when switching models):

| Variable | Description |
|----------|-------------|
| `COMPOSE_PROJECT_NAME` | Fixed project name (`llm_serving`). Ensures volume/network names are stable regardless of clone path — protects the model cache from accidental re-download. |
| `HF_MODEL_ID` | Full HuggingFace model path (e.g. `org/model-name`). vLLM downloads and loads this model. |
| `MODEL_NAME` | Short served-model name exposed in the API (e.g. `my-model`). Clients use this in the `"model"` field of requests. |
| `LITELLM_MODEL` | LiteLLM routing key — must be `openai/` + `MODEL_NAME` (e.g. `openai/my-model`). The `openai/` prefix tells LiteLLM to use the OpenAI-compatible protocol. |

**Credentials** (required):

| Variable | Description |
|----------|-------------|
| `HF_TOKEN` | HuggingFace access token (required for gated models — accept the model licence first). |
| `LITELLM_MASTER_KEY` | Bearer token clients send to authenticate with the gateway. Generate with: `python3 -c "import secrets; print('sk-' + secrets.token_urlsafe(32))"` |
| `VLLM_API_KEY` | Internal key for LiteLLM → vLLM authentication (defense-in-depth, even on the internal network). Generate with: `python3 -c "import secrets; print('vllm-' + secrets.token_urlsafe(32))"` |

**vLLM inference parameters** (optional — defaults shown):

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_DTYPE` | `auto` | Weight and activation dtype (`auto`, `float16`, `bfloat16`, `float32`). |
| `VLLM_QUANTIZATION_ARG` | `--quantization nvfp4` | Full flag passed to vLLM; set to empty to disable quantization. |
| `VLLM_MAX_MODEL_LEN` | `8192` | Maximum context length in tokens (prompt + generation). |
| `VLLM_MAX_NUM_BATCHED_TOKENS` | `8192` | Maximum total tokens across all concurrent sequences in one scheduler step. |
| `VLLM_MAX_NUM_SEQS` | `256` | Maximum number of sequences processed concurrently. |
| `VLLM_GPU_MEMORY_UTILIZATION` | `0.82` | Fraction of GPU HBM reserved for the KV cache (`0.0`–`1.0`). |
| `VLLM_TENSOR_PARALLEL_ARG` | _(empty)_ | Set to `--tensor-parallel-size <n>` for multi-GPU; leave empty for single-GPU. |
| `VLLM_ENABLE_PREFIX_CACHING` | `--enable-prefix-caching` | Set to empty to disable prefix caching. |
| `VLLM_SHM_SIZE` | `16g` | Shared memory for NCCL; scale proportionally with tensor parallelism degree. |

**LiteLLM gateway parameters** (optional — defaults shown):

| Variable | Default | Description |
|----------|---------|-------------|
| `LITELLM_NUM_WORKERS` | `2` | Number of Uvicorn worker processes; increase for higher request concurrency. |

#### 2. **Set up the firewall** (before exposing any ports):
```bash
sudo bash scripts/firewall.sh
```

#### 3. **(Optional) Pre-download model weights** 

Download model weights from HuggingFace into the Docker volume to avoid the initial startup delay:
```bash
./scripts/download_model.sh
```


#### 4. **Start the stack:**
```bash
docker compose --env-file conf/.env up -d
```

#### 5. **Verify health:**
```bash
docker compose --env-file conf/.env ps      # both services should show "healthy"
docker compose --env-file conf/.env logs -f # watch startup progress
```

#### 6. **Test a request:**
```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<MODEL_NAME>",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

---

## Container hardening

Both containers are hardened beyond Docker defaults:

| Measure | vLLM | LiteLLM | Purpose |
|---------|------|---------|---------|
| `cap_drop: ALL` | ✓ | ✓ | Drop all Linux capabilities (GPU access is injected by the NVIDIA runtime). |
| `no-new-privileges` | ✓ | ✓ | Prevent setuid/setgid binaries from escalating privileges. |
| `read_only` | — | ✓ | Immutable root filesystem; only `/tmp` (tmpfs) is writable. |
| `tmpfs` | `/tmp` (1 GB) | `/tmp` (256 MB) | RAM-backed scratch space — avoids writes to the overlay layer. |
| `pids_limit` | 1024 | 256 | Fork-bomb protection. |
| Memory limit | 64 GB | 2 GB | Hard cap via `deploy.resources.limits`; prevents OOM-killing other host services. |
| Swap disabled | ✓ | — | `memswap_limit` equals memory limit — GPU workloads degrade severely on swap. |
| CPU limit | — | 2 cores | Prevents the gateway from starving vLLM or the host. |
| Log rotation | 50 MB × 3 | 50 MB × 5 | JSON-file driver with size caps; prevents disk exhaustion. |
| Port binding | none | IPv4 only | `0.0.0.0:4000` avoids the IPv6 bypass when Docker IPv6 is enabled. |

---

## Configuration notes

### vLLM (inference engine)

| Parameter | Default | Notes |
|-----------|---------|-------|
| `--model` | `${HF_MODEL_ID}` | Full HuggingFace model path. Set `HF_MODEL_ID` in `.env`; update `MODEL_NAME` and `LITELLM_MODEL` to match. |
| `--dtype` | `auto` | Weight precision. `auto` lets vLLM infer an appropriate dtype from model metadata. |
| `--quantization` | `nvfp4` | Selects quantization mode when supported by the chosen model. Reduces VRAM usage compared with full-precision variants. |
| `--max-model-len` | `8192` | Context window in tokens. Can be raised (e.g. `32768`, `131072`) at the cost of higher VRAM usage. |
| `--gpu-memory-utilization` | `0.90` | Fraction of VRAM vLLM pre-allocates for KV cache. |
| `--enable-prefix-caching` | enabled | Caches common prompt prefixes in GPU memory to avoid recomputation. |
| `TORCHINDUCTOR_CACHE_DIR` / `TRITON_CACHE_DIR` | `/root/.cache/vllm/...` | Relocates JIT-compiled kernels off `/tmp`, so Triton can load its generated `.so` files without making the general temp mount executable. |
| `shm_size` | `16g` | Shared memory for NCCL; avoids the security risk of `ipc: host`. |

### LiteLLM (gateway)

| Parameter | Default | Notes |
|-----------|---------|-------|
| `max_parallel_requests` | `4` | Maximum concurrent requests forwarded to vLLM simultaneously. |
| `cache` / `cache_params` | `true` / `local`, 1 h TTL | In-memory response cache. Identical requests are served without hitting the GPU. Set `cache: false` to disable. |
| `request_timeout` | `600` | Global fallback timeout in seconds for model requests. |
| `num_retries` | `2` | Automatic retries on transient vLLM errors (OOM, preemption). |
| `drop_params` | `true` | Silently discards unsupported parameters instead of returning 400. |
| `json_logs` | `true` | Structured JSON output for log aggregators (Loki, ELK). |
| `redact_messages_in_exceptions` | `true` | Strips prompt content from error messages and tracebacks. |

---

## Useful commands

```bash
# Stop the stack (preserves volumes)
docker compose --env-file conf/.env down

# Stop and delete the ~16 GB model cache (forces re-download on next start)
docker compose --env-file conf/.env down -v

# Pull latest images and restart
docker compose --env-file conf/.env pull && docker compose --env-file conf/.env up -d

# Follow logs for a specific service
docker compose --env-file conf/.env logs -f litellm
docker compose --env-file conf/.env logs -f vllm

# Check container resource usage
docker stats --no-stream

# Re-apply firewall rules after manual changes
sudo bash scripts/firewall.sh

# Re-apply only the DOCKER-USER iptables rules (same as the systemd drop-in)
sudo bash scripts/firewall.sh --docker-user-only
```
