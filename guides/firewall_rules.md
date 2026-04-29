## Firewall Setup - Guide

The server uses **UFW** as the frontend and **iptables** as the backend.    
Because Docker manipulates `iptables` directly (bypassing UFW), the script also inserts rules in the `DOCKER-USER` chain to control access to published container ports.

Run the following command to set up the firewall rules:
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
