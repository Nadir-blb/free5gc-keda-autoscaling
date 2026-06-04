#!/bin/sh
# UPF startup wrapper — detects own N4/N3 IPs at runtime (whereabouts assigns them)
# and rewrites upfcfg.yaml before starting the UPF binary.
set -e
sleep 2

N4_IP=$(ip -4 addr show n4 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]}')
N3_IP=$(ip -4 addr show n3 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]}')

if [ -z "$N4_IP" ] || [ -z "$N3_IP" ]; then
  echo "ERROR: N4=$N4_IP N3=$N3_IP — interfaces not ready"; exit 1
fi

echo "UPF starting: N4=$N4_IP  N3=$N3_IP"
cp /free5gc/config/upfcfg.yaml /tmp/upfcfg.yaml
sed -i "s|nodeID:.*|nodeID: ${N4_IP}|g"                  /tmp/upfcfg.yaml
sed -i "s|addr: 10\.100\.50\.24[0-9]|addr: ${N4_IP}|g"  /tmp/upfcfg.yaml
sed -i "s|addr: 10\.100\.50\.23[0-9]|addr: ${N3_IP}|g"  /tmp/upfcfg.yaml

# NAT masquerade for UE traffic (covers both internet and intra-cluster destinations)
iptables -A FORWARD -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.1.0.0/16 -j MASQUERADE
echo "1200 n6if" >> /etc/iproute2/rt_tables 2>/dev/null || true
ip rule add from 10.1.0.0/16 table n6if 2>/dev/null || true
ETH0_GW=$(ip route show dev eth0 | awk '/default/{print $3}')
ip route add default via "$ETH0_GW" dev eth0 table n6if 2>/dev/null || true

exec /free5gc/upf/upf -c /tmp/upfcfg.yaml
