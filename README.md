# routeros-inverterscout

Run [InverterScout](https://github.com/albond/InverterScout) — a self-hosted, read-only LuxPower SNA inverter monitor with Telegram alerts — as a **RouterOS `/app` container** on a MikroTik ARM64 router (tested on an RB5009, RouterOS 7.22+), alongside AdGuard Home, behind a **default-deny** firewall.

This repo is a deployment kit, not a fork of the application. The application is © albond, MIT. This kit is not affiliated with the upstream project.

> **Status:** InverterScout is alpha software. Running third-party code on the device that is also your firewall is a real trade-off — read [Security notes](#security-notes) before deploying. If you have a NAS/home server, running it there with the upstream `docker-compose.yml` keeps all upstream hardening intact.

## What's in here

| File | Purpose |
|---|---|
| `inverterscout.tikapp.yaml` | `/app` definition (ports, volume, non-root user) |
| `firewall.rsc` | Address lists, forward rules and masquerade for a default-deny forward chain |
| `bridge-isolation.rsc` | Bridge filter rules that isolate AdGuard from every other container except DNS |
| `iscout-ip-sync.rsc` | Scheduled script that keeps rules valid when `/app` reassigns IPs or veth IDs |

## Architecture

```
  mgmt PC / VPN ──► router-ip:8088 ──(/app dstnat)──► 172.18.0.x:8080  InverterScout
                                                          │
                         ┌────────────────────────────────┼─────────────────────┐
                         ▼                                ▼                     ▼
              LuxPower WiFi dongle:8000         AdGuard (DNS only)     WAN tcp/443
              (read-only Modbus TCP)            bridge-filtered         Telegram / Tuya cloud
```

Everything not listed above is dropped by the forward chain's default deny.

## Requirements

- MikroTik ARM64 device (RB5009 or similar), RouterOS **7.22+** with the `container` package and device-mode `container=yes`
- External USB/NVMe storage for container layers and volumes (never internal NAND)
- Enough free RAM: InverterScout idles around 40–60 MiB; check `/system resource print` first, especially if AdGuard is already running
- A LuxPower SNA inverter with the WiFi dongle reachable on TCP 8000 (SNA5000 WPV is the upstream-verified model)

## 1. Get an arm64 image

Upstream publishes no image, and RouterOS cannot build one. Two options:

**A. GitHub Actions (recommended).** Fork upstream and add the workflow from [adelomer12/InverterScout](https://github.com/adelomer12/InverterScout) (`.github/workflows/ghcr-arm64.yml`). It builds on GitHub's native ARM64 runner with `GITHUB_TOKEN` — no personal token, no emulation.

**B. Manual buildx on any x86 Linux host** (Unraid, WSL, …):

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
docker buildx create --name armbuilder --driver docker-container --use

# inside the upstream source tree, at a release tag
docker buildx imagetools inspect "$(grep '^FROM' Dockerfile | awk '{print $2}')" | grep -E 'MediaType|Platform'
#   must be an index that lists linux/arm64; if not, drop the @sha256 pin in FROM

echo "$GHCR_PAT" | docker login ghcr.io -u <user> --password-stdin   # CLASSIC token, write:packages
docker buildx build --platform linux/arm64 --provenance=false --sbom=false \
  -t ghcr.io/<user>/inverterscout:<tag>-arm64 --push .
docker logout ghcr.io
```

Notes:
- GHCR expects a **classic** PAT (`ghp_…`). Fine-grained tokens (`github_pat_…`) are the most common cause of `unauthorized`.
- `--provenance=false --sbom=false` keeps the result a plain single-platform manifest (no `unknown/unknown` attestation entries).
- If a wheel fails to compile on `python:3.14-slim`, switch `FROM` to `python:3.13-slim`.

Then make the package **public** (GitHub → Packages → inverterscout → Package settings) so the router pulls anonymously and no registry credentials live in the router config. The image contains no secrets; all credentials are entered at runtime and stored encrypted on the volume.

## 2. Deploy the /app

Add `inverterscout.tikapp.yaml` the same way as any custom `/app` (WinBox/WebFig → App → Add). Before that, make sure the host port is free:

```routeros
/ip firewall nat print where dst-port~"8088"
/ip service print where port=8088
/ip proxy print          # web proxy defaults to 8080
```

After deploying:

```routeros
/container print detail where name~"inverterscout"
/interface veth print where name~"inverterscout"     # note the container IP
/ip firewall nat print where comment~"app inverterscout"   # must show dst-port=8088 -> to-ports=8080
```

## 3. Firewall

Edit the variables at the top of `firewall.rsc` (container IP from the veth, dongle IP, management and VPN subnets, the comment of your final forward drop rule) and paste the whole block. It aborts without changing anything if your default-deny rule is not found, and inserts every rule directly above it.

Rules reference the container through the `ISCOUT-CONTAINER` address list, so a changed container IP means updating one entry (or letting the sync script do it).

## 4. Container isolation

Containers on the same `/app` bridge talk at L2 — the IP firewall never sees that traffic. `bridge-isolation.rsc` adds bridge filter rules anchored on AdGuard's veth: other containers may reach it on port 53 only, and it may not open connections to them. Because the rules name only AdGuard's veth, they cover future containers too and survive InverterScout redeploys.

## 5. Keep things in sync

`iscout-ip-sync.rsc` installs a script + 5-minute scheduler that:
- updates `ISCOUT-CONTAINER` when `/app` gives the container a new IP;
- re-points the AdGuard isolation rules if they turned invalid after an AdGuard redeploy.

It only writes when something actually changed (every `set` is a flash write).

## 6. Verify

```routeros
/container shell app-inverterscout
```

```sh
# outbound HTTPS -> expect 200
python3 -c "import urllib.request;print(urllib.request.urlopen('https://api.telegram.org',timeout=8).status)"
# inverter dongle -> expect 0
python3 -c "import socket;s=socket.socket();s.settimeout(3);print(s.connect_ex(('DONGLE_IP',8000)))"
# AdGuard web UI -> expect 11 (blocked)
python3 -c "import socket;s=socket.socket();s.settimeout(3);print(s.connect_ex(('ADGUARD_IP',80)))"
# DNS -> expect an IP address
python3 -c "import socket;print(socket.gethostbyname('api.telegram.org'))"
exit
```

From a management host: `curl -v http://ROUTER_IP:8088` should return an HTTP response; from any other LAN host it should time out.

## 7. Check for internet exposure (do this before entering credentials)

`/app` can create `/ip reverse-proxy` entries on your MikroTik cloud DDNS name (`<app>.<id>.routingthecloud.com`) with `use-https=yes`.

```routeros
/ip reverse-proxy print
```

If an entry exists for the app, open that hostname from a phone on **mobile data**. It must time out. If it loads, drop tcp/443 from `in-interface-list=WAN` in the input chain above any accept rule.

## Gotchas we hit

1. **Port with IP prefix is mis-parsed.** `"192.168.88.1:8088:8080/tcp:web"` becomes a dstnat on `dst-port=192`. Use `"8088:8080/tcp:web"`; `/app` binds to the router IP itself.
2. **Host-port collisions between apps.** AdGuard's `/app` commonly publishes `8080`. Two dstnat rules on the same port: first one wins.
3. **Every redeploy can change the container IP** (`.3` → `.4`) — hence the address list + sync script.
4. **Every redeploy recreates the veth with a new internal ID.** Bridge filter rules referencing it turn `INVALID` (shown as `*29`) and are silently ignored — isolation fails open. Anchor rules on the side that is redeployed least.
5. **`use-ip-firewall` is global** (`/interface bridge settings`), not per bridge. Enabling it pushes *all* bridged LAN traffic through the IP firewall — with a default-deny forward chain that breaks same-subnet LAN traffic. Use bridge filters instead.
6. **Bridge filter is stateless** — no `connection-state`. Allow replies by `src-port=53`, then drop.
7. **`/container stop` doesn't stick.** `/app` restarts the container within ~30 s. Use `/app disable [find name=inverterscout]` / `/app enable …`.
8. **Never put `INVERTERSCOUT_MASTER_KEY` in the YAML** — `/app` YAML is part of the router config and shows up in every `/export`.

## Operations

- **Stop / start:** `/app disable|enable [find name=inverterscout]` (then run `/system script run iscout-ip-sync`).
- **Update:** build/push a new tag, change `image:` in the YAML, redeploy, check the veth IP against `ISCOUT-CONTAINER`. Data lives on the volume and survives.
- **Backup:** the volume holds `inverterscout.db` and `.master.key`. The database is useless without the key; store the key backup separately from router config exports.
- **Polling:** if Home Assistant also polls the same dongle, give InverterScout a noticeably slower interval — the dongle's TCP server does not handle multiple busy clients well.

## Security notes

- Upstream's Compose hardening (`cap_drop: ALL`, read-only rootfs, `no-new-privileges`) does not fully carry over to RouterOS `/app`. The container runs as non-root UID 10001, which is the main remaining control.
- The app stores Telegram, Tapo and Tuya credentials (encrypted). A compromise of the container is a compromise on your router — keep egress minimal (as in `firewall.rsc`) and the UI LAN/VPN-only.
- Never port-forward, UPnP, or tunnel the web UI. Use Telegram or a VPN when away.

## License

MIT — see `LICENSE`. InverterScout itself is MIT-licensed by its author.
