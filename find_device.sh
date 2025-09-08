#!/bin/bash

#
# Find Nerves devices on the local network
#

echo "Searching for Nerves devices on the network..."
echo ""

# Try mDNS first
echo "Trying mDNS (nerves.local)..."
if ping -c 1 -W 1 nerves.local >/dev/null 2>&1; then
    IP=$(ping -c 1 nerves.local | grep PING | sed -E 's/.*\(([0-9.]+)\).*/\1/')
    echo "✓ Found device at nerves.local ($IP)"
    echo ""
    echo "To upload firmware: ./upload.sh nerves.local"
    echo "To SSH into device: ssh nerves.local"
else
    echo "✗ nerves.local not found"
fi

echo ""

# Look for devices with port 22 open on local subnet
echo "Scanning local network for SSH (port 22)..."
SUBNET=$(ip route | grep default | awk '{print $3}' | sed 's/\.[0-9]*$//')

if [ -n "$SUBNET" ]; then
    echo "Scanning $SUBNET.0/24..."
    for i in {1..254}; do
        IP="$SUBNET.$i"
        if timeout 0.1 nc -z $IP 22 2>/dev/null; then
            echo "✓ Found SSH at $IP"
            # Try to get hostname
            HOSTNAME=$(timeout 1 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=1 $IP hostname 2>/dev/null || echo "unknown")
            if [[ $HOSTNAME == *"nerves"* ]]; then
                echo "  → Likely a Nerves device (hostname: $HOSTNAME)"
                echo "  → To upload: ./upload.sh $IP"
            fi
        fi
    done
else
    echo "Could not determine local subnet"
fi

echo ""
echo "Done scanning."