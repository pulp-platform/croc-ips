// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
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

#define STARTUP_LATCH_NOPS       2000000u
#define POST_FRAME_WAIT_NOPS      200000u
#define BITS_PER_PIXEL                24u
#define NOP_WAIT_LOOP_CYCLES_SHIFT     2u
#define DMA_FRAME_GUARD_NOPS        4000u
#define COUNTER_WRAP_PIXELS          512u
#define POST_WRAP_PIXELS              64u

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

void neodisplay_wait(uint32_t nops) {
    while (nops--) {
        asm volatile("nop");
    }
}

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
    current_layout = layout;
    *reg32(NPX_BASE_ADDR, NPX_NUM_PIXEL_REG_OFFSET) = display_pixels();
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

uint32_t neodisplay_pixel_index(uint32_t x, uint32_t y) {
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

static uint32_t neopixel_cycles_for_color(uint32_t color,
                                          uint32_t t1_cycles,
                                          uint32_t t0_cycles) {
    uint32_t cycles = 0;
    uint32_t mask = 1u << (BITS_PER_PIXEL - 1);

    while (mask != 0) {
        cycles += (color & mask) ? t1_cycles : t0_cycles;
        mask >>= 1;
    }

    return cycles;
}

static uint32_t frame_wait_nops(uint32_t pixels) {
    uint32_t t1_cycles = *reg32(NPX_BASE_ADDR, NPX_TIMING_T1H_REG_OFFSET) +
                         *reg32(NPX_BASE_ADDR, NPX_TIMING_T1L_REG_OFFSET);
    uint32_t t0_cycles = *reg32(NPX_BASE_ADDR, NPX_TIMING_T0H_REG_OFFSET) +
                         *reg32(NPX_BASE_ADDR, NPX_TIMING_T0L_REG_OFFSET);
    uint32_t cycles = 0;

    for (uint32_t i = 0; i < pixels; i++) {
        cycles += neopixel_cycles_for_color(neodisplay_framebuffer[i], t1_cycles, t0_cycles);
    }

    return (cycles >> NOP_WAIT_LOOP_CYCLES_SHIFT) + DMA_FRAME_GUARD_NOPS;
}

void neodisplay_idle_latch(void) {
    *reg32(NPX_BASE_ADDR, NPX_DMA_VALID_REG_OFFSET) = 0;
    *reg32(NPX_BASE_ADDR, NPX_FIFO_REG_OFFSET) = NPX_FIFO_REG_DEACTIVATED;
    *reg32(NPX_BASE_ADDR, NPX_NUM_PIXEL_REG_OFFSET) = 1;
    neodisplay_wait(STARTUP_LATCH_NOPS);
}

void neodisplay_draw(void) {
    uint32_t pixels = display_pixels();

    *reg32(NPX_BASE_ADDR, NPX_DMA_VALID_REG_OFFSET) = 0;
    *reg32(NPX_BASE_ADDR, NPX_NUM_PIXEL_REG_OFFSET) = pixels;
    neodisplay_wait(1000);

    neopixel_setup_dma(neodisplay_framebuffer, NEODISPLAY_FRAME_BYTES(pixels));

    if (pixels > COUNTER_WRAP_PIXELS) {
        neodisplay_wait(frame_wait_nops(COUNTER_WRAP_PIXELS));
        *reg32(NPX_BASE_ADDR, NPX_NUM_PIXEL_REG_OFFSET) = pixels - COUNTER_WRAP_PIXELS;
    }

    neodisplay_wait(frame_wait_nops(pixels));
    neodisplay_wait(POST_FRAME_WAIT_NOPS);
}
