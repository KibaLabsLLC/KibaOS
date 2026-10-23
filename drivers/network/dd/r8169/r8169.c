/*
 * PROJECT:     KibaOS Network Drivers
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Realtek RTL8169 / RTL8168 / RTL8111 PCIe Gigabit Ethernet Driver
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif.ing@outlook.com>
 */

#include "r8169.h"

static NDIS_HANDLE R8169DriverHandle;

static MINIPORT_INITIALIZE_EX R8169InitializeEx;
static MINIPORT_HALT_EX R8169HaltEx;
static MINIPORT_UNLOAD R8169Unload;
static MINIPORT_PAUSE R8169Pause;
static MINIPORT_RESTART R8169Restart;
static MINIPORT_OID_REQUEST R8169OidRequest;
static MINIPORT_CANCEL_OID_REQUEST R8169CancelOidRequest;
static MINIPORT_SEND_NET_BUFFER_LISTS R8169SendNetBufferLists;
static MINIPORT_RETURN_NET_BUFFER_LISTS R8169ReturnNetBufferLists;
static MINIPORT_CANCEL_SEND R8169CancelSend;
static MINIPORT_CHECK_FOR_HANG_EX R8169CheckForHang;
static MINIPORT_RESET_EX R8169Reset;
static MINIPORT_DEVICE_PNP_EVENT_NOTIFY R8169DevicePnPEventNotify;
static MINIPORT_SHUTDOWN_EX R8169Shutdown;
static MINIPORT_ISR R8169Interrupt;
static MINIPORT_INTERRUPT_DPC R8169InterruptDpc;

static const NDIS_OID R8169SupportedOids[] =
{
    OID_GEN_SUPPORTED_LIST,
    OID_GEN_HARDWARE_STATUS,
    OID_GEN_MEDIA_SUPPORTED,
    OID_GEN_MEDIA_IN_USE,
    OID_GEN_MAXIMUM_LOOKAHEAD,
    OID_GEN_MAXIMUM_FRAME_SIZE,
    OID_GEN_LINK_SPEED,
    OID_GEN_TRANSMIT_BLOCK_SIZE,
    OID_GEN_RECEIVE_BLOCK_SIZE,
    OID_GEN_VENDOR_ID,
    OID_GEN_VENDOR_DESCRIPTION,
    OID_GEN_CURRENT_PACKET_FILTER,
    OID_GEN_CURRENT_LOOKAHEAD,
    OID_GEN_DRIVER_VERSION,
    OID_GEN_MAXIMUM_TOTAL_SIZE,
    OID_GEN_MAC_OPTIONS,
    OID_GEN_MEDIA_CONNECT_STATUS,
    OID_GEN_VENDOR_DRIVER_VERSION,
    OID_GEN_PHYSICAL_MEDIUM,
    OID_GEN_LINK_STATE,
    OID_GEN_XMIT_OK,
    OID_GEN_RCV_OK,
    OID_GEN_XMIT_ERROR,
    OID_GEN_RCV_ERROR,
    OID_GEN_RCV_NO_BUFFER,
    OID_802_3_PERMANENT_ADDRESS,
    OID_802_3_CURRENT_ADDRESS,
    OID_802_3_MULTICAST_LIST,
    OID_802_3_MAXIMUM_LIST_SIZE
};

static __inline UCHAR
R8169Read8(
    _In_ PR8169_ADAPTER Adapter,
    _In_ ULONG Offset)
{
    return READ_REGISTER_UCHAR((volatile UCHAR *)(Adapter->MmioBase + Offset));
}

static __inline USHORT
R8169Read16(
    _In_ PR8169_ADAPTER Adapter,
    _In_ ULONG Offset)
{
    return READ_REGISTER_USHORT((volatile USHORT *)(Adapter->MmioBase + Offset));
}

static __inline ULONG
R8169Read32(
    _In_ PR8169_ADAPTER Adapter,
    _In_ ULONG Offset)
{
    return READ_REGISTER_ULONG((volatile ULONG *)(Adapter->MmioBase + Offset));
}

static __inline VOID
R8169Write8(
    _In_ PR8169_ADAPTER Adapter,
    _In_ ULONG Offset,
    _In_ UCHAR Value)
{
    WRITE_REGISTER_UCHAR((volatile UCHAR *)(Adapter->MmioBase + Offset), Value);
}

static __inline VOID
R8169Write16(
    _In_ PR8169_ADAPTER Adapter,
    _In_ ULONG Offset,
    _In_ USHORT Value)
{
    WRITE_REGISTER_USHORT((volatile USHORT *)(Adapter->MmioBase + Offset), Value);
}

static __inline VOID
R8169Write32(
    _In_ PR8169_ADAPTER Adapter,
    _In_ ULONG Offset,
    _In_ ULONG Value)
{
    WRITE_REGISTER_ULONG((volatile ULONG *)(Adapter->MmioBase + Offset), Value);
}

static PVOID
R8169AllocateContiguous(
    _In_ SIZE_T Length,
    _In_ MEMORY_CACHING_TYPE CacheType,
    _Out_ PNDIS_PHYSICAL_ADDRESS Physical)
{
    PHYSICAL_ADDRESS Low, High, Boundary;
    PVOID VirtualAddress;

    Low.QuadPart = 0;
    High.QuadPart = -1;
    Boundary.QuadPart = 0;

    VirtualAddress = MmAllocateContiguousMemorySpecifyCache(Length, Low, High, Boundary, CacheType);
    Physical->QuadPart = VirtualAddress ? MmGetPhysicalAddress(VirtualAddress).QuadPart : 0;
    return VirtualAddress;
}

static VOID
R8169IndicateLinkState(
    _In_ PR8169_ADAPTER Adapter)
{
    NDIS_STATUS_INDICATION StatusIndication;
    NDIS_LINK_STATE LinkState;

    RtlZeroMemory(&LinkState, sizeof(LinkState));
    LinkState.Header.Type = NDIS_OBJECT_TYPE_DEFAULT;
    LinkState.Header.Revision = NDIS_LINK_STATE_REVISION_1;
    LinkState.Header.Size = sizeof(NDIS_LINK_STATE);
    LinkState.MediaConnectState = Adapter->MediaConnectState;
    LinkState.MediaDuplexState = MediaDuplexStateFull;
    LinkState.XmitLinkSpeed = Adapter->LinkSpeed;
    LinkState.RcvLinkSpeed = Adapter->LinkSpeed;
    LinkState.PauseFunctions = NdisPauseFunctionsUnsupported;

    RtlZeroMemory(&StatusIndication, sizeof(StatusIndication));
    StatusIndication.Header.Type = NDIS_OBJECT_TYPE_STATUS_INDICATION;
    StatusIndication.Header.Revision = NDIS_STATUS_INDICATION_REVISION_1;
    StatusIndication.Header.Size = NDIS_SIZEOF_STATUS_INDICATION_REVISION_1;
    StatusIndication.SourceHandle = Adapter->MiniportHandle;
    StatusIndication.StatusCode = NDIS_STATUS_LINK_STATE;
    StatusIndication.StatusBuffer = &LinkState;
    StatusIndication.StatusBufferSize = sizeof(LinkState);

    NdisMIndicateStatusEx(Adapter->MiniportHandle, &StatusIndication);
}

