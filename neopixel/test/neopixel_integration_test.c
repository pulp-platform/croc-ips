// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>

#include "util.h"
#include "neopixel.h"

// More words than the FIFO holds, so the DMA stays busy until the controller has drained it
#define NUM_PIXELS      20
// One phase of every bit lasts 2 cycles, a bit takes 4 cycles and a pixel has 24 bits
#define CYCLES_PER_BIT  4
#define BITS_PER_PIXEL  24

static uint32_t frame_one[NUM_PIXELS];
static uint32_t frame_two[NUM_PIXELS];

int main(void) {
    // Send two DMA frames back to back. The second one is started while the first is still
    // running and has to wait in the DMA command queue. This checks Croc integration, OBI
    // register and manager paths, the queue and completion.
    for (int i = 0; i < NUM_PIXELS; i++) {
        frame_one[i] = 0x00ff0000u + (uint32_t)i;
        frame_two[i] = 0x0000ff00u + (uint32_t)i;
    }
    neopixel_init_timing(NUM_PIXELS, 2, 2, 2, 2, 2, 0);

    uint32_t start = (uint32_t)get_mcycle();
    if (!neopixel_setup_dma(frame_one, sizeof(frame_one))) {
        return 1;
    }
    if (!neopixel_dma_busy()) {
        return 2;
    }
    if (!neopixel_setup_dma(frame_two, sizeof(frame_two))) {
        return 3;
    }
    // A third frame does not fit into the queue
    if (!neopixel_dma_queued() || neopixel_setup_dma(frame_one, sizeof(frame_one))) {
        return 4;
    }

    // LATCH_LEAVE is reported once the controller is idle, i.e. after both frames
    if (!neopixel_wait_frame()) {
        return 5;
    }
    if (neopixel_dma_busy()) {
        return 6;
    }
    // Both frames must have been shifted out completely
    uint32_t elapsed = (uint32_t)get_mcycle() - start;
    if (elapsed < 2u * NUM_PIXELS * BITS_PER_PIXEL * CYCLES_PER_BIT) {
        return 7;
    }

    // At rest: no frame active, empty FIFO
    if ((neopixel_status() & NPX_STATUS_FRAME_ACTIVE) || neopixel_fifo_level() != 0) {
        return 8;
    }

    // Abort and flush discard a running transfer
    neopixel_irq_clear(NPX_IRQ_EVENT_MASK);
    if (!neopixel_setup_dma(frame_one, sizeof(frame_one))) {
        return 9;
    }
    neopixel_dma_abort();
    neopixel_fifo_flush();
    // The wait ends without DMA_DONE, it must not hang
    if (neopixel_wait_dma() || neopixel_dma_busy()) {
        return 10;
    }
    if (neopixel_irq_status() & NPX_IRQ_DMA_DONE) {
        return 11;
    }
    // A frame that had already started ends with zeros. Wait for the controller to be idle.
    for (int i = 0; neopixel_status() & NPX_STATUS_FRAME_ACTIVE; i++) {
        if (i > 100000) {
            return 12;
        }
    }
    if (neopixel_fifo_level() != 0) {
        return 13;
    }
    // The wait for the latch ends too, whether or not the stopped frame had started
    (void)neopixel_wait_latch_leave();
    // The FIFO can be taken over by software after an abort, whatever the frame did
    if (!neopixel_select_fifo()) {
        return 14;
    }

    return 0;
}
