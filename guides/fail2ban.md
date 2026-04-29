## Fail2Ban - Guide

Fail2Ban monitors log files and bans IPs that show repeated failed login attempts.   
You can use Fail2Ban to protect your server against brute-force attacks on SSH and other services.


### 1. Install
```bash
sudo apt-get update && sudo apt-get install -y fail2ban
```


### 2. Configure the SSH jail
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


### 3. Enable and start
```bash
sudo systemctl enable fail2ban
sudo systemctl restart fail2ban
```


### 4. Verify
```bash
sudo fail2ban-client status sshd
```
