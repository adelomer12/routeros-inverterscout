# Isolate AdGuard Home from every other /app container except DNS.
#
# Why: containers on the same /app bridge ("internal") talk at L2; the IP
# firewall never sees that traffic. A compromised container could otherwise
# reach AdGuard's admin UI directly.
#
# Why anchored on AdGuard's veth only: /app recreates a container's veth on
# every redeploy, with a new internal ID. Rules referencing the redeployed
# veth turn INVALID ("*29") and are silently ignored. Anchoring on the side
# redeployed least keeps isolation intact and also covers future containers.
#
# Do NOT use /interface bridge settings use-ip-firewall=yes instead: it is
# global and pushes all bridged LAN traffic through the IP firewall.
#
# Bridge filter is stateless (no connection-state): replies are allowed by
# src-port=53, everything else is dropped.

/interface bridge filter
add chain=forward out-interface=veth-app-adguardhome mac-protocol=ip ip-protocol=udp dst-port=53 \
    action=accept comment="AGH-ISO: containers->AdGuard DNS udp"
add chain=forward out-interface=veth-app-adguardhome mac-protocol=ip ip-protocol=tcp dst-port=53 \
    action=accept comment="AGH-ISO: containers->AdGuard DNS tcp"
add chain=forward out-interface=veth-app-adguardhome mac-protocol=ip \
    action=drop comment="AGH-ISO: containers->AdGuard deny rest"

add chain=forward in-interface=veth-app-adguardhome mac-protocol=ip ip-protocol=udp src-port=53 \
    action=accept comment="AGH-ISO: AdGuard->containers DNS replies udp"
add chain=forward in-interface=veth-app-adguardhome mac-protocol=ip ip-protocol=tcp src-port=53 \
    action=accept comment="AGH-ISO: AdGuard->containers DNS replies tcp"
add chain=forward in-interface=veth-app-adguardhome mac-protocol=ip \
    action=drop comment="AGH-ISO: AdGuard->containers deny rest"

# Verify (no "I" flag):
# /interface bridge filter print where comment~"AGH-ISO"
# After any AdGuard redeploy:
# /interface bridge filter print where invalid
