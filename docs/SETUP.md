# Setup

Build this yourself, from nothing. Written for macOS as the server because that is what it was built on; the Linux equivalents are noted where they differ, and are simpler.

Replace every placeholder as you go:

| Placeholder | Meaning | Example |
|---|---|---|
| `YOURNAME` | Your dynamic DNS hostname, unrelated to your real name | `amber-lantern-07` |
| `SERVER_LAN_IP` | The server's address on your home network | `192.168.0.52` |
| `LAN_SUBNET` | Your home network range | `192.168.0.0/24` |
| `IFACE` | The server's active network interface | `en0` |
| `SSH_KEY_ID` | Identifier of your public key at the hosting provider | a UUID |

Two rules throughout. Private keys are generated on the machine that will own them and are never printed. Every file containing a key is readable only by its owner.

---

## Part one: the home server

### 0. Feasibility, before changing anything

**Carrier-grade address translation.** Compare the address your router reports as its internet address against what the internet sees:

```bash
curl -4 -s https://api.ipify.org
```

If the router's address differs from that, or begins `100.64.` to `100.127.`, inbound connections cannot reach you and this design will not work without a rented relay. Stop here and read the scaling section of the architecture document.

**Sleep.** A sleeping server is an offline server:

```bash
pmset -g
```

On a laptop, `sudo pmset -c sleep 0` prevents sleep while on mains power only. Reverse with `sudo pmset -c sleep 1`.

**Address stability.** Note the server's local address and network interface:

```bash
route -n get default | grep interface
ipconfig getifaddr en0
```

Reserve that address for the machine in the router's settings so it cannot change. On macOS, set the Wi-Fi private address to Fixed first (System Settings, Wi-Fi, Details), or the randomised address will break the reservation.

### 1. Install and generate

```bash
brew install wireguard-tools qrencode          # Linux: apt install wireguard qrencode
```

```bash
PREFIX=$(brew --prefix)
sudo mkdir -p "$PREFIX/etc/wireguard"
(umask 077 && wg genkey | sudo tee "$PREFIX/etc/wireguard/server.key" >/dev/null)
sudo sh -c "wg pubkey < '$PREFIX/etc/wireguard/server.key' > '$PREFIX/etc/wireguard/server.pub'"
sudo chmod 600 "$PREFIX/etc/wireguard/server".{key,pub}
```

`umask 077` sets the permissions before the file exists, so the key is never briefly world-readable.

### 2. Server configuration

```bash
sudo sh -c 'umask 077; cat > /opt/homebrew/etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $(cat /opt/homebrew/etc/wireguard/server.key)
Address = 10.8.0.1/24
ListenPort = 51820
EOF
chmod 600 /opt/homebrew/etc/wireguard/wg0.conf'
```

The key is read and written by root in one step, so it never appears on screen or in shell history.

### 3. Forwarding and address translation

```bash
sudo sysctl -w net.inet.ip.forwarding=1
```

Linux: `net.ipv4.ip_forward=1` in `/etc/sysctl.d/`.

macOS firewall rule, loaded into its own anchor so the system configuration is untouched:

```bash
sudo sh -c 'echo "nat on IFACE from 10.8.0.0/24 to any -> (IFACE)" > /etc/pf.anchors/wireguard.nat'
sudo pfctl -a com.apple/wireguard -f /etc/pf.anchors/wireguard.nat
sudo pfctl -e        # if pfctl -s info reports Disabled
```

Reading that rule: for packets leaving by `IFACE` whose source is any tunnel address, rewrite the source to that interface's current address. The parentheses mean the address is looked up at match time, so it survives the address changing.

Linux equivalent, one line: `nft add rule inet nat postrouting ip saddr 10.8.0.0/24 oifname IFACE masquerade`.

### 4. Bring it up

```bash
sudo wg-quick up /opt/homebrew/etc/wireguard/wg0.conf
sudo wg show
```

macOS names the interface `utunN`, not `wg0`. Any health check must therefore test `wg show interfaces` rather than looking for a device called wg0. This cost an hour of confusion during the original build.

### 5. Dynamic DNS

Create a free hostname with a provider that offers a simple update endpoint. Store the token where only root can read it:

```bash
read -s TOKEN && echo "$TOKEN" | sudo tee /opt/homebrew/etc/wireguard/ddns.token >/dev/null \
  && sudo chmod 600 /opt/homebrew/etc/wireguard/ddns.token && unset TOKEN && echo saved
```

`read -s` keeps the token out of shell history. Push the first update:

```bash
curl -s "https://www.duckdns.org/update?domains=YOURNAME&token=$(sudo cat /opt/homebrew/etc/wireguard/ddns.token)&ip="
```

Leaving `ip=` empty makes the provider use the address the request came from, so the address never has to be typed or known.

### 6. Router

Forward **UDP 51820** to `SERVER_LAN_IP`, and apply the change. This is the step most likely to be missed, and the symptom is distinctive: the client shows bytes sent, zero bytes received, and no handshake.

If your router has universal plug and play enabled, consider turning it off. It lets any device on the network open ports to the internet without asking, and those rules persist after the device has gone.

### 7. Client profiles

Generate the client's keys and register it as a peer. A preshared key adds a symmetric secret on top of the public key exchange:

```bash
sudo sh -c 'umask 077; cd /opt/homebrew/etc/wireguard && wg genkey > phone.key \
  && wg pubkey < phone.key > phone.pub && wg genpsk > phone.psk'
```

```bash
sudo sh -c 'cat >> /opt/homebrew/etc/wireguard/wg0.conf <<EOF

[Peer]
PublicKey = $(cat /opt/homebrew/etc/wireguard/phone.pub)
PresharedKey = $(cat /opt/homebrew/etc/wireguard/phone.psk)
AllowedIPs = 10.8.0.2/32
EOF'
```

Two profiles for the phone, full and split:

```ini
# full tunnel
[Interface]
PrivateKey = <phone.key>
Address = 10.8.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = <server.pub>
PresharedKey = <phone.psk>
Endpoint = YOURNAME.duckdns.org:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

For the split profile, drop the `DNS` line and set `AllowedIPs = LAN_SUBNET, 10.8.0.0/24`.

`PersistentKeepalive` sends a small packet every 25 seconds so the router's address translation entry does not expire while idle.

Restart the tunnel, then render each profile as a QR code and scan it into the official WireGuard app:

```bash
sudo cat /opt/homebrew/etc/wireguard/clients/phone-full.conf | qrencode -t ansiutf8
```

The QR code contains a private key. Do not photograph it, screenshot it, or send it anywhere.

### 8. Test from outside

Turn Wi-Fi off on the phone so it is on mobile data, activate the tunnel, and check three things: a recent handshake in the app, your router's administration page loading, and a what-is-my-address site showing your home address. Any check that fails tells you where to look, and the architecture document explains the chain.

### 9. Persistence

Nothing so far survives a reboot. A boot script that re-applies forwarding, loads the firewall anchor, brings up the tunnel if it is down, and refreshes the dynamic DNS record, run by the system service manager at boot and on a timer, closes that gap. On macOS that is a launchd daemon; on Linux, `systemctl enable wg-quick@wg0` plus a timer for the DNS update, which is considerably simpler.

Make the script safe to run repeatedly, and have it test actual state rather than assuming.

---

## Part two: exit nodes

### Prerequisites

1. An account with a provider that bills hourly and supports cloud-init. Generate an API key in their dashboard and store it as in step 5 above, at `exits/provider.token`.
2. Their command line tool installed.
3. An SSH keypair, with the public half registered at the provider, so you can log into an exit to debug it. Note the identifier the provider gives it.
4. One dynamic DNS hostname per region you want.

### Configure

```
exits/regions.conf        one line per region:  ams example-ams
scripts/exit.sh           edit the constants at the top
```

The constants are the plan name, the operating system image identifier, your SSH key identifier, the tunnel subnet, and the hourly price for cost reporting. Region codes and image identifiers come from the provider's tool.

Install the script as root-owned and executable only by root, since it reads keys and an API credential:

```bash
sudo install -o root -g wheel -m 700 scripts/exit.sh /usr/local/bin/exit.sh
```

### Use

```bash
sudo exit.sh up ams        # create, update DNS, print a QR the first time
sudo exit.sh list          # what is running, how long, what it has cost
sudo exit.sh down ams      # destroy it
sudo exit.sh qr ams        # re-show a profile
```

First launch of a region prints a QR code. Scan it once. Every later server in that region works with the same profile.

Allow about two minutes after `up` returns before connecting, since the instance is still installing packages.

### Habits worth keeping

`sudo exit.sh list` should read "no exits running" before you finish for the day. Check the provider's dashboard occasionally; the tool only knows about instances it labelled.

If the control machine is also a VPN server, turn that server off before connecting the same machine to an exit. Otherwise its routing table sends the replies the wrong way, and the dynamic DNS updater will report the exit's address as the home address, breaking remote access until it refreshes.