static VOID
R8169UpdateLink(
    _In_ PR8169_ADAPTER Adapter,
    _In_ BOOLEAN Indicate)
{
    UCHAR Status = R8169Read8(Adapter, R8169_REG_PHY_STATUS);
    NDIS_MEDIA_CONNECT_STATE ConnectState;
    ULONG64 LinkSpeed;

    if (Status & R8169_PHY_LINK)
    {
        ConnectState = MediaConnectStateConnected;
        if (Status & R8169_PHY_1000M)
            LinkSpeed = 1000000000ULL;
        else if (Status & R8169_PHY_100M)
            LinkSpeed = 100000000ULL;
        else
            LinkSpeed = 10000000ULL;
    }
    else
    {
        ConnectState = MediaConnectStateDisconnected;
        LinkSpeed = NDIS_LINK_SPEED_UNKNOWN;
    }

    if (ConnectState == Adapter->MediaConnectState && LinkSpeed == Adapter->LinkSpeed)
        return;

    Adapter->MediaConnectState = ConnectState;
    Adapter->LinkSpeed = LinkSpeed;

    if (Indicate)
        R8169IndicateLinkState(Adapter);
}

static VOID
R8169ApplyRxFilter(
    _In_ PR8169_ADAPTER Adapter)
{
    ULONG Rcr = R8169_RCR_MXDMA_UNLIMITED;

    if (Adapter->PacketFilter & NDIS_PACKET_TYPE_DIRECTED)
        Rcr |= R8169_RCR_ACCEPT_PHYS;
    if (Adapter->PacketFilter & NDIS_PACKET_TYPE_BROADCAST)
        Rcr |= R8169_RCR_ACCEPT_BROAD;
    if (Adapter->PacketFilter & NDIS_PACKET_TYPE_MULTICAST)
        Rcr |= R8169_RCR_ACCEPT_MULTI;
    if (Adapter->PacketFilter & NDIS_PACKET_TYPE_ALL_MULTICAST)
        Rcr |= R8169_RCR_ACCEPT_ALL_MULTI;
    if (Adapter->PacketFilter & NDIS_PACKET_TYPE_PROMISCUOUS)
        Rcr |= R8169_RCR_ACCEPT_ALL | R8169_RCR_ACCEPT_PHYS | R8169_RCR_ACCEPT_MULTI | R8169_RCR_ACCEPT_BROAD;

    R8169Write32(Adapter, R8169_REG_RCR, Rcr);
}

static VOID
R8169ProcessReceives(
    _In_ PR8169_ADAPTER Adapter,
    _In_ ULONG Budget)
{
    PNET_BUFFER_LIST Head = NULL;
    PNET_BUFFER_LIST Tail = NULL;
    ULONG Indicated = 0;
    ULONG Consumed = 0;
    ULONG IndicatedSlots[R8169_NUM_RX_DESC];
    ULONG Flags;
    ULONG i;

    NdisAcquireSpinLock(&Adapter->RxLock);

    while (Indicated < Budget)
    {
        ULONG Slot = (Adapter->RxCompleted + Consumed) % R8169_NUM_RX_DESC;
        PR8169_DESC Desc = &Adapter->RxRing[Slot];
        ULONG DescriptorFlags;
        ULONG FrameLength;
        PR8169_RX_SLOT RxSlot;
        PNET_BUFFER NetBuffer;

        DescriptorFlags = Desc->Flags;
        if (DescriptorFlags & R8169_DESC_OWN)
            break;

        FrameLength = DescriptorFlags & R8169_DESC_LEN_MASK;
        Consumed++;

        if (Adapter->Paused || !Adapter->PacketFilter || FrameLength < (ETH_LENGTH_OF_ADDRESS * 2 + 2))
        {
            Desc->Flags = R8169_DESC_OWN | ((Slot == R8169_NUM_RX_DESC - 1) ? R8169_DESC_EOR : 0) | R8169_BUFFER_SIZE;
            continue;
        }

        RxSlot = &Adapter->Rx[Slot];
        NetBuffer = NET_BUFFER_LIST_FIRST_NB(RxSlot->NetBufferList);
        NET_BUFFER_CURRENT_MDL(NetBuffer) = RxSlot->Mdl;
        NET_BUFFER_CURRENT_MDL_OFFSET(NetBuffer) = 0;
        NET_BUFFER_DATA_OFFSET(NetBuffer) = 0;
        NET_BUFFER_DATA_LENGTH(NetBuffer) = min(FrameLength, R8169_BUFFER_SIZE);
        NET_BUFFER_LIST_STATUS(RxSlot->NetBufferList) = NDIS_STATUS_SUCCESS;
        NET_BUFFER_LIST_NEXT_NBL(RxSlot->NetBufferList) = NULL;
        RxSlot->NetBufferList->SourceHandle = Adapter->MiniportHandle;

        if (Tail)
            NET_BUFFER_LIST_NEXT_NBL(Tail) = RxSlot->NetBufferList;
        else
            Head = RxSlot->NetBufferList;
        Tail = RxSlot->NetBufferList;

        IndicatedSlots[Indicated] = Slot;
        Indicated++;
        Adapter->RxPackets++;
    }

    Adapter->RxCompleted += Consumed;
    NdisReleaseSpinLock(&Adapter->RxLock);

    if (Head)
    {
        Flags = NDIS_RECEIVE_FLAGS_RESOURCES;
        if (KeGetCurrentIrql() == DISPATCH_LEVEL)
            Flags |= NDIS_RECEIVE_FLAGS_DISPATCH_LEVEL;

        NdisMIndicateReceiveNetBufferLists(Adapter->MiniportHandle,
                                           Head,
                                           NDIS_DEFAULT_PORT_NUMBER,
                                           Indicated,
                                           Flags);

        NdisAcquireSpinLock(&Adapter->RxLock);
        for (i = 0; i < Indicated; i++)
        {
            ULONG Slot = IndicatedSlots[i];
            PR8169_DESC Desc = &Adapter->RxRing[Slot];
            Desc->Flags = R8169_DESC_OWN | ((Slot == R8169_NUM_RX_DESC - 1) ? R8169_DESC_EOR : 0) | R8169_BUFFER_SIZE;
        }
        NdisReleaseSpinLock(&Adapter->RxLock);
    }
}

static VOID
R8169CompleteTransmits(
    _In_ PR8169_ADAPTER Adapter)
{
    NdisAcquireSpinLock(&Adapter->TxLock);

    while (Adapter->TxCompleted != Adapter->TxProduced)
    {
        ULONG Slot = Adapter->TxCompleted % R8169_NUM_TX_DESC;
        PR8169_DESC Desc = &Adapter->TxRing[Slot];

        if (Desc->Flags & R8169_DESC_OWN)
            break;

        Adapter->TxCompleted++;
        Adapter->TxPackets++;
    }

    NdisReleaseSpinLock(&Adapter->TxLock);
}

