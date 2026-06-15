# llm_serving

**Self-hosted LLM serving stack** for open weights models, built with **vLLM** (inference engine) and **LiteLLM** (API gateway).    
Designed for security, reliability, and ease of maintenance in production environments.   
This project is ideal for developers and organizations looking to deploy and serve large language models on their own infrastructure with fine-grained control.


## Architecture
```
               ┌──────────────────────────────────────────────────────────┐
               │ Docker host                                              │
               │                                                          │
 Clients ───► :4000 ───► frontend ───► LiteLLM ───► backend ───► vLLM     │   
               │      (non-internal)               (internal)     │       │
               │      172.30.2.0/24              172.30.0.0/24    |       │
               |                                                  |       │
               │                                                egress    |
               |                                           (non-internal) │
               │                                           172.30.1.0/24  │
               │                                                  │       │
               └──────────────────────────────────────────────────┼───────┘
                                                                  │
                                                           HuggingFace Hub
                                                       (model weight downloads)
```

### Services
| Service     | Image                                     | Role |
|-------------|-------------------------------------------|------|
| **vLLM**    | `vllm/vllm-openai:v0.23.0-cu130`          | **OpenAI-compatible inference engine** serving the model set by `HF_MODEL_ID` with optional quantization and prefix caching. No published port — reachable only by LiteLLM via the internal `backend` network. |
| **LiteLLM** | `ghcr.io/berriai/litellm:v1.88.2` | **API gateway** on port `4000`. Handles bearer-token authentication (`LITELLM_MASTER_KEY`), per-model concurrency gating (`max_parallel_requests: 4`), in-memory response caching (1 h TTL), and structured JSON logging with Docker log rotation. External access is rate-limited by the `DOCKER-USER` iptables chain. |

### Networks
| Network    | Subnet          | internal   | Members       | Purpose |
|------------|-----------------|------------|---------------|---------|
| `frontend` | `172.30.2.0/24` | no         | LiteLLM       | Non-internal bridge required for Docker to wire the host-port `4000` NAT rule. |
| `backend`  | `172.30.0.0/24` | yes        | vLLM, LiteLLM | Internal bridge with no default gateway — containers cannot initiate internet connections through it. |
| `egress`   | `172.30.1.0/24` | no         | vLLM          | Non-internal bridge — allows vLLM to download model weights from HuggingFace. |


## Project structure

```
.
├── conf/                  # configuration files for different environments
│   ├── .env                   
│   └── .env.example          
├── guides/                # setup and troubleshooting guides for dependencies
│   ├── docker.md             
│   ├── fail2ban.md           
│   ├── firewall_rules.md     
│   └── nvidia_container_toolkit.md 
├── scripts/               # utility scripts for setup and maintenance (downloads, firewall)
│   ├── download_model.sh
│   └── firewall.sh
├── .gitignore             # ignores .env and other sensitive/generated files
├── docker-compose.yaml    # service orchestration (vLLM + LiteLLM, networks, volumes)
├── LICENSE                # project license
├── litellm_config.yaml    # LiteLLM routing, concurrency, caching, logging
├── README.md              # this file
└── version.txt            # project version
```


## Prerequisites

- Docker Engine ≥ 24 with the Compose plugin [see guide](guides/docker.md) (required for containerization and orchestration).
- NVIDIA Container Toolkit installed and configured [see guide](guides/nvidia_container_toolkit.md) (required for GPU access inside containers).
- A HuggingFace account with access to your target model accepted (for gated repos). (required for model downloads — the vLLM container will fetch weights on startup).
- **[Optional]** Install Fail2Ban or a similar intrusion prevention system to monitor SSH logs and block malicious IPs [see guide](guides/fail2ban.md).
- **[Optional]** Set up firewall rules to restrict access to the API port and protect against network attacks [see guide](guides/firewall_rules.md).


## Quick start

### 1. **Configure secrets** 

Create `conf/.env` from the example and fill in the required values, and set restrictive permissions since it contains secrets.

```bash
cp conf/.env.example conf/.env  
chmod 600 conf/.env              
```

#### Model Configuration:
| Variable | Description |
|----------|-------------|
| `COMPOSE_PROJECT_NAME` | Fixed project name (`llm_serving`). Ensures volume/network names are stable regardless of clone path — protects the model cache from accidental re-download. |
| `HF_MODEL_ID` | Full HuggingFace model path (e.g. `org/model-name`). vLLM downloads and loads this model. |
| `MODEL_NAME` | Short served-model name exposed in the API (e.g. `my-model`). Clients use this in the `"model"` field of requests. |
| `LITELLM_MODEL` | LiteLLM routing key — must be `openai/` + `MODEL_NAME` (e.g. `openai/my-model`). The `openai/` prefix tells LiteLLM to use the OpenAI-compatible protocol. |

