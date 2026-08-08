// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Philippe Sauter <phsauter@iis.ee.ethz.ch>

#pragma once

#include <stdint.h>
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
#define NPX_FIFO_LOW_THRES_REG_OFFSET   (0x1C0)
#define NPX_FIFO_HIGH_THRES_REG_OFFSET  (0x1E0)

#define NPX_FIFO_DATA_REG_OFFSET        (0x200)

// WS2812-style timing defaults, converted from nanoseconds by neopixel_init().
#define NPX_NUM_PIXEL_DEFAULT   		(  64)
#define NPX_TIMING_T1H_NS          ( 800)
#define NPX_TIMING_T1L_NS          ( 450)
#define NPX_TIMING_T0H_NS          ( 400)
#define NPX_TIMING_T0L_NS          ( 850)
#define NPX_TIMING_LATCH_NS        (100000)
#define NPX_TIMING_SLEEP_NS        (100000)

#define NPX_CYCLES_FROM_FREQ_NS(freq, ns) \
    (((((uint32_t)(freq)) / 1000000u) * (uint32_t)(ns) + 999u) / 1000u)

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
void neopixel_fifo_write(uint32_t color);
void neopixel_setup_dma(uint32_t *data, uint32_t num_bytes);

#define neopixel_init_freq(freq) \
    neopixel_init_timing(NPX_NUM_PIXEL_DEFAULT, \
                         NPX_CYCLES_FROM_FREQ_NS((freq), NPX_TIMING_T1H_NS), \
                         NPX_CYCLES_FROM_FREQ_NS((freq), NPX_TIMING_T1L_NS), \
                         NPX_CYCLES_FROM_FREQ_NS((freq), NPX_TIMING_T0H_NS), \
                         NPX_CYCLES_FROM_FREQ_NS((freq), NPX_TIMING_T0L_NS), \
                         NPX_CYCLES_FROM_FREQ_NS((freq), NPX_TIMING_LATCH_NS), \
                         NPX_CYCLES_FROM_FREQ_NS((freq), NPX_TIMING_SLEEP_NS))

static inline void neopixel_activate_irq() {
    asm volatile("csrs mie, %0" ::"r"(1 << (16+3)) : "memory");
}
