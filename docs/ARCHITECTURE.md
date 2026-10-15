# Architecture

## Vocabulary

Four terms carry most of the design. Worth pinning down before the diagrams.

**Keypair.** A WireGuard identity. The private key stays on its device and is never shown. The public key is safe to publish and is how peers recognise each other. No accounts, no passwords, no certificate authority.

**Peer.** Any device in the network. WireGuard has no built-in notion of client and server; those are roles we impose by deciding which peer has a fixed address and listens, and which peer roams and initiates.

**AllowedIPs.** Means two different things depending on which side you read it from. On a listening peer it is access control: "this peer owns 10.8.0.2 and may not claim anything else." On a roaming peer it is routing: "send these destinations through the tunnel." Setting it to 0.0.0.0/0 sends everything (full tunnel); listing specific subnets sends only those (split tunnel).

**Address translation.** Packets leaving the tunnel carry a source address from the tunnel's private range, which is meaningless on the public internet, so replies could never return. Translation rewrites the source to the server's own public address on the way out and reverses it for replies.

## Part one: the home server

```
phone on hotel Wi-Fi
   |
   |  encrypted, UDP to hostname.example.org:51820
   v
home router  --- port forward UDP 51820 --->  server (192.168.x.x)
                                                 |
                                       decrypt, translate address
                                                 |
                                                 v
                                        home internet connection
                                                 |
                                                 v
                                            destination
```

The server holds 10.8.0.1 on a private tunnel subnet, deliberately different from the home LAN range so the two never collide. Each client device gets an address in that subnet and a peer entry naming its public key.

Three things had to be true for this to work from outside:

1. **A reachable address.** The connection must not be behind carrier-grade address translation, where an internet provider shares one public address across many customers and inbound connections are impossible. Verified by comparing the address the router reports against the address the internet sees. If they differ, this design needs a rented relay instead.
2. **A stable name.** Home addresses change. A dynamic domain name record, refreshed on a timer, keeps a hostname pointing at the current address so clients never need to know it.
3. **A forwarded port.** One UDP port, forwarded to a reserved local address for the server, so the router's assignment cannot drift.

**Two client profiles, same identity.** Full tunnel for untrusted networks. Split tunnel, listing only the home subnet and the tunnel subnet, when the goal is reaching home without routing everything through it. Both use the same device keypair, so only one runs at a time, which matches how they are used.

**On-demand activation.** The phone's VPN client can arm itself automatically on any Wi-Fi network except a named list. Listing only the home networks means every unknown network gets a tunnel before anything leaks.

### Why WireGuard is silent

WireGuard does not respond to anything that is not a correctly signed handshake from a known peer. A port scan of the house looks identical whether the service is running or not. This is good for exposure and mildly awkward for testing, since the only real proof is a successful handshake from outside.

## Part two: on-demand exit nodes

```
control machine (the tool)                cloud provider, one region
--------------------------                ----------------------------
exit.sh up tokyo
  |
  |-- create instance, pass cloud-init --> VM boots
  |                                        installs WireGuard
  |                                        writes config with this
  |                                        region's stable server key
  |                                        forwarding, translation,
  |                                        firewall, service enabled
  |
  |<------ poll until an address exists ---|
  |
  |-- update dynamic DNS: tokyo.example.org -> new address
  |
  v
phone: tunnel "Exit tokyo" already configured, just connect
```

### The identity decision

Each region owns a permanent set of secrets on the control machine:

```
exits/
  provider.token           API credential, readable only by root
  regions.conf             region code -> hostname
  roaming-phone.key/.pub   one identity per client device
  roaming-mac.key/.pub
  ams/
    server.key server.pub  this region's permanent server identity
    psk-phone psk-mac      preshared keys, one per client
    phone.conf mac.conf    generated client profiles
```

Because the server key is permanent and the hostname is permanent, a client profile for a region never changes. Scan once, use forever, across any number of destroyed and recreated servers.

The cost of that choice: the server private key travels through the provider's API and rests in the instance's metadata. A malicious provider could impersonate that exit. Weighed against the fact that the provider already operates the physical machine your plaintext leaves from, and that the alternative is re-scanning a QR code every single time, the trade is worth making. It is a deliberate decision, not an oversight.

### What cloud-init builds

Cloud-init is the standard mechanism for configuring a virtual machine on first boot. The tool renders a configuration file per launch containing that region's keys, and the provider passes it to the instance. On boot the machine installs WireGuard and a firewall, writes the tunnel configuration and the peer entries for each client device, enables packet forwarding, applies firewall rules, and starts the tunnel as a system service. Boot to ready is under two minutes.

Firewall shape:

- Inbound: drop by default; allow established connections, loopback, diagnostics, secure shell, and the tunnel's two UDP ports.
- Forwarding: drop by default; allow anything arriving on the tunnel interface, and return traffic.
- Translation: rewrite the source address for anything leaving the tunnel subnet by another interface. Redirect UDP 443 to the tunnel port so filtered networks still get through.

### Cost model

Instances bill by the hour with a one-hour minimum, so every launch costs at least the price of an hour regardless of how briefly it lives. A stopped instance still bills, because the disk and address persist, which is why the tool destroys instances outright. In practice, launch one exit per outing and keep it for the whole outing.

## Threat model

**Protects against:** anyone on the local network reading or altering traffic; the network operator profiling browsing; exposure of home services, since only one silent UDP port faces the internet; having to trust a commercial provider's claims about what they log.

**Does not protect against:** the internet provider at whichever end traffic exits, who sees the same as always; websites, which see a real address belonging to a real person; malware on the devices themselves; a compromise of the server, which is now the most valuable machine in the house; a legal request to the hosting provider, who holds billing details.

**Where the trust sits.** The honest summary is that this setup still relies on trust, now placed in parties chosen deliberately and in hardware under direct control.

## What would change at larger scale

- A rented always-on machine as a permanent hub would fix the home server's dependence on a particular machine being awake, and would provide a relay for connections behind carrier-grade address translation.
- Infrastructure-as-code tooling would replace the shell script once more than a handful of regions or a second operator were involved.
- A wrapper presenting the tunnel as ordinary encrypted web traffic over TCP would defeat networks that block UDP entirely, at a cost in throughput.
