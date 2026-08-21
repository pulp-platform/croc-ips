// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see ../../../LICENSES/README.md for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <stdint.h>

#define NEODISPLAY_MAX_PIXELS 576u
#define NEODISPLAY_FRAME_BYTES(pixels) ((pixels) * 4u)

#define NEODISPLAY_16X16_WIDTH  16u
#define NEODISPLAY_16X16_HEIGHT 16u
#define NEODISPLAY_16X16_PIXELS (NEODISPLAY_16X16_WIDTH * NEODISPLAY_16X16_HEIGHT)

#define NEODISPLAY_32X16_WIDTH  32u
#define NEODISPLAY_32X16_HEIGHT 16u
#define NEODISPLAY_32X16_PIXELS (NEODISPLAY_32X16_WIDTH * NEODISPLAY_32X16_HEIGHT)

#define NEODISPLAY_24X24_WIDTH  24u
#define NEODISPLAY_24X24_HEIGHT 24u
#define NEODISPLAY_24X24_PIXELS (NEODISPLAY_24X24_WIDTH * NEODISPLAY_24X24_HEIGHT)

#define NEODISPLAY_PACK_RGB(r, g, b) \
    ((((uint32_t)(r) & 0xffu) << 16) | (((uint32_t)(g) & 0xffu) << 8) | ((uint32_t)(b) & 0xffu))
#define NEODISPLAY_PACK_GRB(r, g, b) \
    ((((uint32_t)(g) & 0xffu) << 16) | (((uint32_t)(r) & 0xffu) << 8) | ((uint32_t)(b) & 0xffu))

#define NEODISPLAY_RGB_SEQUENTIAL(r, g, b) NEODISPLAY_PACK_RGB((r), (g), (b))
#define NEODISPLAY_RGB_24X24(r, g, b)      NEODISPLAY_PACK_GRB((r), (g), (b))
#define NEODISPLAY_RGB(r, g, b)            NEODISPLAY_PACK_GRB((r), (g), (b))

typedef enum {
    NEODISPLAY_LAYOUT_16X16 = 0,
    NEODISPLAY_LAYOUT_32X16 = 1,
    NEODISPLAY_LAYOUT_24X24_TILES = 2
} neodisplay_layout_t;

extern uint32_t neodisplay_framebuffer[NEODISPLAY_MAX_PIXELS];

void neodisplay_init(neodisplay_layout_t layout);
void neodisplay_init_16x16(void);
void neodisplay_init_32x16(void);
void neodisplay_init_24x24_tiles(void);

void neodisplay_clear(uint32_t color);
void neodisplay_set_pixel(uint32_t x, uint32_t y, uint32_t color);
void neodisplay_set_pixel_i32(int32_t x, int32_t y, uint32_t color);
void neodisplay_draw_line(int32_t x0, int32_t y0, int32_t x1, int32_t y1, uint32_t color);
void neodisplay_draw_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t color);
void neodisplay_fill_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t color);
void neodisplay_draw_circle(int32_t cx, int32_t cy, int32_t radius, uint32_t color);

void neodisplay_idle_latch(void);
void neodisplay_draw(void);
