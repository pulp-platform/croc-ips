// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Nils Wistoff <nwistoff@iis.ee.ethz.ch>
// Paul Scheffler <paulsc@iis.ee.ethz.ch>

#include "neopixel.h"
#include "util.h"
#include "config.h"

void neopixel_init_timing(uint32_t num_pixels,
                          uint32_t t1h, uint32_t t1l,
                          uint32_t t0h, uint32_t t0l,
                          uint32_t latch, uint32_t sleep) {
    *reg32(NPX_BASE_ADDR, NPX_NUM_PIXEL_REG_OFFSET) = num_pixels;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_T1H_REG_OFFSET) = t1h;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_T1L_REG_OFFSET) = t1l;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_T0H_REG_OFFSET) = t0h;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_T0L_REG_OFFSET) = t0l;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_LATCH_REG_OFFSET) = latch;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_SLEEP_REG_OFFSET) = sleep;
    *reg32(NPX_BASE_ADDR, NPX_FIFO_REG_OFFSET) = NPX_FIFO_REG_DEACTIVATED;
}

void neopixel_init() {
    neopixel_init_timing(NPX_NUM_PIXEL_DEFAULT,
                         NPX_TIMING_T1H_DEFAULT, NPX_TIMING_T1L_DEFAULT,
                         NPX_TIMING_T0H_DEFAULT, NPX_TIMING_T0L_DEFAULT,
                         NPX_TIMING_LATCH_DEFAULT, NPX_TIMING_SLEEP_DEFAULT);
}

void neopixel_setup_dma(uint32_t *data, uint32_t num_bytes) {
    *reg32(NPX_BASE_ADDR, NPX_FIFO_REG_OFFSET) = NPX_FIFO_REG_MODE_DMA;
    *reg32(NPX_BASE_ADDR, NPX_DMA_START_REG_OFFSET) = (uint32_t)data;
    *reg32(NPX_BASE_ADDR, NPX_DMA_NUM_BYTES_REG_OFFSET) = num_bytes;
    *reg32(NPX_BASE_ADDR, NPX_DMA_VALID_REG_OFFSET) = 0x01; 
    *reg32(NPX_BASE_ADDR, NPX_DMA_VALID_REG_OFFSET) = 0x00; 
}

void neopixel_fifo_write(uint32_t color) {
    *reg32(NPX_BASE_ADDR, NPX_FIFO_REG_OFFSET) = NPX_FIFO_REG_MODE_FIFO; 
    *reg32(NPX_BASE_ADDR, NPX_FIFO_DATA_REG_OFFSET) = color;
    *reg32(NPX_BASE_ADDR, NPX_FIFO_REG_OFFSET) = NPX_FIFO_REG_DEACTIVATED; 
}
