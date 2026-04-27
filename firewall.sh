#!/usr/bin/env bash
# firewall.sh — UFW + iptables rules for the LLM serving stack.
# Run as root: sudo bash firewall.sh
set -euo pipefail

# ──────────────────────────────────────────────
# 0. Require root privileges
# ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo bash firewall.sh)" >&2
    exit 1
fi

# ──────────────────────────────────────────────
# Flag: --docker-user-only
#   When called from the systemd drop-in (ExecStartPost), only
#   re-apply the DOCKER-USER iptables rules — skip UFW, package
#   installs, and drop-in (re)creation to avoid recursion.
# ──────────────────────────────────────────────
DOCKER_USER_ONLY=false
if [[ "${1:-}" == "--docker-user-only" ]]; then
    DOCKER_USER_ONLY=true
fi

if [[ "$DOCKER_USER_ONLY" == false ]]; then

    # ──────────────────────────────────────────────
    # 1. Ensure UFW is installed
    # ──────────────────────────────────────────────
    if ! command -v ufw &>/dev/null; then
        echo "Installing UFW..."
        apt-get update -qq && apt-get install -y -qq ufw
    fi

    # ──────────────────────────────────────────────
    # 2. Default policies
    # ──────────────────────────────────────────────
    ufw default deny incoming
    ufw default allow outgoing

    # ──────────────────────────────────────────────
    # 3. Allow SSH (rate-limited to slow brute-force; 6+ connections in 30s → block)
    #    Delete both "allow" and "limit" rules first to guarantee idempotency.
    #    Without this, re-running the script accumulates duplicate limit rules.
    # ──────────────────────────────────────────────
    ufw delete allow 22/tcp 2>/dev/null || true
    ufw delete limit 22/tcp 2>/dev/null || true
    ufw limit 22/tcp comment "SSH (rate-limited)"

    # ──────────────────────────────────────────────
    # 4. Allow LiteLLM API port (delete first to avoid duplicate rules on re-run)
    # ──────────────────────────────────────────────
    ufw delete allow 4000/tcp 2>/dev/null || true
    ufw delete limit 4000/tcp 2>/dev/null || true
    ufw allow 4000/tcp comment "LiteLLM API"

    # ──────────────────────────────────────────────
    # 5. Enable UFW (idempotent)
    # ──────────────────────────────────────────────
    ufw --force enable

fi  # end DOCKER_USER_ONLY check

# ──────────────────────────────────────────────
# 6. Prevent Docker from bypassing UFW
#    Docker manipulates iptables directly via the
#    DOCKER-USER chain, ignoring UFW rules.
#    We insert rules in DOCKER-USER so that only
#    allowed traffic reaches published container ports.
# ──────────────────────────────────────────────

# Guard: skip iptables rules if Docker is not yet installed
# (the DOCKER-USER chain only exists after dockerd starts)
if iptables --wait -L DOCKER-USER -n &>/dev/null; then

    # Flush any previous custom rules in DOCKER-USER
    iptables --wait -F DOCKER-USER

    # Drop packets with INVALID conntrack state — these can bypass stateful rules
    # (e.g. malformed packets, orphaned FIN/RST after conntrack entry expires)
    iptables --wait -A DOCKER-USER -m conntrack --ctstate INVALID -j DROP

    # Allow established / related connections (return traffic)
    iptables --wait -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

    # Allow loopback traffic (host → container via localhost)
    iptables --wait -A DOCKER-USER -i lo -j RETURN

    # Allow traffic from docker0 bridge (host → container default network)
    iptables --wait -A DOCKER-USER -i docker0 -j RETURN

    # Allow traffic between Docker bridge networks (inter-container)
    iptables --wait -A DOCKER-USER -i br+ -o br+ -j RETURN

    # Allow containers to initiate outbound connections to the internet
    # (required for HuggingFace model downloads, etc.)
    # Matches traffic FROM a Docker bridge TO a non-bridge interface (i.e. the physical NIC).
    iptables --wait -A DOCKER-USER -i br+ ! -o br+ -j RETURN

    # Per-source-IP rate-limit for new connections to LiteLLM port.
    # Uses hashlimit (per-IP tracking) instead of global limit so a single
    # attacker cannot exhaust the entire budget and starve legitimate clients.
    # --syn ensures only SYN packets (true connection attempts) are counted,
    # not TCP retransmissions.
    iptables --wait -A DOCKER-USER -p tcp --dport 4000 --syn -m conntrack --ctstate NEW \
        -m hashlimit --hashlimit-upto 30/sec --hashlimit-burst 60 \
        --hashlimit-mode srcip --hashlimit-name docker_port4000 \
        --hashlimit-htable-expire 30000 \
        -j RETURN

    # Note: established connections to port 4000 are already covered by
    # the blanket ESTABLISHED,RELATED rule above — no duplicate rule needed.

    # Log dropped packets (limited to avoid log flooding)
    iptables --wait -A DOCKER-USER -m limit --limit 5/min --limit-burst 10 \
        -j LOG --log-prefix "DOCKER-USER-DROP: " --log-level 4

    # Drop everything else destined to containers
    iptables --wait -A DOCKER-USER -j DROP

    echo "DOCKER-USER iptables (IPv4) chain configured."

