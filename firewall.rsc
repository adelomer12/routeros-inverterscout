# InverterScout rules for a DEFAULT-DENY forward chain (RouterOS 7).
#
# 1. Edit the variables below.
#    containerIP : from  /interface veth print where name~"inverterscout"
#    dropComment : exact comment of your final forward drop rule
# 2. Paste the WHOLE block, including the braces.
#
# The block aborts before changing anything if the drop rule is not found,
# and inserts every filter rule directly above it (order preserved).

{
:local dropComment "FORWARD: default deny"
:local containerIP "172.18.0.3"
:local containerBridge "internal"
:local dongleIP "192.168.88.50"
:local mgmtNet "192.168.88.128/26"
:local vpnNet "10.99.0.0/24"

:local dropId [/ip firewall filter find where chain=forward and action=drop and comment=$dropComment]
:if ([:len $dropId] = 0) do={ :error "default-deny rule not found - nothing added" }

/ip firewall address-list
add list=ISCOUT-CONTAINER address=$containerIP comment="InverterScout container IP (kept in sync by iscout-ip-sync)"
add list=ISCOUT-INVERTER address=$dongleIP comment="LuxPower WiFi dongle"
add list=ISCOUT-ADMIN address=$mgmtNet comment="ISCOUT UI: management subnet"
add list=ISCOUT-ADMIN address=$vpnNet comment="ISCOUT UI: VPN"

/ip firewall filter
# Container -> inverter dongle (read-only Modbus over TCP)
add chain=forward action=accept protocol=tcp src-address-list=ISCOUT-CONTAINER \
    in-interface=$containerBridge dst-address-list=ISCOUT-INVERTER dst-port=8000 \
    comment="ISCOUT: inverter polling (read-only Modbus TCP)" place-before=$dropId

# Container -> internet, HTTPS only (Telegram Bot API, Tuya cloud for Local Keys)
add chain=forward action=accept protocol=tcp src-address-list=ISCOUT-CONTAINER \
    in-interface=$containerBridge out-interface-list=WAN dst-port=443 \
    comment="ISCOUT: outbound HTTPS (Telegram, Tuya cloud)" place-before=$dropId

# Web UI: management + VPN only, and only via the /app dstnat.
# Port is the CONTAINER port (8080): forward sees the packet after dstnat.
add chain=forward action=accept protocol=tcp src-address-list=ISCOUT-ADMIN \
    dst-address-list=ISCOUT-CONTAINER dst-port=8080 connection-nat-state=dstnat \
    comment="ISCOUT: web UI from mgmt/VPN via /app dstnat" place-before=$dropId

# Optional - only if you add Tapo/Tuya devices in InverterScout:
# /ip firewall address-list add list=ISCOUT-SMART address=192.168.88.60 comment="smart plug"
# add chain=forward action=accept protocol=tcp src-address-list=ISCOUT-CONTAINER \
#     in-interface=$containerBridge dst-address-list=ISCOUT-SMART dst-port=80,443,6668 \
#     comment="ISCOUT: smart devices LAN control" place-before=$dropId

/ip firewall nat
# If you have policy-routing srcnat rules above your general masquerade,
# move this next to the rule used for your other containers.
add chain=srcnat action=masquerade src-address-list=ISCOUT-CONTAINER out-interface-list=WAN \
    ipsec-policy=out,none comment="inverterscout"
}

# Verify:
# /ip firewall filter print where comment~"ISCOUT" or comment="FORWARD: default deny"
# /ip firewall nat print where comment="inverterscout"
