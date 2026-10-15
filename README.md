# Meridian

A self-hosted VPN built from parts, so there is no subscription to pay. It has two halves that work independently:

1. **A home server.** WireGuard on a machine at home, reachable from anywhere, so a phone on public Wi-Fi gets an encrypted tunnel back to the house and remote access to the home network.
2. **On-demand exit nodes.** A command line tool that creates a WireGuard server in any of about 30 cities worldwide, hands the phone a profile, and destroys the server when it is no longer wanted. Billed by the hour, so a weekend costs pennies.

Built and documented by [Temi Peters](https://github.com/Temi-Peters). Everything here is the real configuration with personal identifiers replaced by placeholders.

## Why

Commercial VPN providers solve a real problem, but you have to trust them, the subscription runs whether you use it or not, and you never learn how any of it works. This does the same job on infrastructure I control, for roughly the price of a coffee per year, and the learning was the point.

## What it looks like in use

On the phone, the WireGuard app lists tunnels and you tap one:

```
Home Full     all traffic through the house
Home Split    only home addresses through the house
Exit ams      all traffic, exits in Amsterdam
Exit nyc      all traffic, exits in New York
```

On the Mac, exits are one command each:

```
$ sudo exit.sh up ams
created instance a1b2c3d4 in ams, waiting for an IP...
DNS: example-ams.duckdns.org -> 203.0.113.45 (OK)
Server is installing WireGuard now; give it about two minutes before connecting.

$ sudo exit.sh list
REGION   IP               STATUS      HOURS     COST
ams      203.0.113.45     active        1.4 $  0.010

$ sudo exit.sh down ams
destroyed exit-ams (a1b2c3d4). Billing stopped. Keys and DNS name kept for next time.
```

## How it works, briefly

A WireGuard peer is just a keypair. The private key never leaves the device it belongs to; the public key is handed to whoever needs to recognise it. There is no login, no certificate authority, and no server-versus-client distinction in the protocol itself.

**Home server.** The server holds a private subnet (10.8.0.0/24) and listens on one UDP port. The router forwards that port to it. Because home broadband addresses change, a dynamic domain name record follows the address, so clients always connect by name. Packet forwarding and address translation on the server let client traffic exit through the home connection and find its way back.

**Exit nodes.** Each region keeps a permanent identity on the control machine: a server keypair, preshared keys, and a domain name. Creating an exit provisions a virtual machine, injects that region's existing private key through cloud-init, and repoints the region's domain name at the new address. The phone therefore scans one QR code per city, ever, and every later server in that city works with the profile it already has.

Full detail in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Reproduction instructions in [docs/SETUP.md](docs/SETUP.md).

## Repository contents

| Path | What it is |
|---|---|
| `docs/ARCHITECTURE.md` | Design, decisions, trade-offs, threat model |
| `docs/SETUP.md` | Build it yourself, from nothing to a working tunnel |
| `docs/RUNBOOK.md` | Operating the thing: add a device, rotate a key, diagnose faults |
| `scripts/exit.sh` | The exit node tool |
| `scripts/cloud-init.example.yaml` | What gets installed on each exit server |
| `UNDO.example.md` | The rollback log, kept during the real build |

## Design decisions worth defending

**Stable keys per region.** Fresh keys on every provision would be marginally safer, but would mean re-scanning a QR code every single time. Since the provider already runs the machine your traffic exits from, injecting a stable key through their API adds little exposure for a large usability gain. The trade-off is deliberate and stated here.

**Destroy, never stop.** Cloud providers keep billing for a stopped instance because the disk and address still exist. The tool has no stop command for that reason.

**UDP 443 as well as 51820.** Networks that filter aggressively often allow anything that looks like web traffic. Listening on 443 as well gets through most hotel and cafe filters. It is not a disguise: a deep packet inspection system still sees WireGuard.

**Firewall rules in their own anchor.** On macOS the firewall rules load into their own anchor and leave the system firewall configuration untouched, so nothing the operating system owns is changed and removal is a single flush.

**Everything reversible.** Every system change made during the build went into a rollback log with the exact command to undo it, written at the time of each change. [UNDO.example.md](UNDO.example.md) is that log.

## Honest limitations

- Streaming services detect and block datacenter addresses, so exits generally fail on Netflix and similar. The home server is the only residential-looking exit.
- A personal exit address is used by one person, so it identifies a session across sites in a way a shared commercial address does not. This gives privacy from the local network and the internet provider, not anonymity from the destination.
- The hosting provider knows who you are, because they bill you, and can see traffic leaving their network. That is the same trust placed in a commercial VPN, moved to a different company.
- A home server is only reachable while the machine is awake and the home connection is up.
- Networks that block all UDP defeat this. A TCP-based wrapper would be the answer and is not implemented here.

## Status

Running and in daily use as of September 2026. The home server currently runs on a laptop, which means the home half is only reachable while that machine is home and awake. The exit half has no such dependency. Moving the home server to dedicated always-on hardware is documented as an optional next step.

## License

MIT. See [LICENSE](LICENSE).
