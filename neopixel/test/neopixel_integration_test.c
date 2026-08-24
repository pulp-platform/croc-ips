// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>

#include "neopixel.h"

static uint32_t frame[] = {0x00ff0000u};

int main(void) {
    // Send a one-pixel DMA frame with one-cycle waveform phases. This checks
    // Croc integration, OBI register and manager paths, and completion.
    neopixel_init_timing(1, 1, 1, 1, 1, 1, 0);

    if (!neopixel_setup_dma(frame, sizeof(frame))) {
        return 1;
    }
    if (!neopixel_wait_frame()) {
        return 2;
    }

    return 0;
}