static NDIS_STATUS
R8169CopyNetBuffer(
    _In_ PNET_BUFFER NetBuffer,
    _Out_writes_bytes_(DestinationLength) PUCHAR Destination,
    _In_ ULONG DestinationLength,
    _Out_ PULONG BytesCopied)
{
    PMDL Mdl = NET_BUFFER_CURRENT_MDL(NetBuffer);
    ULONG Offset = NET_BUFFER_CURRENT_MDL_OFFSET(NetBuffer);
    ULONG Remaining = NET_BUFFER_DATA_LENGTH(NetBuffer);
    ULONG Copied = 0;

    *BytesCopied = 0;
    if (Remaining > DestinationLength)
        return NDIS_STATUS_INVALID_LENGTH;

    while (Remaining)
    {
        PUCHAR Source;
        ULONG Chunk;

        if (!Mdl)
            return NDIS_STATUS_INVALID_PACKET;

        if (Offset >= MmGetMdlByteCount(Mdl))
        {
            Offset -= MmGetMdlByteCount(Mdl);
            Mdl = Mdl->Next;
            continue;
        }

        Source = MmGetSystemAddressForMdlSafe(Mdl, NormalPagePriority);
        if (!Source)
            return NDIS_STATUS_RESOURCES;

        Chunk = min(MmGetMdlByteCount(Mdl) - Offset, Remaining);
        RtlCopyMemory(Destination + Copied, Source + Offset, Chunk);
        Copied += Chunk;
        Remaining -= Chunk;
        Offset = 0;
        Mdl = Mdl->Next;
    }

    *BytesCopied = Copied;
    return NDIS_STATUS_SUCCESS;
}

static NDIS_STATUS
R8169QueueNetBufferList(
    _In_ PR8169_ADAPTER Adapter,
    _In_ PNET_BUFFER_LIST NetBufferList)
{
    NDIS_STATUS Status = NDIS_STATUS_SUCCESS;
    PNET_BUFFER NetBuffer;
    ULONG Count = 0;

    if (Adapter->Paused)
        return NDIS_STATUS_PAUSED;
    if (!Adapter->Activated || Adapter->MediaConnectState != MediaConnectStateConnected)
        return NDIS_STATUS_MEDIA_DISCONNECTED;

    for (NetBuffer = NET_BUFFER_LIST_FIRST_NB(NetBufferList); NetBuffer; NetBuffer = NET_BUFFER_NEXT_NB(NetBuffer))
    {
        if (NET_BUFFER_DATA_LENGTH(NetBuffer) < (ETH_LENGTH_OF_ADDRESS * 2 + 2) ||
            NET_BUFFER_DATA_LENGTH(NetBuffer) > R8169_FRAME_SIZE)
        {
            return NDIS_STATUS_INVALID_LENGTH;
        }
        Count++;
    }

    if (!Count)
        return NDIS_STATUS_INVALID_PACKET;

    NdisAcquireSpinLock(&Adapter->TxLock);

    if (Adapter->TxProduced - Adapter->TxCompleted + Count > R8169_NUM_TX_DESC - 1)
    {
        NdisReleaseSpinLock(&Adapter->TxLock);
        return NDIS_STATUS_RESOURCES;
    }

    for (NetBuffer = NET_BUFFER_LIST_FIRST_NB(NetBufferList);
         NetBuffer && Status == NDIS_STATUS_SUCCESS;
         NetBuffer = NET_BUFFER_NEXT_NB(NetBuffer))
    {
        ULONG Slot = Adapter->TxProduced % R8169_NUM_TX_DESC;
        ULONG Length;

        Status = R8169CopyNetBuffer(NetBuffer, Adapter->Tx[Slot].VirtualAddress, R8169_BUFFER_SIZE, &Length);
        if (Status == NDIS_STATUS_SUCCESS)
        {
            PR8169_DESC Desc = &Adapter->TxRing[Slot];
            ULONG Flags = R8169_DESC_OWN | R8169_DESC_FS | R8169_DESC_LS | (Length & R8169_DESC_LEN_MASK);

            if (Slot == R8169_NUM_TX_DESC - 1)
                Flags |= R8169_DESC_EOR;

            Desc->VlanFlags = 0;
            Desc->BufferAddress = (ULONG64)Adapter->Tx[Slot].PhysicalAddress.QuadPart;
            KeMemoryBarrier();
            Desc->Flags = Flags;
            Adapter->TxProduced++;
        }
    }

    KeMemoryBarrier();
    R8169Write8(Adapter, R8169_REG_TX_POLL, R8169_POLL_NORMAL);
    NdisReleaseSpinLock(&Adapter->TxLock);

    return Status;
}

static NDIS_STATUS
R8169SetRegistrationAttributes(
    _In_ PR8169_ADAPTER Adapter)
{
    NDIS_MINIPORT_ADAPTER_REGISTRATION_ATTRIBUTES Attributes;

    RtlZeroMemory(&Attributes, sizeof(Attributes));
    Attributes.Header.Type = NDIS_OBJECT_TYPE_MINIPORT_ADAPTER_REGISTRATION_ATTRIBUTES;
    Attributes.Header.Revision = NDIS_MINIPORT_ADAPTER_REGISTRATION_ATTRIBUTES_REVISION_1;
    Attributes.Header.Size = sizeof(Attributes);
    Attributes.MiniportAdapterContext = Adapter;
    Attributes.AttributeFlags = NDIS_MINIPORT_ATTRIBUTES_HARDWARE_DEVICE |
                                NDIS_MINIPORT_ATTRIBUTES_BUS_MASTER |
                                NDIS_MINIPORT_ATTRIBUTES_SURPRISE_REMOVE_OK;
    Attributes.CheckForHangTimeInSeconds = 4;
    Attributes.InterfaceType = NdisInterfacePci;

    return NdisMSetMiniportAttributes(Adapter->MiniportHandle, (PNDIS_MINIPORT_ADAPTER_ATTRIBUTES)&Attributes);
}

static NDIS_STATUS
R8169SetGeneralAttributes(
    _In_ PR8169_ADAPTER Adapter)
{
    NDIS_MINIPORT_ADAPTER_GENERAL_ATTRIBUTES Attributes;

    RtlZeroMemory(&Attributes, sizeof(Attributes));
    Attributes.Header.Type = NDIS_OBJECT_TYPE_MINIPORT_ADAPTER_GENERAL_ATTRIBUTES;
    Attributes.Header.Revision = NDIS_MINIPORT_ADAPTER_GENERAL_ATTRIBUTES_REVISION_1;
    Attributes.Header.Size = NDIS_SIZEOF_MINIPORT_ADAPTER_GENERAL_ATTRIBUTES_REVISION_1;
    Attributes.MediaType = NdisMedium802_3;
    Attributes.PhysicalMediumType = NdisPhysicalMedium802_3;
    Attributes.MtuSize = R8169_MTU;
    Attributes.MaxXmitLinkSpeed = 1000000000ULL;
    Attributes.MaxRcvLinkSpeed = 1000000000ULL;
    Attributes.XmitLinkSpeed = Adapter->LinkSpeed;
    Attributes.RcvLinkSpeed = Adapter->LinkSpeed;
    Attributes.MediaConnectState = Adapter->MediaConnectState;
    Attributes.MediaDuplexState = MediaDuplexStateFull;
    Attributes.LookaheadSize = Adapter->Lookahead;
    Attributes.MacOptions = R8169_MAC_OPTIONS;
    Attributes.SupportedPacketFilters = R8169_SUPPORTED_FILTERS;
    Attributes.MaxMulticastListSize = R8169_MAX_MULTICAST;
    Attributes.MacAddressLength = ETH_LENGTH_OF_ADDRESS;
    RtlCopyMemory(Attributes.PermanentMacAddress, Adapter->PermanentMacAddress, ETH_LENGTH_OF_ADDRESS);
    RtlCopyMemory(Attributes.CurrentMacAddress, Adapter->CurrentMacAddress, ETH_LENGTH_OF_ADDRESS);
    Attributes.AccessType = NET_IF_ACCESS_BROADCAST;
    Attributes.DirectionType = NET_IF_DIRECTION_SENDRECEIVE;
    Attributes.ConnectionType = NET_IF_CONNECTION_DEDICATED;
    Attributes.IfType = IF_TYPE_ETHERNET_CSMACD;
    Attributes.IfConnectorPresent = TRUE;
    Attributes.SupportedPauseFunctions = NdisPauseFunctionsUnsupported;
    Attributes.SupportedOidList = (PNDIS_OID)R8169SupportedOids;
    Attributes.SupportedOidListLength = sizeof(R8169SupportedOids);
    Attributes.SupportedStatistics = NDIS_STATISTICS_XMIT_OK_SUPPORTED |
                                     NDIS_STATISTICS_RCV_OK_SUPPORTED |
                                     NDIS_STATISTICS_XMIT_ERROR_SUPPORTED |
                                     NDIS_STATISTICS_RCV_ERROR_SUPPORTED |
                                     NDIS_STATISTICS_RCV_NO_BUFFER_SUPPORTED;

    return NdisMSetMiniportAttributes(Adapter->MiniportHandle, (PNDIS_MINIPORT_ADAPTER_ATTRIBUTES)&Attributes);
}

