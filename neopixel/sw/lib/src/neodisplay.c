// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see ../../../LICENSES/README.md for details.
// SPDX-License-Identifier: Apache-2.0

#include "neodisplay.h"

#include "neopixel.h"
#include "util.h"

#define PANEL_WIDTH  16u
#define PANEL_HEIGHT 16u
#define TILE_SIZE    8u
#define TILE_COLS    3u
#define TILE_ROWS    3u
#define TILE_LINE_LUT_ENTRIES (24u * 3u)

// C99-compatible compile-time checks for every bundled layout.
#define NEODISPLAY_STATIC_ASSERT(name, condition) \
    typedef char name[(condition) ? 1 : -1]
NEODISPLAY_STATIC_ASSERT(neodisplay_16x16_fits_max,
                         NEODISPLAY_16X16_PIXELS <= NEODISPLAY_MAX_PIXELS);
NEODISPLAY_STATIC_ASSERT(neodisplay_32x16_fits_max,
                         NEODISPLAY_32X16_PIXELS <= NEODISPLAY_MAX_PIXELS);
NEODISPLAY_STATIC_ASSERT(neodisplay_24x24_fits_max,
                         NEODISPLAY_24X24_PIXELS <= NEODISPLAY_MAX_PIXELS);
NEODISPLAY_STATIC_ASSERT(neodisplay_max_fits_ip,
                         NEODISPLAY_MAX_PIXELS <= NPX_MAX_NUM_PIXELS);
#undef NEODISPLAY_STATIC_ASSERT

uint32_t neodisplay_framebuffer[NEODISPLAY_MAX_PIXELS]
    __attribute__((section(".dma_data"), aligned(4)));

static neodisplay_layout_t current_layout;

static const uint8_t panel_base_lut_16x16[1] = { 0 };
static const uint8_t panel_base_lut_32x16[2] = { 0, 1 };

static const uint8_t tile_line_lut[TILE_LINE_LUT_ENTRIES] = {
     0,  8, 16,  1,  9, 17,  2, 10, 18,  3, 11, 19,
     4, 12, 20,  5, 13, 21,  6, 14, 22,  7, 15, 23,
    24, 32, 40, 25, 33, 41, 26, 34, 42, 27, 35, 43,
    28, 36, 44, 29, 37, 45, 30, 38, 46, 31, 39, 47,
    48, 56, 64, 49, 57, 65, 50, 58, 66, 51, 59, 67,
    52, 60, 68, 53, 61, 69, 54, 62, 70, 55, 63, 71
};

static uint32_t display_width(void) {
    switch (current_layout) {
        case NEODISPLAY_LAYOUT_32X16:
            return NEODISPLAY_32X16_WIDTH;
        case NEODISPLAY_LAYOUT_24X24_TILES:
            return NEODISPLAY_24X24_WIDTH;
        case NEODISPLAY_LAYOUT_16X16:
        default:
            return NEODISPLAY_16X16_WIDTH;
    }
}

static uint32_t display_height(void) {
    switch (current_layout) {
        case NEODISPLAY_LAYOUT_24X24_TILES:
            return NEODISPLAY_24X24_HEIGHT;
        case NEODISPLAY_LAYOUT_32X16:
            return NEODISPLAY_32X16_HEIGHT;
        case NEODISPLAY_LAYOUT_16X16:
        default:
            return NEODISPLAY_16X16_HEIGHT;
    }
}

static uint32_t display_pixels(void) {
    switch (current_layout) {
        case NEODISPLAY_LAYOUT_32X16:
            return NEODISPLAY_32X16_PIXELS;
        case NEODISPLAY_LAYOUT_24X24_TILES:
            return NEODISPLAY_24X24_PIXELS;
        case NEODISPLAY_LAYOUT_16X16:
        default:
            return NEODISPLAY_16X16_PIXELS;
    }
}

static uint32_t display_panel_count(void) {
    return (current_layout == NEODISPLAY_LAYOUT_32X16) ? 2u : 1u;
}

void neodisplay_init(neodisplay_layout_t layout) {
    switch (layout) {
        case NEODISPLAY_LAYOUT_32X16:
        case NEODISPLAY_LAYOUT_24X24_TILES:
        case NEODISPLAY_LAYOUT_16X16:
            current_layout = layout;
            break;
        default:
            current_layout = NEODISPLAY_LAYOUT_16X16;
            break;
    }

    neopixel_init_timing(display_pixels(),
                         NPX_TIMING_T1H_DEFAULT, NPX_TIMING_T1L_DEFAULT,
                         NPX_TIMING_T0H_DEFAULT, NPX_TIMING_T0L_DEFAULT,
                         NPX_TIMING_LATCH_DEFAULT, NPX_TIMING_SLEEP_DEFAULT);
}

void neodisplay_init_16x16(void) {
    neodisplay_init(NEODISPLAY_LAYOUT_16X16);
}

void neodisplay_init_32x16(void) {
    neodisplay_init(NEODISPLAY_LAYOUT_32X16);
}

