// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see ../../../LICENSES/README.md for details.
// SPDX-License-Identifier: Apache-2.0
//
// Nils Wistoff <nwistoff@iis.ee.ethz.ch>
// Paul Scheffler <paulsc@iis.ee.ethz.ch>

#include "neopixel.h"
#include "util.h"
#include "config.h"

#include <stddef.h>

static uint32_t neopixel_fifo_owner = NPX_FIFO_REG_DEACTIVATED;
static bool neopixel_latch_leave_observed = true;

// Select a FIFO producer and verify that the register accepted the value.
// Keep the software cache unchanged when hardware reports a different owner.
static bool neopixel_select_owner(uint32_t owner) {
    *reg32(NPX_BASE_ADDR, NPX_FIFO_REG_OFFSET) = owner;
    asm volatile("fence iorw, iorw" ::: "memory");
    uint32_t observed = *reg32(NPX_BASE_ADDR, NPX_FIFO_REG_OFFSET);
    if (observed != owner) {
        return false;
    }
    neopixel_fifo_owner = owner;
    return true;
}

void neopixel_init_timing(uint32_t num_pixels,
                          uint32_t t1h, uint32_t t1l,
                          uint32_t t0h, uint32_t t0l,
                          uint32_t latch, uint32_t sleep) {
    if (num_pixels > NPX_MAX_NUM_PIXELS) {
        num_pixels = NPX_MAX_NUM_PIXELS;
    }

    *reg32(NPX_BASE_ADDR, NPX_NUM_PIXEL_REG_OFFSET) = num_pixels;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_T1H_REG_OFFSET) = t1h;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_T1L_REG_OFFSET) = t1l;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_T0H_REG_OFFSET) = t0h;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_T0L_REG_OFFSET) = t0l;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_LATCH_REG_OFFSET) = latch;
    *reg32(NPX_BASE_ADDR, NPX_TIMING_SLEEP_REG_OFFSET) = sleep;
    neopixel_latch_leave_observed =
        neopixel_select_owner(NPX_FIFO_REG_DEACTIVATED);
}

void neopixel_init() {
    neopixel_init_timing(NPX_NUM_PIXEL_DEFAULT,
                         NPX_TIMING_T1H_DEFAULT, NPX_TIMING_T1L_DEFAULT,
                         NPX_TIMING_T0H_DEFAULT, NPX_TIMING_T0L_DEFAULT,
                         NPX_TIMING_LATCH_DEFAULT, NPX_TIMING_SLEEP_DEFAULT);
}

bool neopixel_setup_dma(uint32_t *data, uint32_t num_bytes) {
    uint32_t configured_pixels = *reg32(NPX_BASE_ADDR, NPX_NUM_PIXEL_REG_OFFSET);

    if (data == NULL || num_bytes == 0 ||
        (((uintptr_t)data & 0x3u) != 0) || ((num_bytes & 0x3u) != 0) ||
        configured_pixels == 0 ||
        num_bytes != configured_pixels * (uint32_t)sizeof(uint32_t) ||
        neopixel_dma_busy()) {
        return false;
    }

    if (neopixel_fifo_owner != NPX_FIFO_REG_MODE_DMA &&
        !neopixel_latch_leave_observed) {
        return false;
    }

    if (neopixel_fifo_owner != NPX_FIFO_REG_MODE_DMA) {
        if (!neopixel_select_owner(NPX_FIFO_REG_MODE_DMA)) {
            return false;
        }
    }
    *reg32(NPX_BASE_ADDR, NPX_DMA_START_REG_OFFSET) = (uint32_t)data;
    *reg32(NPX_BASE_ADDR, NPX_DMA_NUM_BYTES_REG_OFFSET) = num_bytes;
    // DMA_VALID is a write-one command strobe. The hardware clears or
    // consumes the request; software must not follow it with a zero write.
    asm volatile("fence iorw, iorw" ::: "memory");
    *reg32(NPX_BASE_ADDR, NPX_DMA_VALID_REG_OFFSET) = 0x01;
    neopixel_latch_leave_observed = false;
    return true;
}

bool neopixel_fifo_write(uint32_t color) {
    // FIFO mode remains selected after this call so that a caller can queue
    // several words without repeatedly switching ownership of the FIFO.
    if (!neopixel_select_fifo()) {
        return false;
    }
    *reg32(NPX_BASE_ADDR, NPX_FIFO_DATA_REG_OFFSET) = color;
    neopixel_latch_leave_observed = false;
    return true;
}

bool neopixel_select_fifo(void) {
    if (neopixel_fifo_owner != NPX_FIFO_REG_MODE_FIFO) {
        if (!neopixel_latch_leave_observed || neopixel_dma_busy()) {
            return false;
        }
        if (!neopixel_select_owner(NPX_FIFO_REG_MODE_FIFO)) {
            return false;
        }
    }
    return true;
}

uint32_t neopixel_irq_status(void) {
    uint32_t events = *reg32(NPX_BASE_ADDR, NPX_IRQ_STATUS_REG_OFFSET);
    if ((events & NPX_IRQ_LATCH_LEAVE) != 0) {
        neopixel_latch_leave_observed = true;
    }
    return events;
}

void neopixel_irq_clear(uint32_t events) {
    events &= NPX_IRQ_EVENT_MASK;
    *reg32(NPX_BASE_ADDR, NPX_IRQ_STATUS_REG_OFFSET) = events;
}

uint32_t neopixel_dma_status(void) {
    return *reg32(NPX_BASE_ADDR, NPX_DMA_STATUS_REG_OFFSET);
}

bool neopixel_dma_busy(void) {
    return (neopixel_dma_status() & NPX_DMA_STATUS_BUSY) != 0;
}

bool neopixel_wait_dma(void) {
    bool dma_error = false;
    bool dma_done = false;

    for (;;) {
        uint32_t events = neopixel_irq_status();
        if ((events & NPX_IRQ_DMA_ERROR) != 0) {
            dma_error = true;
        }
        if ((events & NPX_IRQ_DMA_DONE) != 0) {
            dma_done = true;
        }

        if (!neopixel_dma_busy()) {
            if (dma_error) {
                return false;
            }
            if (dma_done) {
                return true;
            }
        }
    }
}

bool neopixel_wait_latch_leave(void) {
    for (;;) {
        uint32_t events = neopixel_irq_status();
        if ((events & NPX_IRQ_DMA_ERROR) != 0) {
            return false;
        }
        if ((events & NPX_IRQ_LATCH_LEAVE) != 0) {
            return true;
        }
    }
}

bool neopixel_wait_frame(void) {
    return neopixel_wait_dma() && neopixel_wait_latch_leave();
}
