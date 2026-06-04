#!/bin/bash
# Switch UPF N3/N4/N6 NADs from static IPAM to whereabouts pools
# Run once after deploying free5GC
NS=free5gc

kubectl patch network-attachment-definition -n $NS n3network-free5gc-free5gc-upf --type=merge -p \
  '{"spec":{"config":"{\"cniVersion\":\"0.3.1\",\"plugins\":[{\"type\":\"ipvlan\",\"capabilities\":{\"ips\":true},\"master\":\"eth0\",\"mode\":\"l2\",\"ipam\":{\"type\":\"whereabouts\",\"range\":\"10.100.50.232/29\",\"range_start\":\"10.100.50.233\",\"range_end\":\"10.100.50.237\",\"gateway\":\"10.100.50.238\"}}]}"}}'

kubectl patch network-attachment-definition -n $NS n4network-free5gc-free5gc-upf --type=merge -p \
  '{"spec":{"config":"{\"cniVersion\":\"0.3.1\",\"plugins\":[{\"type\":\"ipvlan\",\"capabilities\":{\"ips\":true},\"master\":\"eth0\",\"mode\":\"l2\",\"ipam\":{\"type\":\"whereabouts\",\"range\":\"10.100.50.240/29\",\"range_start\":\"10.100.50.241\",\"range_end\":\"10.100.50.245\",\"gateway\":\"10.100.50.246\"}}]}"}}'

kubectl patch network-attachment-definition -n $NS n6network-free5gc-free5gc-upf --type=merge -p \
  '{"spec":{"config":"{\"cniVersion\":\"0.3.1\",\"plugins\":[{\"type\":\"ipvlan\",\"capabilities\":{\"ips\":true},\"master\":\"eth0\",\"mode\":\"l2\",\"ipam\":{\"type\":\"whereabouts\",\"range\":\"10.100.100.0/24\",\"range_start\":\"10.100.100.12\",\"range_end\":\"10.100.100.20\",\"gateway\":\"10.100.100.1\"}}]}"}}'

echo "NADs patched to whereabouts IPAM"