static NDIS_STATUS
R8169MapResources(
    _In_ PR8169_ADAPTER Adapter,
    _In_opt_ PNDIS_RESOURCE_LIST ResourceList)
{
    ULONG i;

    if (!ResourceList)
        return NDIS_STATUS_RESOURCES;

    for (i = 0; i < ResourceList->Count && !Adapter->MmioBase; i++)
    {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR Descriptor = &ResourceList->PartialDescriptors[i];
        NDIS_STATUS Status;

        if (Descriptor->Type != CmResourceTypeMemory)
            continue;

        Adapter->MmioPhysical = Descriptor->u.Memory.Start;
        Adapter->MmioLength = Descriptor->u.Memory.Length;
        Status = NdisMMapIoSpace((PVOID *)&Adapter->MmioBase, Adapter->MiniportHandle, Adapter->MmioPhysical, Adapter->MmioLength);
        if (Status != NDIS_STATUS_SUCCESS)
            return Status;
    }

    if (!Adapter->MmioBase || Adapter->MmioLength < 0x100)
        return NDIS_STATUS_RESOURCES;

    return NDIS_STATUS_SUCCESS;
}

static NDIS_STATUS
R8169ProbeDevice(
    _In_ PR8169_ADAPTER Adapter)
{
    ULONG Low, High;
    ULONG i;

    R8169Write8(Adapter, R8169_REG_COMMAND, R8169_CMD_RESET);
    for (i = 0; i < 1000; i++)
    {
        if (!(R8169Read8(Adapter, R8169_REG_COMMAND) & R8169_CMD_RESET))
            break;
        NdisMSleep(100);
    }

    Low = R8169Read32(Adapter, R8169_REG_MAC0);
    High = R8169Read32(Adapter, R8169_REG_MAC4);

    Adapter->PermanentMacAddress[0] = (UCHAR)Low;
    Adapter->PermanentMacAddress[1] = (UCHAR)(Low >> 8);
    Adapter->PermanentMacAddress[2] = (UCHAR)(Low >> 16);
    Adapter->PermanentMacAddress[3] = (UCHAR)(Low >> 24);
    Adapter->PermanentMacAddress[4] = (UCHAR)High;
    Adapter->PermanentMacAddress[5] = (UCHAR)(High >> 8);

    RtlCopyMemory(Adapter->CurrentMacAddress, Adapter->PermanentMacAddress, ETH_LENGTH_OF_ADDRESS);
    return NDIS_STATUS_SUCCESS;
}

static NDIS_STATUS
R8169AllocateDatapath(
    _In_ PR8169_ADAPTER Adapter)
{
    NET_BUFFER_LIST_POOL_PARAMETERS PoolParameters;
    SIZE_T RingSize = R8169_NUM_TX_DESC * sizeof(R8169_DESC) + R8169_NUM_RX_DESC * sizeof(R8169_DESC);
    ULONG i;

    Adapter->DmaVirtual = R8169AllocateContiguous(ROUND_TO_PAGES(RingSize), MmNonCached, &Adapter->DmaPhysical);
    if (!Adapter->DmaVirtual)
        return NDIS_STATUS_RESOURCES;

    RtlZeroMemory(Adapter->DmaVirtual, ROUND_TO_PAGES(RingSize));
    Adapter->TxRing = (PR8169_DESC)Adapter->DmaVirtual;
    Adapter->RxRing = (PR8169_DESC)(Adapter->DmaVirtual + R8169_NUM_TX_DESC * sizeof(R8169_DESC));

    Adapter->TxRingPhysical = Adapter->DmaPhysical;
    Adapter->RxRingPhysical.QuadPart = Adapter->DmaPhysical.QuadPart + R8169_NUM_TX_DESC * sizeof(R8169_DESC);

    for (i = 0; i < R8169_NUM_TX_DESC; i++)
    {
        NDIS_PHYSICAL_ADDRESS Physical;
        Adapter->Tx[i].VirtualAddress = R8169AllocateContiguous(R8169_BUFFER_SIZE, MmCached, &Physical);
        if (!Adapter->Tx[i].VirtualAddress)
            return NDIS_STATUS_RESOURCES;
        Adapter->Tx[i].PhysicalAddress = Physical;
    }

    RtlZeroMemory(&PoolParameters, sizeof(PoolParameters));
    PoolParameters.Header.Type = NDIS_OBJECT_TYPE_DEFAULT;
    PoolParameters.Header.Revision = NET_BUFFER_LIST_POOL_PARAMETERS_REVISION_1;
    PoolParameters.Header.Size = sizeof(PoolParameters);
    PoolParameters.ProtocolId = NDIS_PROTOCOL_ID_DEFAULT;
    PoolParameters.fAllocateNetBuffer = TRUE;
    PoolParameters.PoolTag = R8169_TAG;
    Adapter->RxNblPool = NdisAllocateNetBufferListPool(Adapter->MiniportHandle, &PoolParameters);
    if (!Adapter->RxNblPool)
        return NDIS_STATUS_RESOURCES;

    for (i = 0; i < R8169_NUM_RX_DESC; i++)
    {
        NDIS_PHYSICAL_ADDRESS Physical;
        PR8169_RX_SLOT Slot = &Adapter->Rx[i];

        Slot->VirtualAddress = R8169AllocateContiguous(R8169_BUFFER_SIZE, MmCached, &Physical);
        if (!Slot->VirtualAddress)
            return NDIS_STATUS_RESOURCES;
        Slot->PhysicalAddress = Physical;

        Slot->Mdl = IoAllocateMdl(Slot->VirtualAddress, R8169_BUFFER_SIZE, FALSE, FALSE, NULL);
        if (!Slot->Mdl)
            return NDIS_STATUS_RESOURCES;
        MmBuildMdlForNonPagedPool(Slot->Mdl);

        Slot->NetBufferList = NdisAllocateNetBufferAndNetBufferList(Adapter->RxNblPool, 0, 0, Slot->Mdl, 0, 0);
        if (!Slot->NetBufferList)
            return NDIS_STATUS_RESOURCES;

        Adapter->RxRing[i].BufferAddress = (ULONG64)Physical.QuadPart;
        Adapter->RxRing[i].Flags = R8169_DESC_OWN | R8169_BUFFER_SIZE | ((i == R8169_NUM_RX_DESC - 1) ? R8169_DESC_EOR : 0);
    }

    return NDIS_STATUS_SUCCESS;
}

