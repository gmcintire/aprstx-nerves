# Makefile for Nerves Aprx project
# 
# Targets:
#   make firmware    - Build production firmware (default)
#   make dev         - Build development firmware
#   make burn        - Burn firmware to SD card
#   make upload      - Upload firmware over network (SSH)
#   make ssh         - SSH into the device
#   make console     - Connect IEx console over SSH
#

# Default target
.DEFAULT_GOAL := help

# Configuration
MIX_TARGET ?= rpi3
MIX_ENV ?= prod
DEVICE_IP ?= nerves.local

.PHONY: help
help:
	@echo "Nerves Aprx - Makefile targets:"
	@echo ""
	@echo "  make firmware    - Build production firmware (default)"
	@echo "  make dev         - Build development firmware"
	@echo "  make burn        - Burn production firmware to SD card" 
	@echo "  make upload      - Upload production firmware over network (SSH)"
	@echo "  make dev-upload  - Build and upload development firmware"
	@echo "  make ssh         - SSH into the device"
	@echo "  make console     - Connect IEx console over SSH"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make find        - Find Nerves devices on network"
	@echo ""
	@echo "Configuration:"
	@echo "  MIX_TARGET=$(MIX_TARGET)"
	@echo "  MIX_ENV=$(MIX_ENV) (default: prod)"
	@echo "  DEVICE_IP=$(DEVICE_IP)"
	@echo ""
	@echo "Examples:"
	@echo "  make firmware MIX_TARGET=rpi4"
	@echo "  make upload DEVICE_IP=192.168.1.100"
	@echo "  make dev-upload MIX_TARGET=rpi0"

.PHONY: deps
deps:
	mix deps.get

# Default firmware build is production
.PHONY: firmware
firmware: deps
	MIX_TARGET=$(MIX_TARGET) MIX_ENV=prod mix firmware

# Alias for production
.PHONY: prod
prod: firmware

# Development firmware
.PHONY: dev
dev: deps
	MIX_TARGET=$(MIX_TARGET) MIX_ENV=dev mix firmware

# Default burn is production
.PHONY: burn
burn: firmware
	@echo "Insert SD card and press Enter to continue..."
	@read dummy
	MIX_TARGET=$(MIX_TARGET) MIX_ENV=prod mix burn

.PHONY: burn-dev
burn-dev: dev
	@echo "Insert SD card and press Enter to continue..."
	@read dummy
	MIX_TARGET=$(MIX_TARGET) MIX_ENV=dev mix burn

# Default upload is production
.PHONY: upload
upload: firmware
	MIX_TARGET=$(MIX_TARGET) MIX_ENV=prod ./upload.sh $(DEVICE_IP)

.PHONY: dev-upload
dev-upload: dev
	MIX_TARGET=$(MIX_TARGET) MIX_ENV=dev ./upload.sh $(DEVICE_IP)

.PHONY: ssh
ssh:
	ssh $(DEVICE_IP)

.PHONY: console
console:
	ssh $(DEVICE_IP) -t "iex"

.PHONY: clean
clean:
	mix clean
	rm -rf _build

# Default deploy is production
.PHONY: deploy
deploy: firmware upload
	@echo "Production deployment complete!"

# Development deployment
.PHONY: deploy-dev
deploy-dev: dev dev-upload
	@echo "Development deployment complete!"

# Get device info
.PHONY: info
info:
	@echo "Getting device info from $(DEVICE_IP)..."
	@ssh $(DEVICE_IP) "cat /proc/cpuinfo | grep Model || true"
	@ssh $(DEVICE_IP) "uname -a"
	@ssh $(DEVICE_IP) "df -h /data"
	@ssh $(DEVICE_IP) "ifconfig eth0 | grep inet || true"

# Find devices on network
.PHONY: find
find:
	@./find_device.sh

# Show firmware info
.PHONY: fw-info
fw-info:
	@echo "Firmware files:"
	@ls -lh _build/*/nerves/images/*.fw 2>/dev/null || echo "No firmware built yet"