#### Credentials:
| Variable | Description |
|----------|-------------|
| `HF_TOKEN` | HuggingFace access token (required for gated models — accept the model licence first). |
| `LITELLM_MASTER_KEY` | Bearer token clients send to authenticate with the gateway. Generate with: `python3 -c "import secrets; print('sk-' + secrets.token_urlsafe(32))"` |
| `VLLM_API_KEY` | Internal key for LiteLLM → vLLM authentication (defense-in-depth, even on the internal network). Generate with: `python3 -c "import secrets; print('vllm-' + secrets.token_urlsafe(32))"` |

#### vLLM Inference Engine:
| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_DTYPE` | `auto` | Weight and activation dtype (`auto`, `float16`, `bfloat16`, `float32`). |
| `VLLM_QUANTIZATION_ARG` | `--quantization modelopt` | Full flag passed to vLLM; set to empty to disable quantization. NVIDIA NVFP4 checkpoints require `modelopt`. |
| `VLLM_ENABLE_PREFIX_CACHING` | `--enable-prefix-caching` | Set to empty to disable prefix caching. |
| `VLLM_ENABLE_CHUNKED_PREFILL` | _(empty)_ | Set to `--enable-chunked-prefill` to split long prefill phases into chunks, improving latency under concurrent load. |
| `VLLM_LANGUAGE_MODEL_ONLY` | _(empty)_ | Set to `--language-model-only` to skip the vision encoder on multimodal models (text-only deployments). |
| `VLLM_ENABLE_AUTO_TOOL_CHOICE` | _(empty)_ | Set to `--enable-auto-tool-choice` to allow the model to invoke tools autonomously. |
| `VLLM_TOOL_CALL_PARSER_ARG` | _(empty)_ | Full flag, e.g. `--tool-call-parser qwen3_xml`. Common values: `gemma4`, `hermes`, `mistral`, `llama3_json`, `qwen3_xml`. |
| `VLLM_REASONING_PARSER_ARG` | _(empty)_ | Full flag, e.g. `--reasoning-parser qwen3`. Enables structured extraction of `<think>…</think>` blocks. Common values: `qwen3`, `deepseek_r1`. |
| `VLLM_MAX_MODEL_LEN` | `8192` | Maximum context length in tokens (prompt + generation). |
| `VLLM_MAX_NUM_BATCHED_TOKENS` | `8192` | Maximum total tokens across all concurrent sequences in one scheduler step. |
| `VLLM_MAX_NUM_SEQS` | `256` | Maximum number of sequences processed concurrently. |
| `VLLM_GPU_MEMORY_UTILIZATION` | `0.82` | Fraction of GPU memory reserved for the KV cache (`0.0`–`1.0`). |
| `VLLM_TENSOR_PARALLEL_ARG` | _(empty)_ | Set to `--tensor-parallel-size <n>` for multi-GPU; leave empty for single-GPU. |
| `VLLM_SHM_SIZE` | `16g` | Shared memory for NCCL; scale proportionally with tensor parallelism degree. |
| `VLLM_KV_CACHE_DTYPE_ARG` | _(empty)_ | Set to `--kv-cache-dtype fp8` to halve KV cache memory on Blackwell GPUs. |
| `VLLM_ATTENTION_BACKEND_ARG` | _(empty)_ | Set to `--attention-backend flashinfer` for optimized attention on Blackwell. |
| `VLLM_MOE_BACKEND_ARG` | _(empty)_ | Set to `--moe-backend marlin` for optimized MoE dispatch on Blackwell. |
| `VLLM_ASYNC_SCHEDULING` | _(empty)_ | Set to `--async-scheduling` to overlap request scheduling with GPU execution. |
| `VLLM_LOAD_FORMAT_ARG` | _(empty)_ | Set to `--load-format fastsafetensors` for faster model weight loading. |
| `VLLM_TRUST_REMOTE_CODE` | _(empty)_ | Set to `--trust-remote-code` to allow model-supplied custom code. |
| `VLLM_SPECULATIVE_CONFIG_ARG` | _(empty)_ | Full JSON flag for speculative decoding, e.g. `--speculative-config '{"method":"mtp","num_speculative_tokens":3}'`. |

#### LiteLLM Gateway:
| Variable | Default | Description |
|----------|---------|-------------|
| `LITELLM_NUM_WORKERS` | `2` | Number of Uvicorn worker processes; increase for higher request concurrency. |


### 2. Pre-download model weights
Download model weights from HuggingFace into the Docker volume to avoid the initial startup delay:
```bash
./scripts/download_model.sh
```


### 3. Start the stack
```bash
docker compose --env-file conf/.env up -d
```

### 4. Verify health
```bash
docker compose --env-file conf/.env ps      # both services should show "healthy"
docker compose --env-file conf/.env logs -f # watch startup progress
```

### 5. Test a request
```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<MODEL_NAME>",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```


