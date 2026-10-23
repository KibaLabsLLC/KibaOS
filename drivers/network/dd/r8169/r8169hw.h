/*
 * PROJECT:     KibaOS Network Drivers
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Realtek RTL8169 / RTL8168 / RTL8111 PCIe Gigabit Ethernet Hardware Definitions
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif.ing@outlook.com>
 */

#ifndef _R8169HW_H_
#define _R8169HW_H_

#define R8169_REG_MAC0               0x00
#define R8169_REG_MAC4               0x04
#define R8169_REG_MAR0               0x08
#define R8169_REG_MAR4               0x0C
#define R8169_REG_TX_DESC_ADDR_LOW   0x20
#define R8169_REG_TX_DESC_ADDR_HIGH  0x24
#define R8169_REG_COMMAND            0x37
#define R8169_REG_TX_POLL            0x38
#define R8169_REG_IMR                0x3C
#define R8169_REG_ISR                0x3E
#define R8169_REG_TCR                0x40
#define R8169_REG_RCR                0x44
#define R8169_REG_PHY_STATUS         0x6C
#define R8169_REG_RMS                0xDA
#define R8169_REG_RX_DESC_ADDR_LOW   0xE4
#define R8169_REG_RX_DESC_ADDR_HIGH  0xE8

#define R8169_CMD_RESET              0x10
#define R8169_CMD_RX_ENABLE          0x08
#define R8169_CMD_TX_ENABLE          0x04

#define R8169_POLL_NORMAL            0x40

#define R8169_INT_RX_OK              0x0001
#define R8169_INT_RX_ERR             0x0002
#define R8169_INT_TX_OK              0x0004
#define R8169_INT_TX_ERR             0x0008
#define R8169_INT_RX_OVERFLOW       0x0010
#define R8169_INT_LINK_CHANGE        0x0020
#define R8169_INT_SYSTEM_ERROR       0x8000

#define R8169_INT_DEFAULT            (R8169_INT_RX_OK | R8169_INT_RX_ERR | \
                                      R8169_INT_TX_OK | R8169_INT_TX_ERR | \
                                      R8169_INT_RX_OVERFLOW | R8169_INT_LINK_CHANGE)

#define R8169_RCR_ACCEPT_ALL         0x00000001
#define R8169_RCR_ACCEPT_PHYS        0x00000002
#define R8169_RCR_ACCEPT_MULTI       0x00000004
#define R8169_RCR_ACCEPT_BROAD       0x00000008
#define R8169_RCR_ACCEPT_ALL_MULTI   0x00000010
#define R8169_RCR_MXDMA_UNLIMITED    0x00000700

#define R8169_TCR_MXDMA_UNLIMITED    0x00000700

#define R8169_PHY_LINK               0x02
#define R8169_PHY_1000M              0x10
#define R8169_PHY_100M               0x08
#define R8169_PHY_FULL_DUPLEX        0x01

#define R8169_DESC_OWN               0x80000000
#define R8169_DESC_EOR               0x40000000
#define R8169_DESC_FS                0x20000000
#define R8169_DESC_LS                0x10000000
#define R8169_DESC_LEN_MASK          0x00003FFF

#include <pshpack1.h>
typedef struct _R8169_DESC
{
    ULONG Flags;
    ULONG VlanFlags;
    ULONG64 BufferAddress;
} R8169_DESC, *PR8169_DESC;
#include <poppack.h>

#endif
