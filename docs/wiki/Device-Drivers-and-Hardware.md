<p align="center">
<img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/5dae868ed1caac1629ebd14959d92f3b0216e5e6/GH_MEDIA/F37FC284-F214-4989-B85C-1256AE8F9BD8.png?raw=true" />
</p>

# Device Drivers and Hardware Support

This document details hardware device drivers, network protocols, storage port drivers, and platform Board Support Packages (BSPs) included in KibaOS.

## Storage and Bus Drivers

### NVMe Storage Port Driver (`drivers/storage/port/stornvme/`)
- High-Performance NVMe Stack: Native NVMe controller initialization, submission/completion queue pair management, and DirectStorage/IORing zero-copy transfer hooks.

### USB Stack (`drivers/usb/`)
- Controller Drivers: Native USB xHCI (USB 3.x), EHCI (USB 2.0), and OHCI/UHCI controllers.
- Class Drivers: USB Mass Storage, USB Human Interface Devices (HID), and USB Audio.

## Networking Stack and Security

### Realtek PCIe Gigabit Ethernet Driver (`drivers/network/dd/r8169/`)
- Native PCIe Driver: High-throughput driver support for Realtek RTL8169/8111 series Gigabit Ethernet adapters.

### Windows Filtering Platform & IPSec (`drivers/network/netio/fwp_ipsec.c`)
- WFP Engine State: Manages kernel network filtering layers, classification keys, and packet inspection pipelines.
- IPSec Security Associations (SA): Implements Security Association creation, key exchange, and payload encryption/decryption routines.

## Audio Subsystem

- High Definition Audio (HDAudio): Kernel streaming audio framework supporting Multi-Channel HD Audio codecs and low-latency buffer queues.

## Board Support Packages (BSP)

### Raspberry Pi Board Support Package
- RP1 Peripheral Controller: Custom Ethernet controller driver for Raspberry Pi 5.
- CYW43455 Wi-Fi & Bluetooth: Wireless network initialization and firmware loading.
- VideoCore Acceleration: Display controller and VideoCore graphics pipeline support.