static VOID
R8169FreeDatapath(
    _In_ PR8169_ADAPTER Adapter)
{
    ULONG i;

    for (i = 0; i < R8169_NUM_RX_DESC; i++)
    {
        if (Adapter->Rx[i].NetBufferList)
            NdisFreeNetBufferList(Adapter->Rx[i].NetBufferList);
        if (Adapter->Rx[i].Mdl)
            IoFreeMdl(Adapter->Rx[i].Mdl);
        if (Adapter->Rx[i].VirtualAddress)
            MmFreeContiguousMemorySpecifyCache(Adapter->Rx[i].VirtualAddress, R8169_BUFFER_SIZE, MmCached);
    }

    if (Adapter->RxNblPool)
        NdisFreeNetBufferListPool(Adapter->RxNblPool);

    for (i = 0; i < R8169_NUM_TX_DESC; i++)
    {
        if (Adapter->Tx[i].VirtualAddress)
            MmFreeContiguousMemorySpecifyCache(Adapter->Tx[i].VirtualAddress, R8169_BUFFER_SIZE, MmCached);
    }

    if (Adapter->DmaVirtual)
        MmFreeContiguousMemorySpecifyCache(Adapter->DmaVirtual, ROUND_TO_PAGES(R8169_NUM_TX_DESC * sizeof(R8169_DESC) * 2), MmNonCached);
}

static NDIS_STATUS
R8169Activate(
    _In_ PR8169_ADAPTER Adapter)
{
    R8169Write8(Adapter, R8169_REG_COMMAND, R8169_CMD_RESET);
    NdisMSleep(1000);

    R8169Write32(Adapter, R8169_REG_TX_DESC_ADDR_LOW, (ULONG)Adapter->TxRingPhysical.QuadPart);
    R8169Write32(Adapter, R8169_REG_TX_DESC_ADDR_HIGH, (ULONG)(Adapter->TxRingPhysical.QuadPart >> 32));

    R8169Write32(Adapter, R8169_REG_RX_DESC_ADDR_LOW, (ULONG)Adapter->RxRingPhysical.QuadPart);
    R8169Write32(Adapter, R8169_REG_RX_DESC_ADDR_HIGH, (ULONG)(Adapter->RxRingPhysical.QuadPart >> 32));

    R8169Write16(Adapter, R8169_REG_RMS, R8169_BUFFER_SIZE);
    R8169Write32(Adapter, R8169_REG_TCR, R8169_TCR_MXDMA_UNLIMITED);
    R8169ApplyRxFilter(Adapter);

    R8169Write8(Adapter, R8169_REG_COMMAND, R8169_CMD_RX_ENABLE | R8169_CMD_TX_ENABLE);
    R8169Write16(Adapter, R8169_REG_IMR, R8169_INT_DEFAULT);

    Adapter->Activated = TRUE;
    return NDIS_STATUS_SUCCESS;
}

static VOID
R8169Deactivate(
    _In_ PR8169_ADAPTER Adapter)
{
    if (!Adapter->Activated)
        return;

    R8169Write16(Adapter, R8169_REG_IMR, 0);
    R8169Write8(Adapter, R8169_REG_COMMAND, 0);
    Adapter->Activated = FALSE;
}

static BOOLEAN NTAPI
R8169Interrupt(
    _In_ NDIS_HANDLE MiniportInterruptContext,
    _Out_ PBOOLEAN QueueDefaultInterruptDpc,
    _Out_ PULONG TargetProcessors)
{
    PR8169_ADAPTER Adapter = (PR8169_ADAPTER)MiniportInterruptContext;
    USHORT Isr;

    *QueueDefaultInterruptDpc = FALSE;
    *TargetProcessors = 0;

    if (!Adapter->Activated)
        return FALSE;

    Isr = R8169Read16(Adapter, R8169_REG_ISR);
    if (!Isr || Isr == 0xFFFF)
        return FALSE;

    R8169Write16(Adapter, R8169_REG_ISR, Isr);
    R8169Write16(Adapter, R8169_REG_IMR, 0);
    *QueueDefaultInterruptDpc = TRUE;
    return TRUE;
}

static VOID NTAPI
R8169InterruptDpc(
    _In_ NDIS_HANDLE MiniportInterruptContext,
    _In_ PVOID MiniportDpcContext,
    _In_ PVOID ReceiveThrottleParameters,
    _In_ PVOID NdisReserved2)
{
    PR8169_ADAPTER Adapter = (PR8169_ADAPTER)MiniportInterruptContext;

    UNREFERENCED_PARAMETER(MiniportDpcContext);
    UNREFERENCED_PARAMETER(ReceiveThrottleParameters);
    UNREFERENCED_PARAMETER(NdisReserved2);

    R8169UpdateLink(Adapter, TRUE);
    R8169CompleteTransmits(Adapter);
    R8169ProcessReceives(Adapter, R8169_NUM_RX_DESC);

    if (Adapter->Activated)
        R8169Write16(Adapter, R8169_REG_IMR, R8169_INT_DEFAULT);
}

static NDIS_STATUS
R8169RegisterInterrupt(
    _In_ PR8169_ADAPTER Adapter)
{
    NDIS_MINIPORT_INTERRUPT_CHARACTERISTICS Characteristics;

    RtlZeroMemory(&Characteristics, sizeof(Characteristics));
    Characteristics.Header.Type = NDIS_OBJECT_TYPE_MINIPORT_INTERRUPT;
    Characteristics.Header.Revision = NDIS_MINIPORT_INTERRUPT_REVISION_1;
    Characteristics.Header.Size = NDIS_SIZEOF_MINIPORT_INTERRUPT_CHARACTERISTICS_REVISION_1;
    Characteristics.InterruptHandler = R8169Interrupt;
    Characteristics.InterruptDpcHandler = R8169InterruptDpc;
    Characteristics.InterruptType = NDIS_CONNECT_LINE_BASED;
    Characteristics.MsiSupported = FALSE;

    return NdisMRegisterInterruptEx(Adapter->MiniportHandle, Adapter, &Characteristics, &Adapter->InterruptHandle);
}

static VOID
R8169Release(
    _In_ PR8169_ADAPTER Adapter)
{
    R8169Deactivate(Adapter);

    if (Adapter->InterruptHandle)
        NdisMDeregisterInterruptEx(Adapter->InterruptHandle);

    R8169FreeDatapath(Adapter);

    if (Adapter->MmioBase)
        NdisMUnmapIoSpace(Adapter->MiniportHandle, Adapter->MmioBase, Adapter->MmioLength);

    NdisFreeSpinLock(&Adapter->CommandLock);
    NdisFreeSpinLock(&Adapter->RxLock);
    NdisFreeSpinLock(&Adapter->TxLock);
    ExFreePoolWithTag(Adapter, R8169_TAG);
}

