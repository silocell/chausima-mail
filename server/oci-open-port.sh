#!/bin/bash
# Run in Oracle Cloud Shell: opens a TCP port in the HEH-Live subnet's security
# list(s), copying the source of the existing rule for a reference port.
# Usage: bash oci-open-port.sh 995 993
set -e
NEW=${1:?port}; REF=${2:?reference port}
source ~/heh.env
VNIC=$(oci compute vnic-attachment list -c $C --instance-id $INST --query 'data[0]."vnic-id"' --raw-output)
SUBNET=$(oci network vnic get --vnic-id $VNIC --query 'data."subnet-id"' --raw-output)
NSGS=$(oci network vnic get --vnic-id $VNIC --query 'data."nsg-ids"' --raw-output)
echo "NSGs on the VNIC: $NSGS"
for SL in $(oci network subnet get --subnet-id $SUBNET --query 'data."security-list-ids"[]' --raw-output | tr -d '[]",'); do
  oci network security-list get --security-list-id $SL --query 'data."ingress-security-rules"' > /tmp/in.json
  if jq -e --argjson p $NEW 'any(.[]; .protocol=="6" and (."tcp-options"."destination-port-range".min // -1) <= $p and (."tcp-options"."destination-port-range".max // -1) >= $p)' /tmp/in.json >/dev/null; then
    echo "$SL: $NEW already open"; continue; fi
  if ! jq -e --argjson p $REF 'any(.[]; .protocol=="6" and ."tcp-options"."destination-port-range".min == $p)' /tmp/in.json >/dev/null; then
    echo "$SL: no rule for $REF, skipped"; continue; fi
  jq --argjson p $NEW --argjson r $REF '. + [ (map(select(.protocol=="6" and ."tcp-options"."destination-port-range".min == $r)) | .[0]
     | ."tcp-options"."destination-port-range" = {"min":$p,"max":$p} | .description = "POP3S (Chausima Mail)") ]' /tmp/in.json > /tmp/in2.json
  echo "$SL: $(jq length /tmp/in.json) -> $(jq length /tmp/in2.json) rules"
  oci network security-list update --security-list-id $SL --ingress-security-rules file:///tmp/in2.json --force --query 'data."lifecycle-state"' --raw-output
done
