#!/bin/bash
# exit.sh : on-demand WireGuard exit servers
#
# Part of Meridian. Creates a WireGuard server in a chosen region, points that
# region's dynamic DNS hostname at it, and destroys it on demand. Client
# profiles are generated once per region and stay valid across rebuilds,
# because each region keeps a permanent server keypair on this machine.
#
#   sudo exit.sh up REGION      create, update DNS, print a QR on first use
#   sudo exit.sh down REGION    destroy (this is what stops billing)
#   sudo exit.sh list           running exits, uptime, cost so far
#   sudo exit.sh qr REGION [phone|mac]
#   sudo exit.sh regions        configured regions
#
# Before first use, set the constants below, create regions.conf with one
# "REGIONCODE dnsname" line per region, and place your provider API token at
# $EX/provider.token and your dynamic DNS token at $BASE/duckdns.token, both
# readable only by root.
#
# Requires: wireguard-tools, qrencode, python3, and the provider CLI.
# Written for Vultr; the create, get, list and delete calls are the only
# provider-specific parts.
set -euo pipefail
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

BASE=/opt/homebrew/etc/wireguard
EX=$BASE/exits
PLAN=vc2-1c-1gb
OS_ID=2136                                   # Debian 12
SSH_KEY_ID=REPLACE_WITH_YOUR_SSH_KEY_ID
SUBNET=10.9.0                                # exit tunnels use 10.9.0.0/24 (home uses 10.8.0.0/24)
PRICE_PER_HOUR=0.0074

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
umask 077
export VULTR_API_KEY
VULTR_API_KEY=$(cat "$EX/provider.token")
DUCK_TOKEN=$(cat "$BASE/duckdns.token")

dnsname() { awk -v r="$1" '$1==r {print $2}' "$EX/regions.conf"; }

find_id() {
  vultr-cli instance list -o json 2>/dev/null | python3 -c '
import sys, json
label = "exit-" + sys.argv[1]
for i in json.load(sys.stdin).get("instances", []):
    if i.get("label") == label:
        print(i["id"]); break
' "$1"
}

ensure_client_keys() {
  for c in phone mac; do
    if [ ! -f "$EX/roaming-$c.key" ]; then
      wg genkey > "$EX/roaming-$c.key"
      wg pubkey < "$EX/roaming-$c.key" > "$EX/roaming-$c.pub"
    fi
  done
}

ensure_region_keys() {
  local d=$EX/$1
  mkdir -p "$d"
  if [ ! -f "$d/server.key" ]; then
    wg genkey > "$d/server.key"
    wg pubkey < "$d/server.key" > "$d/server.pub"
  fi
  [ -f "$d/psk-phone" ] || wg genpsk > "$d/psk-phone"
  [ -f "$d/psk-mac" ]   || wg genpsk > "$d/psk-mac"
}

write_profiles() {
  local r=$1 d=$EX/$1 name
  name=$(dnsname "$r")
  [ -n "$name" ] || die "no DNS name for region '$r' in $EX/regions.conf"
  local c addr
  for c in phone mac; do
    addr=2; [ "$c" = mac ] && addr=3
    cat > "$d/$c.conf" <<EOF
[Interface]
PrivateKey = $(cat "$EX/roaming-$c.key")
Address = $SUBNET.$addr/32
DNS = 1.1.1.1

[Peer]
PublicKey = $(cat "$d/server.pub")
PresharedKey = $(cat "$d/psk-$c")
Endpoint = $name.duckdns.org:443
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  done
}

render_userdata() {
  local d=$EX/$1 f=$EX/$1/userdata.yaml
  cat > "$f" <<EOF
#cloud-config
package_update: true
packages:
  - wireguard
  - nftables
write_files:
  - path: /etc/wireguard/wg0.conf
    permissions: "0600"
    content: |
      [Interface]
      PrivateKey = $(cat "$d/server.key")
      Address = $SUBNET.1/24
      ListenPort = 51820

      [Peer]
      PublicKey = $(cat "$EX/roaming-phone.pub")
      PresharedKey = $(cat "$d/psk-phone")
      AllowedIPs = $SUBNET.2/32

      [Peer]
      PublicKey = $(cat "$EX/roaming-mac.pub")
      PresharedKey = $(cat "$d/psk-mac")
      AllowedIPs = $SUBNET.3/32
  - path: /etc/sysctl.d/99-wireguard.conf
    content: |
      net.ipv4.ip_forward=1
  - path: /etc/nftables-exit.conf
    permissions: "0644"
    content: |
      #!/usr/sbin/nft -f
      flush ruleset
      table inet filter {
        chain input {
          type filter hook input priority 0; policy drop;
          ct state established,related accept
          iif "lo" accept
          ip protocol icmp accept
          meta l4proto ipv6-icmp accept
          tcp dport 22 accept
          udp dport { 443, 51820 } accept
        }
        chain forward {
          type filter hook forward priority 0; policy drop;
          iifname "wg0" accept
          oifname "wg0" ct state established,related accept
        }
      }
      table inet nat {
        chain prerouting {
          type nat hook prerouting priority -100;
          udp dport 443 redirect to :51820
        }
        chain postrouting {
          type nat hook postrouting priority 100;
          ip saddr $SUBNET.0/24 oifname != "wg0" masquerade
        }
      }
runcmd:
  - sysctl --system
  - cp /etc/nftables-exit.conf /etc/nftables.conf
  - systemctl enable --now nftables
  - systemctl enable --now wg-quick@wg0
EOF
  echo "$f"
}

