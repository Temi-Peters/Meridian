# Runbook

Operating the thing once it is built. Placeholders as in [SETUP.md](SETUP.md).

## Add a device, five steps

1. Generate its keys, picking the next free tunnel address:
   ```bash
   sudo sh -c 'umask 077; cd <prefix>/etc/wireguard && wg genkey > NAME.key \
     && wg pubkey < NAME.key > NAME.pub && wg genpsk > NAME.psk'
   ```
2. Append a `[Peer]` block to `wg0.conf` with the new public key, preshared key and `AllowedIPs = 10.8.0.N/32`.
3. Build a client profile from the template in SETUP.md, using the new keys.
4. Restart: `sudo wg-quick down ... && sudo wg-quick up ...`
5. Transfer the profile by QR code, or copy the file to the device directly. Never by email or chat.

## Rotate a key

Do this if a device is lost, or if a key may have been exposed.

1. Generate a fresh keypair and preshared key for that device, same tunnel address.
2. Replace its public key and preshared key in `wg0.conf`; rebuild its profile.
3. Restart the tunnel. The old key stops working the moment the configuration reloads.
4. Re-scan on the device.

## Health checks

| Question | Command | Healthy answer |
|---|---|---|
| Is the tunnel up? | `sudo wg show` | An interface, and a recent handshake per connected peer |
| Is the daemon running? | `sudo launchctl list \| grep <label>` | Second column 0 |
| Is forwarding on? | `sysctl net.inet.ip.forwarding` | 1 |
| Is the translation rule loaded? | `sudo pfctl -a com.apple/wireguard -s nat` | The rule echoes back |
| Is DNS current? | `nslookup YOURNAME.duckdns.org` | Matches `curl -4 -s https://api.ipify.org` |
| Are packets arriving? | `sudo tcpdump -i IFACE -n udp port 51820` | Lines appear when a client connects |

## Diagnosing a failure

Work along the path one step at a time. The client application tells you where to start:

**Bytes sent, none received, no handshake.** Packets are leaving the client and nothing is answering. The fault is between the internet and the server: port forward missing or not applied, the dynamic DNS record stale, or the server down. Run the tcpdump check above and reconnect the client. Lines appearing means packets reach the machine and the problem is local to it. Silence means the router is dropping them.

**Handshake succeeds, no traffic flows.** The tunnel is fine but routing or translation is not. Check forwarding is 1 and the rule is loaded.

**Works at home, not away.** Almost always the address changed and the dynamic DNS record has not caught up. Wait for the timer or run the boot script by hand.

**Everything dead after a reboot.** The boot daemon did not run. Check it, and run the boot script manually to confirm the script itself still works.

**Everything dead after connecting another VPN.** Expected. Any second system-wide VPN captures the routing table. Turn the server off before using one, and back on afterwards.

## Exit nodes

```bash
sudo exit.sh up REGION      # allow two minutes before connecting
sudo exit.sh list           # should read "no exits running" at end of day
sudo exit.sh down REGION    # destroys; stopping is not enough to end billing
sudo exit.sh qr REGION
```

Add a region by adding a line to `regions.conf` and creating the matching dynamic DNS hostname. Region codes come from the provider's tool.

Instances bill with a one-hour minimum, so each launch costs at least an hour regardless of how briefly it lives. Launch per outing, not per browse.

## Tear it all down

Follow the rollback log from the bottom up. In short: destroy every exit, unload and delete the boot daemon and scripts, bring the tunnel down, flush the firewall anchor, turn forwarding off, delete the configuration directory, remove the router's port forward and address reservation, delete the dynamic DNS hostnames, delete the tunnels on client devices, and restore the sleep setting.
