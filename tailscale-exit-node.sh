#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "=============================================="
echo " Starting Low-RAM Debian 12 Tailscale Setup   "
echo "=============================================="

# 1. Verify Root
if [ "$(id -u)" -ne 0 ]; then
  echo "[-] Error: This script must be run as root." >&2
  exit 1
fi

# 2. Baseline Memory Inspection
echo "[+] Initial Memory Baseline:"
free -m
echo ""

# 3. Check TUN/TAP device accessibility
echo "[+] Checking TUN/TAP device..."
if ! cat /dev/net/tun 2>&1 | grep -q "File descriptor in bad state"; then
  echo "[-] WARNING: /dev/net/tun is unavailable or misconfigured."
  echo "    On OpenVZ/container VPS, enable TUN/TAP in your provider panel and reboot."
  exit 1
fi

# 4. Low-RAM Daemon Cleanup (Reclaim Memory Early)
echo "[+] Stopping non-essential services to conserve RAM..."
systemctl stop rsyslog cron 2>/dev/null || true
systemctl disable rsyslog cron 2>/dev/null || true

# 5. Update & Upgrade Minimal Packages
echo "[+] Updating apt repositories and packages..."
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

# 6. Install Bare Minimum Dependencies
echo "[+] Installing essential networking tools..."
apt-get install -y --no-install-recommends \
  curl \
  ca-certificates \
  iptables \
  iptables-persistent

# 7. Enable Kernel IP Packet Forwarding
echo "[+] Configuring IP forwarding sysctl..."
cat <<'EOF' > /etc/sysctl.d/99-tailscale.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null

# 8. Configure Dynamic NAT Masquerading
echo "[+] Detecting primary egress interface..."
PRIMARY_IFACE=$(ip route show default | awk '{print $5}' | head -n1)
if [ -z "$PRIMARY_IFACE" ]; then
  PRIMARY_IFACE=$(ip -4 route show | grep -E 'venet0|eth0' | awk '{print $3}' | head -n1)
fi

if [ -z "$PRIMARY_IFACE" ]; then
  echo "[-] Could not detect primary interface. Defaulting to venet0."
  PRIMARY_IFACE="venet0"
fi
echo "[+] Using egress interface: ${PRIMARY_IFACE}"

# Apply iptables NAT rule if not already present
if ! iptables -t nat -C POSTROUTING -o "${PRIMARY_IFACE}" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -o "${PRIMARY_IFACE}" -j MASQUERADE
fi

# Save iptables rules across reboots
netfilter-persistent save

# 9. Install Tailscale
echo "[+] Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# 10. Aggressive Clean-up Before Launch
apt-get autoremove --purge -y
apt-get clean
rm -rf /var/lib/apt/lists/*
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

# 11. Memory Diagnostic Before Launch
echo "----------------------------------------------"
echo " RAM available prior to starting Tailscale:  "
free -m
echo "----------------------------------------------"

# 12. Tailscale Initialization
echo ""
echo "[?] If you have an Auth Key, paste it below."
echo "    Press [ENTER] without typing anything to authenticate via Web URL:"
read -r -p "Auth Key (optional): " AUTH_KEY

TAILSCALE_OPTS="--advertise-exit-node --ssh"

if [ -n "$AUTH_KEY" ]; then
  echo "[+] Bringing up Tailscale using Auth Key..."
  tailscale up ${TAILSCALE_OPTS} --authkey="${AUTH_KEY}"
else
  echo "[+] Bringing up Tailscale (open the URL below to authenticate):"
  tailscale up ${TAILSCALE_OPTS}
fi

# 13. Final Memory Verification
echo ""
echo "----------------------------------------------"
echo " Final RAM status with Tailscale active:     "
free -m
echo "----------------------------------------------"

echo ""
echo "=============================================="
echo " Setup Complete!                              "
echo "=============================================="
echo "1. Go to: https://login.tailscale.com/admin/machines"
echo "2. Find this node -> Click '...' -> 'Edit route settings...'"
echo "3. Check 'Use as exit node' -> Click 'Save'."
echo "=============================================="
