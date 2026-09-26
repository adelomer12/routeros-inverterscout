# Keeps InverterScout rules valid across /app redeploys:
#  - updates the ISCOUT-CONTAINER address list when the container IP changes
#  - re-points AGH-ISO bridge filters if they turned INVALID after an AdGuard redeploy
# Writes only when something changed (each set is a flash write).

/system script
add name=iscout-ip-sync policy=read,write source={
:local a [:tostr [/interface veth get [find name="veth-app-inverterscout"] address]]
:local ip [:pick $a 0 [:find $a "/"]]
:local e [/ip firewall address-list find list=ISCOUT-CONTAINER]
:if ([:len $e] = 1 && [/ip firewall address-list get $e address] != $ip) do={
  /ip firewall address-list set $e address=$ip
  :log warning "ISCOUT container IP changed -> $ip"
}
:if ([:len [/interface bridge filter find where invalid and comment~"AGH-ISO"]] > 0) do={
  /interface bridge filter set [find comment~"AGH-ISO: containers->"] out-interface=veth-app-adguardhome
  /interface bridge filter set [find comment~"AGH-ISO: AdGuard->"] in-interface=veth-app-adguardhome
  :log warning "AGH-ISO bridge filters re-pointed to new AdGuard veth"
}
}

/system scheduler
add name=iscout-ip-sync interval=5m start-time=startup on-event=iscout-ip-sync policy=read,write

# Test once:
# /system script run iscout-ip-sync
# Script messages only (config-change audit lines also match the comments):
# /log print where topics~"warning" and message~"ISCOUT|AGH-ISO"
