# UNDO.md, the rollback log

This is the real log kept during the original build, with personal identifiers replaced by placeholders. Every change to the machine, the router or an external account went in as it happened, with the exact command to reverse it.

The discipline is worth more than the file. Writing the reversal at the moment of the change means it is accurate; reconstructing it weeks later means guessing. It also makes "try it and see" safe, which is how most of this was learned.

Entries are numbered in the order they were made. Undo runs bottom to top.

---

## 1. Disable sleep on power adapter

- Change: `sudo pmset -c sleep 0`, so the machine stays reachable while plugged in
- Revert: `sudo pmset -c sleep 1`

## 2. Wi-Fi private address set to Fixed

- Change: System Settings, Wi-Fi, Details, Private Wi-Fi Address set to Fixed, so the hardware address stops rotating and the router reservation holds
- Revert: set it back to Rotating

## 3. Router address reservation

- Change: reserved `SERVER_LAN_IP` for the server's Wi-Fi address
- Revert: delete the reservation, apply changes

## 4. Install packages

- Change: `brew install wireguard-tools qrencode`
- Revert: `brew uninstall wireguard-tools qrencode`

## 5. Server keypair

- Change: `server.key` and `server.pub` created under the WireGuard configuration directory, permissions 600
- Revert: `sudo rm -r <prefix>/etc/wireguard`

## 6. Server configuration

- Change: `wg0.conf` written, tunnel subnet 10.8.0.0/24, server at 10.8.0.1, UDP 51820
- Revert: `sudo rm <prefix>/etc/wireguard/wg0.conf`

## 7. Packet forwarding, runtime only

- Change: `sudo sysctl -w net.inet.ip.forwarding=1`
- Revert: `sudo sysctl -w net.inet.ip.forwarding=0`
- Side effect worth recording: the operating system disabled its private relay feature while forwarding is on, because the machine is now acting as a router

## 8. Firewall address translation rule

- Change: rule file written and loaded into a dedicated anchor; the system firewall configuration was not edited
- Revert: `sudo pfctl -a com.apple/wireguard -F all && sudo rm /etc/pf.anchors/wireguard.nat`. The firewall itself was already enabled by the system, so it was left enabled.

## 9. Tunnel up

- Change: `sudo wg-quick up <prefix>/etc/wireguard/wg0.conf`
- Revert: `sudo wg-quick down <prefix>/etc/wireguard/wg0.conf`

## 10. Dynamic DNS hostname and token

- Change: hostname `YOURNAME` registered; token stored at `<prefix>/etc/wireguard/duckdns.token`, permissions 600; first update pushed
- Revert: delete the token file, delete the subdomain in the provider's dashboard

## 11. Router port forward

- Change: UDP 51820 forwarded to `SERVER_LAN_IP`
- Revert: delete the rule, apply changes

## 12. Client keys and peer entry

- Change: client keypair and preshared key generated; `[Peer]` block for 10.8.0.2/32 appended to `wg0.conf`; tunnel restarted
- Revert: remove the peer block, delete the client key files, restart the tunnel

## 13. Client profiles

- Change: full tunnel and split tunnel profiles written under `clients/`, permissions 600, transferred by QR code
- Revert: delete the directory; delete the tunnels in the client application

## 14. Boot persistence

- Change: boot script plus a system daemon that runs it at startup and every ten minutes. It re-applies forwarding, reloads the firewall anchor, brings the tunnel up if it is down, and refreshes the dynamic DNS record.
- Revert: unload the daemon, delete the daemon definition and the script

## 15. On-demand activation on the phone

- Change: full tunnel profile set to connect automatically on any Wi-Fi except the home networks
- Revert: turn on-demand activation off in the client application

## 16. Hardening pass

- Universal plug and play disabled on the router, after finding a stale rule it had opened for a device that was no longer even switched on. Revert: re-enable it.
- Commercial VPN client uninstalled, including its network extension, because a second system-wide VPN breaks this one. Revert: reinstall it.
- Secure shell enabled for one named user only. Revert: turn remote login off.
- Application firewall enabled. "Block all incoming connections" deliberately left off, because blocking all incoming would break both the VPN and secure shell.
- Confirmed already correct: full disk encryption on, all other sharing services off, guest account off, one administrator account.

## 17. Server on and off switch

- Change: a small root-owned control script with `on`, `off` and `status`; a sudo rule allowing one named user to run only that script without a password; two shortcuts in the desktop shortcuts application calling it. Needed because running any other VPN on the same machine breaks this one, so turning the server off cleanly is a routine operation.
- Revert: delete the script, the sudo rule and the shortcuts.
- Also recorded here: the boot script's health check originally tested for an interface named `wg0`, which never matches on macOS because tunnels are named `utunN`. Corrected to test `wg show interfaces`.

## 18. Exit nodes

- Hosting provider account created, API key stored at `exits/provider.token`, permissions 600. Revert: delete the key in the provider's dashboard, delete the file, close the account if unused.
- Provider command line tool installed. Revert: uninstall it.
- SSH keypair generated and its public half registered with the provider. Revert: delete the key at the provider, delete the local keypair.
- Four dynamic DNS hostnames, one per region. Revert: delete them in the provider's dashboard.
- `exits/` directory containing the tool, region configuration, roaming client keys and per-region key folders. Revert: destroy every running exit, then delete the directory.
- Client profile for one region added to the phone. Revert: delete the tunnel in the client application.
