// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see ../../../LICENSES/README.md for details.
// SPDX-License-Identifier: Apache-2.0
//
// Philippe Sauter <phsauter@iis.ee.ethz.ch>

#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "config.h"


// Register offsets
#define NPX_MAX_NUM_PIXEL_REG_OFFSET    (0x000)
#define NPX_MIN_FREQ_REG_OFFSET    	    (0x020)
#define NPX_NUM_PIXEL_REG_OFFSET    	(0x040)
#define NPX_TIMING_T1H_REG_OFFSET   	(0x060)
#define NPX_TIMING_T1L_REG_OFFSET   	(0x080)
#define NPX_TIMING_T0H_REG_OFFSET   	(0x0A0)
#define NPX_TIMING_T0L_REG_OFFSET   	(0x0C0)
#define NPX_TIMING_LATCH_REG_OFFSET 	(0x0E0)
#define NPX_TIMING_SLEEP_REG_OFFSET		(0x100)

#define NPX_DMA_START_REG_OFFSET		(0x120)
#define NPX_DMA_NUM_BYTES_REG_OFFSET	(0x140)
#define NPX_DMA_VALID_REG_OFFSET		(0x160)

#define NPX_FIFO_REG_OFFSET         	(0x180)
#define NPX_FIFO_REG_MODE_FIFO         	(0x01)
#define NPX_FIFO_REG_MODE_DMA         	(0x02)
#define NPX_FIFO_REG_DEACTIVATED        (0x00)

#define NPX_IRQ_MASK_REG_OFFSET         (0x1A0)
#define NPX_IRQ_STATUS_REG_OFFSET       (0x1B0)
#define NPX_FIFO_LOW_THRES_REG_OFFSET   (0x1C0)
#define NPX_FIFO_HIGH_THRES_REG_OFFSET  (0x1E0)

#define NPX_DMA_STATUS_REG_OFFSET       (0x1D0)

#define NPX_FIFO_DATA_REG_OFFSET        (0x200)

// IRQ event masks. IRQ_STATUS is write-one-to-clear (W1C).
#define NPX_IRQ_FIFO_LOW                (1u << 0)
#define NPX_IRQ_FIFO_HIGH               (1u << 1)
#define NPX_IRQ_DMA_DONE                (1u << 2)
#define NPX_IRQ_LATCH_ENTER             (1u << 3)
#define NPX_IRQ_LATCH_LEAVE             (1u << 4)
#define NPX_IRQ_DMA_ERROR               (1u << 5)
#define NPX_IRQ_EVENT_MASK              (NPX_IRQ_FIFO_LOW | NPX_IRQ_FIFO_HIGH | \
                                         NPX_IRQ_DMA_DONE | NPX_IRQ_LATCH_ENTER | \
                                         NPX_IRQ_LATCH_LEAVE | NPX_IRQ_DMA_ERROR)

// DMA_STATUS bit 0 is asserted while a request is pending or active.
#define NPX_DMA_STATUS_BUSY             (1u << 0)

// NeoPixel timing defaults, converted from nanoseconds by neopixel_init().
#define NPX_MAX_NUM_PIXELS            (2048u)
#define NPX_NUM_PIXEL_DEFAULT   		(  64)
#define NPX_TIMING_T1H_NS          ( 800)
#define NPX_TIMING_T1L_NS          ( 450)
#define NPX_TIMING_T0H_NS          ( 400)
#define NPX_TIMING_T0L_NS          ( 850)
#define NPX_TIMING_LATCH_NS        (100000)
#define NPX_TIMING_SLEEP_NS        (100000)

static inline uint32_t neopixel_cycles_from_freq_ns(uint32_t freq, uint32_t ns) {
    uint64_t cycles = (uint64_t)freq * (uint64_t)ns;
    return (uint32_t)((cycles + 999999999ull) / 1000000000ull);
}