static NDIS_STATUS
R8169CopyQuery(
    _Inout_ PNDIS_OID_REQUEST OidRequest,
    _In_reads_bytes_(Length) const VOID *Source,
    _In_ ULONG Length)
{
    OidRequest->DATA.QUERY_INFORMATION.BytesWritten = 0;
    OidRequest->DATA.QUERY_INFORMATION.BytesNeeded = 0;

    if (OidRequest->DATA.QUERY_INFORMATION.InformationBufferLength < Length)
    {
        OidRequest->DATA.QUERY_INFORMATION.BytesNeeded = Length;
        return NDIS_STATUS_BUFFER_TOO_SHORT;
    }

    RtlCopyMemory(OidRequest->DATA.QUERY_INFORMATION.InformationBuffer, Source, Length);
    OidRequest->DATA.QUERY_INFORMATION.BytesWritten = Length;
    return NDIS_STATUS_SUCCESS;
}

static NDIS_STATUS
R8169QueryInformation(
    _In_ PR8169_ADAPTER Adapter,
    _Inout_ PNDIS_OID_REQUEST OidRequest)
{
    union
    {
        ULONG Ulong;
        USHORT Ushort;
        ULONG64 Ulong64;
        NDIS_MEDIUM Medium;
        NDIS_HARDWARE_STATUS HardwareStatus;
        NDIS_MEDIA_STATE MediaState;
        NDIS_PHYSICAL_MEDIUM PhysicalMedium;
        NDIS_LINK_STATE LinkState;
    } Data;

    RtlZeroMemory(&Data, sizeof(Data));

    switch (OidRequest->DATA.QUERY_INFORMATION.Oid)
    {
        case OID_GEN_SUPPORTED_LIST:
            return R8169CopyQuery(OidRequest, R8169SupportedOids, sizeof(R8169SupportedOids));

        case OID_GEN_HARDWARE_STATUS:
            Data.HardwareStatus = NdisHardwareStatusReady;
            return R8169CopyQuery(OidRequest, &Data.HardwareStatus, sizeof(Data.HardwareStatus));

        case OID_GEN_MEDIA_SUPPORTED:
        case OID_GEN_MEDIA_IN_USE:
            Data.Medium = NdisMedium802_3;
            return R8169CopyQuery(OidRequest, &Data.Medium, sizeof(Data.Medium));

        case OID_GEN_PHYSICAL_MEDIUM:
            Data.PhysicalMedium = NdisPhysicalMedium802_3;
            return R8169CopyQuery(OidRequest, &Data.PhysicalMedium, sizeof(Data.PhysicalMedium));

        case OID_GEN_MAXIMUM_LOOKAHEAD:
        case OID_GEN_MAXIMUM_FRAME_SIZE:
            Data.Ulong = R8169_MTU;
            return R8169CopyQuery(OidRequest, &Data.Ulong, sizeof(Data.Ulong));

        case OID_GEN_CURRENT_LOOKAHEAD:
            Data.Ulong = Adapter->Lookahead;
            return R8169CopyQuery(OidRequest, &Data.Ulong, sizeof(Data.Ulong));

        case OID_GEN_MAXIMUM_TOTAL_SIZE:
        case OID_GEN_TRANSMIT_BLOCK_SIZE:
        case OID_GEN_RECEIVE_BLOCK_SIZE:
            Data.Ulong = R8169_FRAME_SIZE;
            return R8169CopyQuery(OidRequest, &Data.Ulong, sizeof(Data.Ulong));

        case OID_GEN_LINK_SPEED:
            Data.Ulong = (Adapter->LinkSpeed == NDIS_LINK_SPEED_UNKNOWN) ? 0 : (ULONG)(Adapter->LinkSpeed / 100);
            return R8169CopyQuery(OidRequest, &Data.Ulong, sizeof(Data.Ulong));

        case OID_GEN_VENDOR_ID:
            Data.Ulong = ((ULONG)Adapter->PermanentMacAddress[0] << 16) |
                         ((ULONG)Adapter->PermanentMacAddress[1] << 8) |
                         Adapter->PermanentMacAddress[2];
            return R8169CopyQuery(OidRequest, &Data.Ulong, sizeof(Data.Ulong));

        case OID_GEN_VENDOR_DESCRIPTION:
        {
            static const CHAR Description[] = "Realtek PCIe Gigabit Ethernet Adapter";
            return R8169CopyQuery(OidRequest, Description, sizeof(Description));
        }

        case OID_GEN_DRIVER_VERSION:
        case OID_GEN_VENDOR_DRIVER_VERSION:
            Data.Ushort = 0x0100;
            return R8169CopyQuery(OidRequest, &Data.Ushort, sizeof(Data.Ushort));

        case OID_GEN_CURRENT_PACKET_FILTER:
            Data.Ulong = Adapter->PacketFilter;
            return R8169CopyQuery(OidRequest, &Data.Ulong, sizeof(Data.Ulong));

        case OID_GEN_MAC_OPTIONS:
            Data.Ulong = R8169_MAC_OPTIONS;
            return R8169CopyQuery(OidRequest, &Data.Ulong, sizeof(Data.Ulong));

        case OID_GEN_MEDIA_CONNECT_STATUS:
            Data.MediaState = (Adapter->MediaConnectState == MediaConnectStateConnected) ?
                              NdisMediaStateConnected : NdisMediaStateDisconnected;
            return R8169CopyQuery(OidRequest, &Data.MediaState, sizeof(Data.MediaState));

        case OID_GEN_LINK_STATE:
            Data.LinkState.Header.Type = NDIS_OBJECT_TYPE_DEFAULT;
            Data.LinkState.Header.Revision = NDIS_LINK_STATE_REVISION_1;
            Data.LinkState.Header.Size = sizeof(NDIS_LINK_STATE);
            Data.LinkState.MediaConnectState = Adapter->MediaConnectState;
            Data.LinkState.MediaDuplexState = MediaDuplexStateFull;
            Data.LinkState.XmitLinkSpeed = Adapter->LinkSpeed;
            Data.LinkState.RcvLinkSpeed = Adapter->LinkSpeed;
            Data.LinkState.PauseFunctions = NdisPauseFunctionsUnsupported;
            return R8169CopyQuery(OidRequest, &Data.LinkState, sizeof(Data.LinkState));

        case OID_GEN_XMIT_OK:
            Data.Ulong64 = Adapter->TxPackets;
            return R8169CopyQuery(OidRequest, &Data.Ulong64, sizeof(Data.Ulong64));

        case OID_GEN_RCV_OK:
            Data.Ulong64 = Adapter->RxPackets;
            return R8169CopyQuery(OidRequest, &Data.Ulong64, sizeof(Data.Ulong64));

        case OID_GEN_XMIT_ERROR:
            Data.Ulong64 = Adapter->TxErrors;
            return R8169CopyQuery(OidRequest, &Data.Ulong64, sizeof(Data.Ulong64));

        case OID_GEN_RCV_ERROR:
            Data.Ulong64 = Adapter->RxErrors;
            return R8169CopyQuery(OidRequest, &Data.Ulong64, sizeof(Data.Ulong64));

        case OID_GEN_RCV_NO_BUFFER:
            Data.Ulong64 = Adapter->RxNoBuffer;
            return R8169CopyQuery(OidRequest, &Data.Ulong64, sizeof(Data.Ulong64));

        case OID_802_3_PERMANENT_ADDRESS:
            return R8169CopyQuery(OidRequest, Adapter->PermanentMacAddress, ETH_LENGTH_OF_ADDRESS);

        case OID_802_3_CURRENT_ADDRESS:
            return R8169CopyQuery(OidRequest, Adapter->CurrentMacAddress, ETH_LENGTH_OF_ADDRESS);

        case OID_802_3_MULTICAST_LIST:
            return R8169CopyQuery(OidRequest, Adapter->MulticastList, Adapter->MulticastCount * ETH_LENGTH_OF_ADDRESS);

        case OID_802_3_MAXIMUM_LIST_SIZE:
            Data.Ulong = R8169_MAX_MULTICAST;
            return R8169CopyQuery(OidRequest, &Data.Ulong, sizeof(Data.Ulong));
    }

    return NDIS_STATUS_NOT_SUPPORTED;
}

