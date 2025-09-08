#!/bin/sh

#
# Upload new firmware to a Nerves device over SSH
#
# Usage:
#   upload.sh [destination]
#
# Default destination is "nerves.local"
# The destination is an SSH destination. Any valid "scp" destination should work.
#
# You may need to run "mix firmware" first to create the firmware file.
#
# Environment variables:
#   MIX_TARGET - The mix target (defaults to rpi3)
#   MIX_ENV - The mix environment (defaults to dev)
#

set -e

DESTINATION="${1:-nerves.local}"
MIX_TARGET="${MIX_TARGET:-rpi3}"
MIX_ENV="${MIX_ENV:-dev}"

FIRMWARE_PATH="./_build/${MIX_TARGET}_${MIX_ENV}/nerves/images/aprstx.fw"

# Check if firmware file exists
if [ ! -f "$FIRMWARE_PATH" ]; then
    echo "Firmware file not found at $FIRMWARE_PATH"
    echo "Run 'MIX_TARGET=$MIX_TARGET MIX_ENV=$MIX_ENV mix firmware' to build the firmware first"
    exit 1
fi

echo "Uploading $FIRMWARE_PATH to $DESTINATION..."
echo "Target: $MIX_TARGET, Environment: $MIX_ENV"

# Upload firmware using SSH subsystem
cat "$FIRMWARE_PATH" | ssh -s $DESTINATION fwup

echo ""
echo "✓ Firmware uploaded successfully!"
echo "The device will reboot with the new firmware."