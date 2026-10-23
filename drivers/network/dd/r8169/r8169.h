/*
 * PROJECT:     KibaOS Network Drivers
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Realtek RTL8169 / RTL8168 / RTL8111 PCIe Gigabit Ethernet Driver Header
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif.ing@outlook.com>
 */

#pragma once

#include <ndis.h>
#include <ifdef.h>
#include <ipifcons.h>

#define NDEBUG
#include <reactos/debug.h>

#include "r8169hw.h"

#ifndef ETH_LENGTH_OF_ADDRESS
#define ETH_LENGTH_OF_ADDRESS 6
#endif

#define R8169_TAG                    '9618'
#define R8169_NUM_TX_DESC            64
#define R8169_NUM_RX_DESC            64
#define R8169_BUFFER_SIZE            1536
#define R8169_MTU                    1500
#define R8169_FRAME_SIZE             1514
#define R8169_MAX_MULTICAST          32

#define R8169_MAC_OPTIONS            (NDIS_MAC_OPTION_COPY_LOOKAHEAD_DATA | \
                                      NDIS_MAC_OPTION_TRANSFORMS_EXECUTE | \
                                      NDIS_MAC_OPTION_NO_LOOPBACK | \
                                      NDIS_MAC_OPTION_802_1P_PRIORITY)

#define R8169_SUPPORTED_FILTERS      (NDIS_PACKET_TYPE_DIRECTED | \
                                      NDIS_PACKET_TYPE_MULTICAST | \
                                      NDIS_PACKET_TYPE_ALL_MULTICAST | \
                                      NDIS_PACKET_TYPE_BROADCAST | \
                                      NDIS_PACKET_TYPE_PROMISCUOUS)

typedef struct _R8169_RX_SLOT
{
    PUCHAR VirtualAddress;
    PHYSICAL_ADDRESS PhysicalAddress;
    PMDL Mdl;
    PNET_BUFFER_LIST NetBufferList;
} R8169_RX_SLOT, *PR8169_RX_SLOT;

typedef struct _R8169_TX_SLOT
{
    PUCHAR VirtualAddress;
    PHYSICAL_ADDRESS PhysicalAddress;
} R8169_TX_SLOT, *PR8169_TX_SLOT;

typedef struct _R8169_ADAPTER
{
    NDIS_HANDLE MiniportHandle;
    NDIS_HANDLE InterruptHandle;
    PUCHAR MmioBase;
    ULONG MmioLength;
    PHYSICAL_ADDRESS MmioPhysical;

    NDIS_SPIN_LOCK TxLock;
    NDIS_SPIN_LOCK RxLock;
    NDIS_SPIN_LOCK CommandLock;

    BOOLEAN Paused;
    BOOLEAN Activated;
    ULONG PacketFilter;
    ULONG Lookahead;

    NDIS_MEDIA_CONNECT_STATE MediaConnectState;
    ULONG64 LinkSpeed;

    UCHAR PermanentMacAddress[ETH_LENGTH_OF_ADDRESS];
    UCHAR CurrentMacAddress[ETH_LENGTH_OF_ADDRESS];
    UCHAR MulticastList[R8169_MAX_MULTICAST][ETH_LENGTH_OF_ADDRESS];
    ULONG MulticastCount;

    PUCHAR DmaVirtual;
    PHYSICAL_ADDRESS DmaPhysical;

    PR8169_DESC TxRing;
    PR8169_DESC RxRing;
    PHYSICAL_ADDRESS TxRingPhysical;
    PHYSICAL_ADDRESS RxRingPhysical;

    R8169_TX_SLOT Tx[R8169_NUM_TX_DESC];
    R8169_RX_SLOT Rx[R8169_NUM_RX_DESC];
    PVOID TxBufferPages[R8169_NUM_TX_DESC / (PAGE_SIZE / R8169_BUFFER_SIZE) + 1];
    PVOID RxBufferPages[R8169_NUM_RX_DESC / (PAGE_SIZE / R8169_BUFFER_SIZE) + 1];

    NDIS_HANDLE RxNblPool;

    ULONG TxProduced;
    ULONG TxCompleted;
    ULONG RxCompleted;

    ULONG64 TxPackets;
    ULONG64 RxPackets;
    ULONG64 TxErrors;
    ULONG64 RxErrors;
    ULONG64 RxNoBuffer;
} R8169_ADAPTER, *PR8169_ADAPTER;