static NDIS_STATUS
R8169SetInformation(
    _In_ PR8169_ADAPTER Adapter,
    _Inout_ PNDIS_OID_REQUEST OidRequest)
{
    PVOID Buffer = OidRequest->DATA.SET_INFORMATION.InformationBuffer;
    ULONG Length = OidRequest->DATA.SET_INFORMATION.InformationBufferLength;

    OidRequest->DATA.SET_INFORMATION.BytesRead = 0;
    OidRequest->DATA.SET_INFORMATION.BytesNeeded = 0;

    switch (OidRequest->DATA.SET_INFORMATION.Oid)
    {
        case OID_GEN_CURRENT_PACKET_FILTER:
            if (Length < sizeof(ULONG))
            {
                OidRequest->DATA.SET_INFORMATION.BytesNeeded = sizeof(ULONG);
                return NDIS_STATUS_INVALID_LENGTH;
            }
            if (*(PULONG)Buffer & ~R8169_SUPPORTED_FILTERS)
                return NDIS_STATUS_NOT_SUPPORTED;
            Adapter->PacketFilter = *(PULONG)Buffer;
            R8169ApplyRxFilter(Adapter);
            OidRequest->DATA.SET_INFORMATION.BytesRead = sizeof(ULONG);
            return NDIS_STATUS_SUCCESS;

        case OID_GEN_CURRENT_LOOKAHEAD:
            if (Length < sizeof(ULONG))
            {
                OidRequest->DATA.SET_INFORMATION.BytesNeeded = sizeof(ULONG);
                return NDIS_STATUS_INVALID_LENGTH;
            }
            Adapter->Lookahead = min(*(PULONG)Buffer, R8169_MTU);
            OidRequest->DATA.SET_INFORMATION.BytesRead = sizeof(ULONG);
            return NDIS_STATUS_SUCCESS;

        case OID_802_3_MULTICAST_LIST:
            if ((Length % ETH_LENGTH_OF_ADDRESS) != 0)
                return NDIS_STATUS_INVALID_LENGTH;
            if (Length > sizeof(Adapter->MulticastList))
                return NDIS_STATUS_MULTICAST_FULL;
            RtlCopyMemory(Adapter->MulticastList, Buffer, Length);
            Adapter->MulticastCount = Length / ETH_LENGTH_OF_ADDRESS;
            OidRequest->DATA.SET_INFORMATION.BytesRead = Length;
            return NDIS_STATUS_SUCCESS;
    }

    return NDIS_STATUS_NOT_SUPPORTED;
}

static NDIS_STATUS NTAPI
R8169InitializeEx(
    _In_ NDIS_HANDLE MiniportAdapterHandle,
    _In_ NDIS_HANDLE MiniportDriverContext,
    _In_ PNDIS_MINIPORT_INIT_PARAMETERS MiniportInitParameters)
{
    PR8169_ADAPTER Adapter;
    NDIS_STATUS Status;

    UNREFERENCED_PARAMETER(MiniportDriverContext);

    Adapter = ExAllocatePoolWithTag(NonPagedPool, sizeof(*Adapter), R8169_TAG);
    if (!Adapter)
        return NDIS_STATUS_RESOURCES;

    RtlZeroMemory(Adapter, sizeof(*Adapter));
    Adapter->MiniportHandle = MiniportAdapterHandle;
    Adapter->Paused = TRUE;
    Adapter->Lookahead = R8169_MTU;
    Adapter->MediaConnectState = MediaConnectStateDisconnected;
    Adapter->LinkSpeed = NDIS_LINK_SPEED_UNKNOWN;

    NdisAllocateSpinLock(&Adapter->TxLock);
    NdisAllocateSpinLock(&Adapter->RxLock);
    NdisAllocateSpinLock(&Adapter->CommandLock);

    Status = R8169SetRegistrationAttributes(Adapter);
    if (Status == NDIS_STATUS_SUCCESS)
        Status = R8169MapResources(Adapter, (PNDIS_RESOURCE_LIST)MiniportInitParameters->AllocatedResources);
    if (Status == NDIS_STATUS_SUCCESS)
        Status = R8169ProbeDevice(Adapter);
    if (Status == NDIS_STATUS_SUCCESS)
        Status = R8169AllocateDatapath(Adapter);
    if (Status == NDIS_STATUS_SUCCESS)
        Status = R8169RegisterInterrupt(Adapter);
    if (Status == NDIS_STATUS_SUCCESS)
        Status = R8169Activate(Adapter);
    if (Status == NDIS_STATUS_SUCCESS)
    {
        R8169UpdateLink(Adapter, FALSE);
        Status = R8169SetGeneralAttributes(Adapter);
    }

    if (Status != NDIS_STATUS_SUCCESS)
    {
        R8169Release(Adapter);
        return Status;
    }

    return NDIS_STATUS_SUCCESS;
}

static VOID NTAPI
R8169HaltEx(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _In_ NDIS_HALT_ACTION HaltAction)
{
    UNREFERENCED_PARAMETER(HaltAction);
    R8169Release((PR8169_ADAPTER)MiniportAdapterContext);
}

static NDIS_STATUS NTAPI
R8169Pause(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _In_ PNDIS_MINIPORT_PAUSE_PARAMETERS PauseParameters)
{
    UNREFERENCED_PARAMETER(PauseParameters);
    ((PR8169_ADAPTER)MiniportAdapterContext)->Paused = TRUE;
    return NDIS_STATUS_SUCCESS;
}

static NDIS_STATUS NTAPI
R8169Restart(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _In_ PNDIS_MINIPORT_RESTART_PARAMETERS RestartParameters)
{
    UNREFERENCED_PARAMETER(RestartParameters);
    ((PR8169_ADAPTER)MiniportAdapterContext)->Paused = FALSE;
    return NDIS_STATUS_SUCCESS;
}

