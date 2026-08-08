// Copyright (c) 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

#include <stdint.h>
#include <stdbool.h>

#include "uart.h"
#include "print.h"
#include "gpio.h"
#include "obi_timer.h"
#include "util.h"
#include "neopixel.h"
#include "font8x8_basic.h"

#define WIDTH  8
#define HEIGHT 8
#define NUM_PIXELS (WIDTH * HEIGHT)
#define NUM_BYTES  (NUM_PIXELS *4)
#define TEXT_COLOR (0x080808)
#define SCROLL_DELAY_CYCLES ((TB_FREQUENCY / 1000u) * 30u)

//*****************************************************************************
// Text Rendering
//*****************************************************************************
// font8x8_basic.h is kept as a local copy; see that header for provenance.
// It is encoded as black/white row-major, 8 bytes per character
// LSB is the first pixel in the row


uint32_t nextColor(void) {
    const uint8_t scale = 8;
    static uint8_t row = 0;
    static uint8_t col = 0;
    uint8_t r = (uint8_t)(row * (256/WIDTH))/scale;
    uint8_t g = (uint8_t)(col * (256/HEIGHT))/scale;
    uint8_t b = (uint8_t)( 255 - (row+col) * (256/(WIDTH+HEIGHT)) )/scale;
    row++;
    if(row >= HEIGHT) {
        row = 0;
        col++;
    }
    if(col >= WIDTH) {
        col = 0;
    }
    return ( (r << 16) | (g << 8) | b );
}

/**
 * @brief Render 8x8 font to Neopixel frame
 *
 *
 * @param frame     pointer to a WIDTH*HEIGHT array to be filled with test frame
 * @param character ASCII encoded character
 */
void renderCharacter(uint32_t *frame, char character) {
    uint8_t font_bit;
    uint32_t pixel;
    uint32_t color = nextColor();
    for (int row = 0; row < HEIGHT; row++) {
        for (int col = 0; col < WIDTH; col++) {
            // expand the corresponding character bit to the pixel
            if (character >= 128)
                character = 0;
            font_bit = (font8x8_basic[character][col] >> (HEIGHT-row-1)) & 0x01;
            pixel = font_bit ? color : 0;
            frame[row*WIDTH +col] = pixel;
        }
    }
}


const char *hello = "Hello World! Hello World! Hello World!";
char string[255];
uint32_t frame[2*NUM_PIXELS]  __attribute__((section(".dma_data")));

void croc_interrupt_handler(uint32_t cause) {
    if (cause == IRQ_OBI_TIMER) {
        obi_timer_clear_expired();
    }
}

int main(void) {
    uint32_t *frameOne = &frame[0];
    // reduced kerning
    //uint32_t *frameTwo = &frame[NUM_PIXELS - WIDTH];
    uint32_t *frameTwo = &frame[NUM_PIXELS];

    for (int i = 0; i < 39; i++)
    {
        string[i] = hello[i];
    }
    
    uart_init();
    neopixel_init();
    printf("Starting test...\n");
    uart_write_flush();
    printf("Test1234\n");
    uart_write_flush();

    while(1) {
        // render and display string
        // interrupt based scrolling deactivated -> too fast
        // use sleep instead
        *reg32(NPX_BASE_ADDR, NPX_IRQ_MASK_REG_OFFSET) = 0x01 << 4;
        //set_mie(1);

        for(int i=0; i<255; i++) {
            renderCharacter(frameTwo, string[i]);
            renderCharacter(frameOne, string[i+1]);
            for(uint8_t shift=0; shift<8; shift++)
            {
                //neopixel_activate_irq();
                if (!neopixel_setup_dma(frameTwo - shift * WIDTH, NUM_BYTES)) {
                    continue;
                }
                //wfi();
                obi_timer_sleep(SCROLL_DELAY_CYCLES);
            }
            if(string[i+1] == '\n' || string[i+1] == 0) {
                break;
            }
        }
    }
    
    return 0;
}
