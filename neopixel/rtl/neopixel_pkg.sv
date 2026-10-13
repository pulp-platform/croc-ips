// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Luisa Wüthrich <lwuethri@ethz.ch>

`include "obi/typedef.svh"

package neopixel_pkg;

    //import the package from the domain you are on
    import user_pkg::*;

    /////////////////
    // Address map //
    /////////////////

    // Register Address
    parameter bit [31:0] NeoPixelRegisterAddrOffset  = UserNeoPixelAddrOffset;
    parameter bit [31:0] NeoPixelRegisterAddrRange   = 32'h0000_0200;

    // FIFO Address
    parameter bit [31:0] NeoPixelFifoAddrOffset   =
                            NeoPixelRegisterAddrOffset + NeoPixelRegisterAddrRange;
    parameter bit [31:0] NeoPixelFifoAddrRange    = 32'h0000_0E00;

    // The two regions fill the window of the IP, which is a power of two and aligned to its size.
    // Everything outside of the window is an error, everything inside is decoded by a few address
    // bits only, see neopixel.sv.
    parameter int unsigned NeoPixelWindowWidth    = $clog2(NeoPixelRegisterAddrRange +
                                                           NeoPixelFifoAddrRange);
    parameter int unsigned NeoPixelRegisterWidth  = $clog2(NeoPixelRegisterAddrRange);
    parameter int unsigned NumNeoPixelAddress     = 3;  // Register + FIFO + OBI error

    // Enum for bus indices
    typedef enum int {
        NeoPixelError       = 0,
        NeoPixelRegister    = 1,
        NeoPixelFifo        = 2
    } neopixel_demux_outputs_e;

    /////////////////////////////////////
    // Register for Timing Constraints //
    /////////////////////////////////////

    //-------------------------------------------------------------------------------------------
    // Register Unions
    //-------------------------------------------------------------------------------------------

    // Address widths within the block : Defines the max no of Block Addresses
    parameter int AddressWidth = 10;

    // Register space
    parameter int RegisterDepth = 32;

    // The NeoPixel protocol has no fixed cascade limit. This IP is practically
    // limited to 2048 RGB pixels per supplied DMA frame by its DMA memory
    // budget; this is an IP limit, not a NeoPixel protocol limit.
    parameter int unsigned MaxNumNeoPixel = 2048;
    parameter int unsigned PixelCountWidth = $clog2(MaxNumNeoPixel + 1);

    //----Writeable NeoPixel Register------------------------------------------------------------

    // Every register occupies one 32-bit OBI word at the offsets below. Only the low bits of a
    // timing register are stored: a write above the largest value saturates, a read returns the
    // stored value with zeros above it.
    //
    // Core clock from MinFreqHz to 200 MHz:
    //   pulse phases  14 bit: up to 16383 cycles, 82 us at 200 MHz
    //   t_latch       20 bit: up to 1048575 cycles, 5.2 ms at 200 MHz
    //   sleep         24 bit: up to 16777215 cycles, 84 ms at 200 MHz
    parameter int unsigned PulseWidth = 14;
    parameter int unsigned LatchWidth = 20;
    parameter int unsigned SleepWidth = 24;

    // Lowest core clock for which the shortest NeoPixel phase (about 0.4 us) still takes a cycle.
    // Read from the MIN_FREQ register.
    parameter int unsigned MinFreqHz = 3_000_000;

    // Read data of an unmapped register
    parameter logic [31:0] ReadErrorData = 32'hBADCAB1E;

    // The controller counts every phase with one counter
    parameter int unsigned CounterWidth = SleepWidth;

    typedef struct packed {
        logic [PixelCountWidth - 1:0] num_neopixel;   // Number of NeoPixel attached
        logic [PulseWidth - 1:0]      t1h;            // 1 code, high voltage time
        logic [PulseWidth - 1:0]      t1l;            // 1 code, low voltage time
        logic [PulseWidth - 1:0]      t0h;            // 0 code, high voltage time
        logic [PulseWidth - 1:0]      t0l;            // 0 code, low voltage time
        logic [LatchWidth - 1:0]      t_latch;        // Low voltage time
        logic [SleepWidth - 1:0]      sleep;          // Sleep time in idle state
    } neopixel_write_reg_fields_t;

    typedef union packed {
        neopixel_write_reg_fields_t str;        // Access as structured fields
        logic [$bits(neopixel_write_reg_fields_t) - 1:0] arr;   // Access as a flat array
    } neopixel_write_reg_union_t;

    //----Writeable DMA Register-------------------------------------------------------------------

    // Number of Register for the DMA
    parameter int NumDmaReg = 3;

    typedef struct packed {
       logic [RegisterDepth - 1:0] src_addr;    // Source Address in SRAM
       logic [RegisterDepth - 1:0] num_bytes;   // Number of bytes sent to FIFO
       logic [RegisterDepth - 1:0] valid;       // Write-one DMA launch strobe (not stored)
    } dma_write_reg_fields_t;

    typedef union packed {
        dma_write_reg_fields_t str;        // Access as structured fields
        logic [NumDmaReg * RegisterDepth - 1:0] arr;   // Access as a flat array
    } dma_write_reg_union_t;

    //-------------------------------------------------------------------------------------------
    // Register Address Offsets
    //-------------------------------------------------------------------------------------------

    //----Information Register-------------------------------------------------------------------
    // After the chip is printed Software can't change them

    // Number of NeoPixel the controller can support
    parameter logic [AddressWidth - 1:0] MAX_NUM_NEOPIXEL_OFFSET  = 10'h000;
    // Minimum frequency for which the NeoPixel still works
    parameter logic [AddressWidth - 1:0] MIN_FREQ_OFFSET          = 10'h020;

    //----Writeable Register---------------------------------------------------------------------
    // After the chip is printed you can write into it with Software

    // Registers used for the neopixel_controller
    // Number of attached NeoPixels
    parameter logic [AddressWidth - 1:0] NUM_NEOPIXEL_OFFSET      = 10'h040;
    // Timing constraints for the timing control
    // you have to calculate the values
    parameter logic [AddressWidth - 1:0] NEOPIXEL_T1H_OFFSET      = 10'h060;
    parameter logic [AddressWidth - 1:0] NEOPIXEL_T1L_OFFSET      = 10'h080;
    parameter logic [AddressWidth - 1:0] NEOPIXEL_T0H_OFFSET      = 10'h0A0;
    parameter logic [AddressWidth - 1:0] NEOPIXEL_T0L_OFFSET      = 10'h0C0;
    parameter logic [AddressWidth - 1:0] NEOPIXEL_T_LATCH_OFFSET  = 10'h0E0;
    parameter logic [AddressWidth - 1:0] NEOPIXEL_SLEEP_OFFSET    = 10'h100;

    // Registers used for the DMA
    parameter logic [AddressWidth - 1:0] DMA_SRC_ADDR_OFFSET      = 10'h120;
    parameter logic [AddressWidth - 1:0] DMA_NUM_BYTES_OFFSET     = 10'h140;
    parameter logic [AddressWidth - 1:0] DMA_VALID_OFFSET         = 10'h160;
    // Read-only status: bit 0 BUSY is set while a DMA command is pending or active, bit 1 QUEUED
    // while a command waits behind the running one.
    parameter logic [AddressWidth - 1:0] DMA_STATUS_OFFSET        = 10'h1D0;

    // FIFO producer selection, written to FIFO_ACCESS_OFFSET
    parameter logic [AddressWidth - 1:0] FIFO_ACCESS_OFFSET       = 10'h180;
    parameter logic [1:0] FIFO_ACCESS_OFF = 2'b00;  // No producer, writes are rejected
    parameter logic [1:0] FIFO_ACCESS_OBI = 2'b01;  // Software writes the FIFO over OBI
    parameter logic [1:0] FIFO_ACCESS_DMA = 2'b10;  // The DMA writes the FIFO

    // Number of interrupt events
    parameter int unsigned NumIrqEvents = 7;
    // Bit 0: FIFO low; Bit 1: FIFO high; Bit 2: DMA finished; Bit 3: Enter LATCH,
    // Bit 4: Leave LATCH (frame done, after the latch and the sleep); Bit 5: DMA bus error; Bit 6: FIFO underrun (a pixel was sent as zeros
    // because the FIFO was empty).
    parameter logic [AddressWidth - 1:0] NEOPIXEL_IRQ_MASK_OFFSET  = 10'h1A0;
    parameter logic [AddressWidth - 1:0] IRQ_STATUS_OFFSET         = 10'h1B0;

    // Write-one command strobes, reads as zero: bit 0 aborts the queued and the running DMA command,
    // bit 1 flushes the FIFO. When flushing during a transfer, write both bits (0x3) together.
    // Writes to DMA_VALID and to the FIFO after a strobe are not lost.
    parameter logic [AddressWidth - 1:0] CONTROL_OFFSET           = 10'h170;
    // Read-only number of FIFO entries
    parameter logic [AddressWidth - 1:0] FIFO_LEVEL_OFFSET        = 10'h190;
    // Read-only levels: bit 0 frame active, bit 1 FIFO at or below the low threshold, bit 2 FIFO at
    // or above the high threshold
    parameter logic [AddressWidth - 1:0] STATUS_OFFSET            = 10'h1F0;

    // Thresholds for the FIFO interrupts, see FifoLowThresholdDefault and FifoHighThresholdDefault
    parameter logic [AddressWidth - 1:0] NEOPIXEL_FIFO_LOW_OFFSET  = 10'h1C0;
    parameter logic [AddressWidth - 1:0] NEOPIXEL_FIFO_HIGH_OFFSET = 10'h1E0;

    //////////////
    // NeoPixel //
    //////////////

    parameter int unsigned NumBitsPerPixel = 24;

    // A DMA frame holds one 32-bit word per pixel; its size bounds the DMA command length.
    parameter int unsigned MaxFrameBytes   = MaxNumNeoPixel * 4;
    parameter int unsigned FrameBytesWidth = $clog2(MaxFrameBytes + 1);

    /////////////////////////
    // FIFO for color data //
    /////////////////////////

    // FIFO parameters
    // At least 4: the default thresholds below are 2 and FifoDepth / 2.
    parameter int unsigned FifoDepth = 8;

    // Default thresholds of the FIFO interrupts
    parameter int unsigned FifoLowThresholdDefault  = 2;
    parameter int unsigned FifoHighThresholdDefault = FifoDepth / 2;

    parameter int unsigned FifoAddrDepth   = (FifoDepth > 1) ? $clog2(FifoDepth) : 1;
    // Thresholds must represent every legal occupancy, including a full FIFO.
    parameter int unsigned FifoThresholdWidth = $clog2(FifoDepth + 1);

endpackage