static VOID NTAPI
R8169SendNetBufferLists(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _In_ PNET_BUFFER_LIST NetBufferLists,
    _In_ NDIS_PORT_NUMBER PortNumber,
    _In_ ULONG SendFlags)
{
    PR8169_ADAPTER Adapter = (PR8169_ADAPTER)MiniportAdapterContext;
    PNET_BUFFER_LIST NetBufferList = NetBufferLists;
    PNET_BUFFER_LIST Head = NULL;
    PNET_BUFFER_LIST Tail = NULL;
    ULONG CompleteFlags = 0;

    UNREFERENCED_PARAMETER(PortNumber);

    if (NDIS_TEST_SEND_AT_DISPATCH_LEVEL(SendFlags))
        CompleteFlags |= NDIS_SEND_COMPLETE_FLAGS_DISPATCH_LEVEL;

    R8169CompleteTransmits(Adapter);

    while (NetBufferList)
    {
        PNET_BUFFER_LIST Next = NET_BUFFER_LIST_NEXT_NBL(NetBufferList);
        NDIS_STATUS Status;

        NET_BUFFER_LIST_NEXT_NBL(NetBufferList) = NULL;
        Status = R8169QueueNetBufferList(Adapter, NetBufferList);
        NET_BUFFER_LIST_STATUS(NetBufferList) = Status;
        if (Status != NDIS_STATUS_SUCCESS)
            Adapter->TxErrors++;

        if (Tail)
            NET_BUFFER_LIST_NEXT_NBL(Tail) = NetBufferList;
        else
            Head = NetBufferList;
        Tail = NetBufferList;
        NetBufferList = Next;
    }

    if (Head)
        NdisMSendNetBufferListsComplete(Adapter->MiniportHandle, Head, CompleteFlags);
}

static VOID NTAPI
R8169ReturnNetBufferLists(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _In_ PNET_BUFFER_LIST NetBufferLists,
    _In_ ULONG ReturnFlags)
{
    PR8169_ADAPTER Adapter = (PR8169_ADAPTER)MiniportAdapterContext;
    PNET_BUFFER_LIST Curr = NetBufferLists;

    UNREFERENCED_PARAMETER(ReturnFlags);

    NdisAcquireSpinLock(&Adapter->RxLock);
    while (Curr)
    {
        PNET_BUFFER_LIST Next = NET_BUFFER_LIST_NEXT_NBL(Curr);
        ULONG i;

        for (i = 0; i < R8169_NUM_RX_DESC; i++)
        {
            if (Adapter->Rx[i].NetBufferList == Curr)
            {
                PR8169_DESC Desc = &Adapter->RxRing[i];
                Desc->Flags = R8169_DESC_OWN | ((i == R8169_NUM_RX_DESC - 1) ? R8169_DESC_EOR : 0) | R8169_BUFFER_SIZE;
                break;
            }
        }
        Curr = Next;
    }
    NdisReleaseSpinLock(&Adapter->RxLock);
}

static VOID NTAPI
R8169CancelSend(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _In_ PVOID CancelId)
{
    UNREFERENCED_PARAMETER(MiniportAdapterContext);
    UNREFERENCED_PARAMETER(CancelId);
}

static BOOLEAN NTAPI
R8169CheckForHang(
    _In_ NDIS_HANDLE MiniportAdapterContext)
{
    PR8169_ADAPTER Adapter = (PR8169_ADAPTER)MiniportAdapterContext;

    if (Adapter->Activated)
    {
        R8169UpdateLink(Adapter, TRUE);
        R8169CompleteTransmits(Adapter);
    }

    return FALSE;
}

static NDIS_STATUS NTAPI
R8169Reset(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _Out_ PBOOLEAN AddressingReset)
{
    UNREFERENCED_PARAMETER(MiniportAdapterContext);
    *AddressingReset = FALSE;
    return NDIS_STATUS_SUCCESS;
}

static NDIS_STATUS NTAPI
R8169OidRequest(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _Inout_ PNDIS_OID_REQUEST OidRequest)
{
    PR8169_ADAPTER Adapter = (PR8169_ADAPTER)MiniportAdapterContext;

    switch (OidRequest->RequestType)
    {
        case NdisRequestQueryInformation:
        case NdisRequestQueryStatistics:
            return R8169QueryInformation(Adapter, OidRequest);

        case NdisRequestSetInformation:
            return R8169SetInformation(Adapter, OidRequest);

        default:
            return NDIS_STATUS_NOT_SUPPORTED;
    }
}

static VOID NTAPI
R8169CancelOidRequest(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _In_ PVOID RequestId)
{
    UNREFERENCED_PARAMETER(MiniportAdapterContext);
    UNREFERENCED_PARAMETER(RequestId);
}

static VOID NTAPI
R8169DevicePnPEventNotify(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _In_ struct _NET_DEVICE_PNP_EVENT *NetDevicePnPEvent)
{
    UNREFERENCED_PARAMETER(MiniportAdapterContext);
    UNREFERENCED_PARAMETER(NetDevicePnPEvent);
}

static VOID NTAPI
R8169Shutdown(
    _In_ NDIS_HANDLE MiniportAdapterContext,
    _In_ NDIS_SHUTDOWN_ACTION ShutdownAction)
{
    PR8169_ADAPTER Adapter = (PR8169_ADAPTER)MiniportAdapterContext;

    UNREFERENCED_PARAMETER(ShutdownAction);

    if (Adapter->Activated)
    {
        R8169Write16(Adapter, R8169_REG_IMR, 0);
        R8169Write8(Adapter, R8169_REG_COMMAND, 0);
    }
}

static VOID NTAPI
R8169Unload(
    _In_ PDRIVER_OBJECT DriverObject)
{
    UNREFERENCED_PARAMETER(DriverObject);

    if (R8169DriverHandle)
    {
        NdisMDeregisterMiniportDriver(R8169DriverHandle);
        R8169DriverHandle = NULL;
    }
}

NTSTATUS NTAPI
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath)
{
    NDIS_MINIPORT_DRIVER_CHARACTERISTICS Characteristics;

    RtlZeroMemory(&Characteristics, sizeof(Characteristics));
    Characteristics.Header.Type = NDIS_OBJECT_TYPE_MINIPORT_DRIVER_CHARACTERISTICS;
    Characteristics.Header.Revision = NDIS_MINIPORT_DRIVER_CHARACTERISTICS_REVISION_2;
    Characteristics.Header.Size = NDIS_SIZEOF_MINIPORT_DRIVER_CHARACTERISTICS_REVISION_2;
    Characteristics.MajorNdisVersion = 6;
    Characteristics.MinorNdisVersion = 30;
    Characteristics.MajorDriverVersion = 1;
    Characteristics.MinorDriverVersion = 0;
    Characteristics.InitializeHandlerEx = R8169InitializeEx;
    Characteristics.HaltHandlerEx = R8169HaltEx;
    Characteristics.UnloadHandler = R8169Unload;
    Characteristics.PauseHandler = R8169Pause;
    Characteristics.RestartHandler = R8169Restart;
    Characteristics.OidRequestHandler = R8169OidRequest;
    Characteristics.SendNetBufferListsHandler = R8169SendNetBufferLists;
    Characteristics.ReturnNetBufferListsHandler = R8169ReturnNetBufferLists;
    Characteristics.CancelSendHandler = R8169CancelSend;
    Characteristics.CheckForHangHandlerEx = R8169CheckForHang;
    Characteristics.ResetHandlerEx = R8169Reset;
    Characteristics.DevicePnPEventNotifyHandler = R8169DevicePnPEventNotify;
    Characteristics.ShutdownHandlerEx = R8169Shutdown;
    Characteristics.CancelOidRequestHandler = R8169CancelOidRequest;

    return NdisMRegisterMiniportDriver(DriverObject, RegistryPath, NULL, &Characteristics, &R8169DriverHandle);
}