void neodisplay_init_24x24_tiles(void) {
    neodisplay_init(NEODISPLAY_LAYOUT_24X24_TILES);
}

static uint32_t neodisplay_pixel_index(uint32_t x, uint32_t y) {
    if (current_layout == NEODISPLAY_LAYOUT_24X24_TILES) {
        uint32_t tile_x = x >> 3;
        uint32_t lut_index = y + (y << 1) + tile_x;
        return (((uint32_t)tile_line_lut[lut_index]) << 3) + (x & (TILE_SIZE - 1));
    } else {
        const uint8_t *panel_lut = (display_panel_count() == 2) ?
            panel_base_lut_32x16 : panel_base_lut_16x16;
        uint32_t panel = x >> 4;
        uint32_t local_x = x & (PANEL_WIDTH - 1);

        if (y & 1u) {
            local_x = (PANEL_WIDTH - 1) - local_x;
        }

        return (((uint32_t)panel_lut[panel]) << 8) + (y << 4) + local_x;
    }
}

void neodisplay_clear(uint32_t color) {
    uint32_t pixels = display_pixels();

    for (uint32_t i = 0; i < pixels; i++) {
        neodisplay_framebuffer[i] = color;
    }
}

void neodisplay_set_pixel(uint32_t x, uint32_t y, uint32_t color) {
    if (x < display_width() && y < display_height()) {
        neodisplay_framebuffer[neodisplay_pixel_index(x, y)] = color;
    }
}

void neodisplay_set_pixel_i32(int32_t x, int32_t y, uint32_t color) {
    if (x >= 0 && y >= 0) {
        neodisplay_set_pixel((uint32_t)x, (uint32_t)y, color);
    }
}

static int32_t abs_i32(int32_t v) {
    return (v < 0) ? -v : v;
}

void neodisplay_draw_line(int32_t x0, int32_t y0, int32_t x1, int32_t y1, uint32_t color) {
    int32_t dx = abs_i32(x1 - x0);
    int32_t sx = (x0 < x1) ? 1 : -1;
    int32_t dy = -abs_i32(y1 - y0);
    int32_t sy = (y0 < y1) ? 1 : -1;
    int32_t err = dx + dy;

    while (1) {
        neodisplay_set_pixel_i32(x0, y0, color);
        if (x0 == x1 && y0 == y1) {
            break;
        }
        int32_t e2 = err << 1;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

void neodisplay_draw_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t color) {
    if (w == 0 || h == 0) {
        return;
    }

    for (uint32_t xx = 0; xx < w; xx++) {
        neodisplay_set_pixel(x + xx, y, color);
        neodisplay_set_pixel(x + xx, y + h - 1, color);
    }
    for (uint32_t yy = 0; yy < h; yy++) {
        neodisplay_set_pixel(x, y + yy, color);
        neodisplay_set_pixel(x + w - 1, y + yy, color);
    }
}

void neodisplay_fill_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t color) {
    for (uint32_t yy = 0; yy < h; yy++) {
        for (uint32_t xx = 0; xx < w; xx++) {
            neodisplay_set_pixel(x + xx, y + yy, color);
        }
    }
}

void neodisplay_draw_circle(int32_t cx, int32_t cy, int32_t radius, uint32_t color) {
    int32_t x = radius;
    int32_t y = 0;
    int32_t err = 1 - x;

    while (x >= y) {
        neodisplay_set_pixel_i32(cx + x, cy + y, color);
        neodisplay_set_pixel_i32(cx + y, cy + x, color);
        neodisplay_set_pixel_i32(cx - y, cy + x, color);
        neodisplay_set_pixel_i32(cx - x, cy + y, color);
        neodisplay_set_pixel_i32(cx - x, cy - y, color);
        neodisplay_set_pixel_i32(cx - y, cy - x, color);
        neodisplay_set_pixel_i32(cx + y, cy - x, color);
        neodisplay_set_pixel_i32(cx + x, cy - y, color);

        y++;
        if (err < 0) {
            err += (y << 1) + 1;
        } else {
            x--;
            err += ((y - x) << 1) + 1;
        }
    }
}

void neodisplay_idle_latch(void) {
    (void)neopixel_wait_latch_leave();
}

void neodisplay_draw(void) {
    uint32_t pixels = display_pixels();

    // Sticky events belong to the previous command until explicitly cleared.
    // DMA_DONE only means that the source transfer completed; LATCH_LEAVE is
    // the event that marks the end of the displayed frame.
    neopixel_irq_clear(NPX_IRQ_DMA_DONE | NPX_IRQ_DMA_ERROR | NPX_IRQ_LATCH_LEAVE);
    if (!neopixel_setup_dma(neodisplay_framebuffer, NEODISPLAY_FRAME_BYTES(pixels))) {
        return;
    }
    if (!neopixel_wait_dma()) {
        return;
    }
    (void)neopixel_wait_latch_leave();
}