## Container hardening

Both containers are hardened beyond Docker defaults:

| Measure | vLLM | LiteLLM | Purpose |
|---------|------|---------|---------|
| `cap_drop: ALL` | ✓ | ✓ | Drop all Linux capabilities (GPU access is injected by the NVIDIA runtime). |
| `no-new-privileges` | ✓ | ✓ | Prevent setuid/setgid binaries from escalating privileges. |
| `read_only` | — | ✓ | Immutable root filesystem; only `/tmp` (tmpfs) is writable. |
| `tmpfs` | `/tmp` (1 GB) | `/tmp` (256 MB) | RAM-backed scratch space — avoids writes to the overlay layer. |
| `pids_limit` | 1024 | 256 | Fork-bomb protection. |
| Memory limit | 120 GB | 2 GB | Hard cap via `deploy.resources.limits`; DGX Spark has 128 GB unified memory. |
| Swap disabled | ✓ | — | `memswap_limit` equals memory limit — GPU workloads degrade severely on swap. |
| CPU limit | — | 2 cores | Prevents the gateway from starving vLLM or the host. |
| Log rotation | 50 MB × 3 | 50 MB × 5 | JSON-file driver with size caps; prevents disk exhaustion. |
| Port binding | none | IPv4 only | `0.0.0.0:4000` avoids the IPv6 bypass when Docker IPv6 is enabled. |


## Configuration notes

### vLLM (inference engine)

| Parameter | Default | Notes |
|-----------|---------|-------|
| `--model` | `${HF_MODEL_ID}` | Full HuggingFace model path. Set `HF_MODEL_ID` in `.env`; update `MODEL_NAME` and `LITELLM_MODEL` to match. |
| `--dtype` | `auto` | Weight precision. `auto` lets vLLM infer an appropriate dtype from model metadata. |
| `--quantization` | `modelopt` | Selects quantization mode when supported by the chosen model (NVIDIA NVFP4 checkpoints require `modelopt`). Reduces VRAM usage compared with full-precision variants. |
| `--enable-prefix-caching` | enabled | Caches common prompt prefixes in GPU memory to avoid recomputation. |
| `--enable-chunked-prefill` | disabled | Splits long prefill phases into chunks, reducing head-of-line blocking under concurrent load. Enable via `VLLM_ENABLE_CHUNKED_PREFILL`. |
| `--language-model-only` | disabled | Skips the vision encoder on multimodal models for text-only deployments. Enable via `VLLM_LANGUAGE_MODEL_ONLY`. |
| `--enable-auto-tool-choice` | disabled | Permits the model to call tools autonomously. Enable via `VLLM_ENABLE_AUTO_TOOL_CHOICE`. |
| `--tool-call-parser` | _(none)_ | Parser for structured tool call output. Set via `VLLM_TOOL_CALL_PARSER_ARG` (e.g. `qwen3_xml`, `hermes`, `llama3_json`). |
| `--reasoning-parser` | _(none)_ | Extracts `<think>…</think>` reasoning blocks from output. Set via `VLLM_REASONING_PARSER_ARG` (e.g. `qwen3`, `deepseek_r1`). |
| `--max-model-len` | `8192` | Context window in tokens. Can be raised (e.g. `32768`, `131072`) at the cost of higher VRAM usage. |
| `--gpu-memory-utilization` | `0.82` | Fraction of VRAM vLLM pre-allocates for KV cache. DGX Spark uses unified memory — set to `0.40` to avoid starving the OS. |
| `--kv-cache-dtype` | _(none)_ | Data type for the KV cache. Set to `fp8` via `VLLM_KV_CACHE_DTYPE_ARG` to halve KV cache memory on Blackwell GPUs. |
| `--attention-backend` | _(default)_ | Attention kernel backend. Set to `flashinfer` via `VLLM_ATTENTION_BACKEND_ARG` for optimized performance on Blackwell. |
| `--moe-backend` | _(default)_ | MoE dispatch backend. Set to `marlin` via `VLLM_MOE_BACKEND_ARG` for optimized MoE on Blackwell. |
| `--async-scheduling` | disabled | Overlaps request scheduling with GPU execution to improve throughput. Enable via `VLLM_ASYNC_SCHEDULING`. |
| `--load-format` | _(default)_ | Model weight loading strategy. Set to `fastsafetensors` via `VLLM_LOAD_FORMAT_ARG` for faster startup. |
| `--trust-remote-code` | disabled | Allows model-supplied custom code. Enable via `VLLM_TRUST_REMOTE_CODE` only for trusted model repos. |
| `--speculative-config` | _(none)_ | JSON config for speculative decoding (e.g. Multi-Token Prediction). Set via `VLLM_SPECULATIVE_CONFIG_ARG`. |
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