#define NPX_CYCLES_FROM_FREQ_NS(freq, ns) \
    neopixel_cycles_from_freq_ns((uint32_t)(freq), (uint32_t)(ns))

#define NPX_CYCLES_FROM_NS(ns) NPX_CYCLES_FROM_FREQ_NS(NPX_FREQ, (ns))

#define NPX_TIMING_T1H_DEFAULT     NPX_CYCLES_FROM_NS(NPX_TIMING_T1H_NS)
#define NPX_TIMING_T1L_DEFAULT     NPX_CYCLES_FROM_NS(NPX_TIMING_T1L_NS)
#define NPX_TIMING_T0H_DEFAULT     NPX_CYCLES_FROM_NS(NPX_TIMING_T0H_NS)
#define NPX_TIMING_T0L_DEFAULT     NPX_CYCLES_FROM_NS(NPX_TIMING_T0L_NS)
#define NPX_TIMING_LATCH_DEFAULT   NPX_CYCLES_FROM_NS(NPX_TIMING_LATCH_NS)
#define NPX_TIMING_SLEEP_DEFAULT   NPX_CYCLES_FROM_NS(NPX_TIMING_SLEEP_NS)

void neopixel_init();
void neopixel_init_timing(uint32_t num_pixels,
                          uint32_t t1h, uint32_t t1l,
                          uint32_t t0h, uint32_t t0l,
                          uint32_t latch, uint32_t sleep);
// Select FIFO ownership and queue one GRB word. FIFO mode remains selected.
// Returns false if ownership could not be selected.
bool neopixel_fifo_write(uint32_t color);
// Select DMA ownership, program one complete raw frame, and trigger it with a
// write-one command.  The byte count must equal the configured pixel count times
// sizeof(uint32_t); partial or multi-frame transfers are rejected.  Returns false
// when the request is invalid, the configured pixel count is zero, DMA is already
// busy, or the owner transition has not been made safe by observing LATCH_LEAVE.
bool neopixel_setup_dma(uint32_t *data, uint32_t num_bytes);
// Select FIFO ownership after a completed frame.  The first selection after
// reset is permitted; later transitions require an observed LATCH_LEAVE event.
bool neopixel_select_fifo(void);
uint32_t neopixel_irq_status(void);
void neopixel_irq_clear(uint32_t events);
uint32_t neopixel_dma_status(void);
bool neopixel_dma_busy(void);
// Poll sticky events.  DMA_ERROR causes the wait to fail, but only after
// DMA_STATUS_BUSY clears and the request reaches its terminal state.  Callers
// should clear stale events before starting a new frame.  DMA_DONE only
// indicates source-transfer completion; wait for LATCH_LEAVE for a fully idle
// frame.
bool neopixel_wait_dma(void);
// LATCH_LEAVE is observed only after the configured sleep period, when the
// controller is fully idle and safe for an ownership transition.
bool neopixel_wait_latch_leave(void);
bool neopixel_wait_frame(void);

static inline void neopixel_init_freq(uint32_t freq) {
    neopixel_init_timing(NPX_NUM_PIXEL_DEFAULT,
                         neopixel_cycles_from_freq_ns(freq, NPX_TIMING_T1H_NS),
                         neopixel_cycles_from_freq_ns(freq, NPX_TIMING_T1L_NS),
                         neopixel_cycles_from_freq_ns(freq, NPX_TIMING_T0H_NS),
                         neopixel_cycles_from_freq_ns(freq, NPX_TIMING_T0L_NS),
                         neopixel_cycles_from_freq_ns(freq, NPX_TIMING_LATCH_NS),
                         neopixel_cycles_from_freq_ns(freq, NPX_TIMING_SLEEP_NS));
}

// Historical Croc helper. The external interrupt mapping is version-specific
// and must be adapted with the target integration.
static inline void neopixel_activate_irq() {
    asm volatile("csrs mie, %0" ::"r"(1 << (16+3)) : "memory");
}