cmd_up() {
  local r=$1
  grep -q "^$r " "$EX/regions.conf" || die "unknown region '$r' (see: exit.sh regions)"
  [ -z "$(find_id "$r")" ] || die "an exit for '$r' is already running (exit.sh list)"
  ensure_client_keys
  ensure_region_keys "$r"
  write_profiles "$r"
  local ud out id
  ud=$(render_userdata "$r")
  out=$(vultr-cli instance create --region "$r" --plan "$PLAN" --os "$OS_ID" \
        --label "exit-$r" --host "exit-$r" --tags exit \
        --ssh-keys "$SSH_KEY_ID" --userdata-file "$ud" -o json)
  rm -f "$ud"
  id=$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["instance"]["id"])') \
    || die "could not parse create response: $out"
  echo "created instance $id in $r, waiting for an IP..."
  local ip=0.0.0.0 st="" i
  for i in $(seq 1 60); do
    read -r ip st < <(vultr-cli instance get "$id" -o json | python3 -c '
import sys, json
i = json.load(sys.stdin)["instance"]
print(i.get("main_ip", "0.0.0.0"), i.get("status", ""))')
    [ "$ip" != "0.0.0.0" ] && [ "$st" = "active" ] && break
    sleep 5
  done
  [ "$ip" != "0.0.0.0" ] || die "timed out waiting for an IP; check the Vultr dashboard"
  local name res
  name=$(dnsname "$r")
  res=$(curl -s "https://www.duckdns.org/update?domains=$name&token=$DUCK_TOKEN&ip=$ip")
  echo "DNS: $name.duckdns.org -> $ip ($res)"
  echo "Server is installing WireGuard now; give it about two minutes before connecting."
  if [ ! -f "$EX/$r/.qr-shown" ]; then
    echo; echo "First time for $r: scan this into the WireGuard app as \"Exit $r\"."; echo
    qrencode -t ansiutf8 < "$EX/$r/phone.conf"
    touch "$EX/$r/.qr-shown"
  fi
}

cmd_down() {
  local r=$1 id
  id=$(find_id "$r")
  [ -n "$id" ] || die "no running exit for '$r'"
  vultr-cli instance delete "$id" >/dev/null
  echo "destroyed exit-$r ($id). Billing stopped. Keys and DNS name kept for next time."
}

cmd_list() {
  vultr-cli instance list -o json | python3 -c '
import sys, json
from datetime import datetime, timezone
price = float(sys.argv[1])
rows = [i for i in json.load(sys.stdin).get("instances", []) if str(i.get("label","")).startswith("exit-")]
if not rows:
    print("no exits running"); sys.exit()
print("%-8s %-16s %-10s %6s %8s" % ("REGION", "IP", "STATUS", "HOURS", "COST"))
for i in rows:
    created = datetime.fromisoformat(i["date_created"].replace("Z", "+00:00"))
    hours = (datetime.now(timezone.utc) - created).total_seconds() / 3600
    print("%-8s %-16s %-10s %6.1f $%7.3f" % (i["label"][5:], i["main_ip"], i["status"], hours, hours * price))
' "$PRICE_PER_HOUR"
}

cmd_qr() {
  local r=$1 c=${2:-phone}
  [ -f "$EX/$r/$c.conf" ] || die "no $c profile for '$r' yet (run: exit.sh up $r)"
  qrencode -t ansiutf8 < "$EX/$r/$c.conf"
}

case "${1:-}" in
  up)      [ -n "${2:-}" ] || die "usage: exit.sh up REGION";   cmd_up "$2" ;;
  down)    [ -n "${2:-}" ] || die "usage: exit.sh down REGION"; cmd_down "$2" ;;
  list)    cmd_list ;;
  qr)      [ -n "${2:-}" ] || die "usage: exit.sh qr REGION [phone|mac]"; cmd_qr "$2" "${3:-phone}" ;;
  regions) cat "$EX/regions.conf" ;;
  *)       echo "usage: sudo exit.sh up REGION | down REGION | list | qr REGION [phone|mac] | regions"; exit 1 ;;
esac
