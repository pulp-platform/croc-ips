// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>

#include "neopixel.h"

int main(void) {
    // Send a one-pixel FIFO frame with one-cycle waveform phases. This checks
    // Croc integration, OBI register/FIFO paths, and controller completion.
    neopixel_init_timing(1, 1, 1, 1, 1, 1, 0);

    if (!neopixel_fifo_write(0x00ff0000u)) {
        return 1;
    }
    if (!neopixel_wait_latch_leave()) {
        return 2;
    }

    return 0;
}