else
    echo "WARNING: DOCKER-USER chain not found for IPv4 (Docker not installed yet?)."
    echo "         Re-run this script after installing Docker to secure container ports."
fi

# ──────────────────────────────────────────────
# 6b. Mirror DOCKER-USER rules for IPv6
#     If Docker IPv6 is enabled, containers could be reached via IPv6
#     without these rules, completely bypassing the IPv4 protections above.
# ──────────────────────────────────────────────
if ip6tables --wait -L DOCKER-USER -n &>/dev/null; then
    ip6tables --wait -F DOCKER-USER

    # Drop INVALID packets (IPv6)
    ip6tables --wait -A DOCKER-USER -m conntrack --ctstate INVALID -j DROP

    ip6tables --wait -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    ip6tables --wait -A DOCKER-USER -i lo -j RETURN
    ip6tables --wait -A DOCKER-USER -i docker0 -j RETURN
    ip6tables --wait -A DOCKER-USER -i br+ -o br+ -j RETURN

    # Allow containers to initiate outbound connections (IPv6)
    ip6tables --wait -A DOCKER-USER -i br+ ! -o br+ -j RETURN

    ip6tables --wait -A DOCKER-USER -p tcp --dport 4000 --syn -m conntrack --ctstate NEW \
        -m hashlimit --hashlimit-upto 30/sec --hashlimit-burst 60 \
        --hashlimit-mode srcip --hashlimit-name docker6_port4000 \
        --hashlimit-htable-expire 30000 \
        -j RETURN

    ip6tables --wait -A DOCKER-USER -m limit --limit 5/min --limit-burst 10 \
        -j LOG --log-prefix "DOCKER-USER6-DROP: " --log-level 4

    ip6tables --wait -A DOCKER-USER -j DROP

    echo "DOCKER-USER ip6tables (IPv6) chain configured."
else
    echo "INFO: No IPv6 DOCKER-USER chain found (Docker IPv6 likely disabled — OK)."
fi

if [[ "$DOCKER_USER_ONLY" == false ]]; then

    # ──────────────────────────────────────────────
    # 7. Persist iptables rules across reboots
    # ──────────────────────────────────────────────
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    else
        echo "Installing iptables-persistent to survive reboots..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
        netfilter-persistent save
    fi

    # ────────────────────────────────────────────────
    # 8. Persist DOCKER-USER rules across Docker daemon restarts
    #    Docker recreates the DOCKER-USER chain when dockerd restarts,
    #    wiping custom rules. A systemd drop-in re-applies them.
    #    The --docker-user-only flag ensures only iptables rules are
    #    re-applied — UFW and package installs are skipped.
    # ────────────────────────────────────────────────
    SCRIPT_PATH="$(readlink -f "$0")"
    DROPIN_DIR="/etc/systemd/system/docker.service.d"
    DROPIN_FILE="${DROPIN_DIR}/docker-user-firewall.conf"

    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN_FILE" << EOF
[Service]
ExecStartPost=/bin/bash ${SCRIPT_PATH} --docker-user-only
EOF
    systemctl daemon-reload
    echo "Installed systemd drop-in at ${DROPIN_FILE} (re-applies DOCKER-USER rules on dockerd restart)."

    echo ""
    echo "Firewall configured:"
    echo "  - UFW: deny incoming, allow outgoing, allow SSH (22, rate-limited) + LiteLLM (4000)"
    echo "  - DOCKER-USER chain: only port 4000 reachable from outside (rate-limited); container outbound + inter-container traffic allowed"
    ufw status verbose

fi  # end DOCKER_USER_ONLY check
