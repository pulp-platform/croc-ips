// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Luisa Wüthrich <lwuethri@ethz.ch>

`include "common_cells/registers.svh"

module neopixel_controller import neopixel_pkg::*; (
    /// Primary input clock. The control interface is supposed to be synchronous to
    /// this clock.
    input  logic clk_i,
    /// Asynchronous active-low reset
    input  logic rst_ni,

    /// FIFO control signals
    /// FIFO is empty
    input  logic fifo_empty_i,
    /// FIFO is flushed at the end of this cycle: the word at its head is gone
    input  logic fifo_flush_i,
    /// Data read from the FIFOs
    input  logic [NumBitsPerPixel-1:0] fifo_data_i,
    /// Pop the head of the FIFO, the next word is available in the following cycle
    output logic fifo_pop_o,

    /// Timing Constraints
    input neopixel_write_reg_union_t timing_constraints_i,

    /// Output to NeoPixel data line
    output logic data_o,

    output logic latch_state_o,

    /// True while a frame is being transmitted, latched, or sleeping.
    /// This also asserts in the cycle where the first FIFO word is accepted.
    output logic frame_active_o,

    /// Pulses when a word is needed but the FIFO is empty, so a pixel is sent as zeros
    output logic underrun_o
);

    /////////////////////////////////////////////////////////////
    // Counter and Timing for correct NeoPixel Timing Protocol //
    /////////////////////////////////////////////////////////////

    // Timing constants and number of NeoPixels to control. The register block bounds the number.
    logic [CounterWidth - 1:0] t1h, t1l, t0h, t0l, t_latch, sleep;
    logic [PixelCountWidth - 1:0] num_neopixel_cfg;

    // Extract timing values and number of NeoPixels from input struct
    assign num_neopixel_cfg = timing_constraints_i.str.num_neopixel;
    assign t1h          = CounterWidth'(timing_constraints_i.str.t1h);
    assign t1l          = CounterWidth'(timing_constraints_i.str.t1l);
    assign t0h          = CounterWidth'(timing_constraints_i.str.t0h);
    assign t0l          = CounterWidth'(timing_constraints_i.str.t0l);
    assign t_latch      = CounterWidth'(timing_constraints_i.str.t_latch);
    assign sleep        = CounterWidth'(timing_constraints_i.str.sleep);

    // Counter logic for precise timing
    // Counter value
    logic [CounterWidth - 1:0] counter_q;
    // Control signals for the counter
    logic counter_en, counter_clear, counter_overflow;

    // Counter instance for implementing timing delays
    delta_counter #(
        .WIDTH              ( CounterWidth  ),
        .STICKY_OVERFLOW    ( 1'b1          )
    ) i_counter (
        .clk_i      ( clk_i             ),
        .rst_ni     ( rst_ni            ),
        .clear_i    ( counter_clear     ), // Resets the counter to 0
        .en_i       ( counter_en        ), // If 1, counter_q is increased
        .load_i     ( 1'b0              ), // No loading new values
        .down_i     ( 1'b0              ), // Count up
        .delta_i    ( CounterWidth'(1)  ), // Increment by 1 each clock cycle
        .d_i        ( '0                ), // No external load data
        .q_o        ( counter_q         ), // Counter output
        .overflow_o ( counter_overflow  )
    );

    // The phase is over once `cycles` clock cycles have passed. A phase of zero cycles is skipped.
    function automatic logic timing_elapsed(
        logic [CounterWidth - 1:0] cycles,
        logic [CounterWidth - 1:0] count,
        logic                      overflow
    );
        return (cycles == '0) || overflow || (count >= cycles - 1'b1);
    endfunction

    //////////////////////////////////////////
    // FSM for sending Bits to the Neopixel //
    //////////////////////////////////////////

    // State encoding
    typedef enum logic [1:0] {
        // Waiting until the FIFO has data to be sent
        IDLE       = 2'b00,
        // Transmit high phase of a bit
        BIT_HIGH   = 2'b01,
        // Transmit low phase of a bit
        BIT_LOW    = 2'b10,
        // Send RET/Latch period of transmission
        // This happens when all the GRB data for all LEDs has been sent
        LATCH      = 2'b11
    } state_e;

    // FSM state registers
    state_e state_d, state_q;

    // A word stays at the FIFO head until its last bit is loaded, so the controller keeps no copy
    // of it. Bits are sent in GRB order, most significant bit first.
    localparam logic [$clog2(NumBitsPerPixel) - 1:0] FirstBitIndex = NumBitsPerPixel - 1;

    logic last_state_latch_d, last_state_latch_q;

    // Index of the bit being sent, counting down, and its value
    logic [$clog2(NumBitsPerPixel) - 1:0] bit_index_q, bit_index_d;
    logic                                 bit_q, bit_d;

    // The word being sent was taken from the FIFO. Otherwise the FIFO ran dry and zeros are sent.
    logic word_valid_q, word_valid_d;

    // The FIFO has a word at its head that is not flushed away in this cycle
    logic fifo_head_valid;
    // The word is still at the FIFO head. A flush removes it: the rest of the pixel is zeros, also
    // if the FIFO is refilled before the pixel ends.
    logic word_available;

    assign fifo_head_valid = !fifo_empty_i && !fifo_flush_i;
    assign word_available  = word_valid_q && fifo_head_valid;

    // Number of NeoPixels that still have to be sent, including the current one
    logic [PixelCountWidth - 1:0] pixels_remaining_q, pixels_remaining_d;

    logic frame_start;

    // A configured sleep period follows the latch before the next frame can start
    logic sleep_pending;

    assign sleep_pending = last_state_latch_q && (sleep != '0);
    assign frame_start   = (state_q == IDLE) && !sleep_pending &&
                           fifo_head_valid && (num_neopixel_cfg != '0);

    // Next state and output logic
    always_comb begin
        state_d = state_q;
        last_state_latch_d = last_state_latch_q;
        data_o = 1'b0;
        counter_clear = 1'b0;
        counter_en = 1'b0;
        bit_index_d = bit_index_q;
        bit_d = bit_q;
        word_valid_d = word_valid_q;
        pixels_remaining_d = pixels_remaining_q;
        fifo_pop_o = 1'b0;
        latch_state_o = '0;
        underrun_o = 1'b0;

        unique case (state_q)
            IDLE: begin
                if (sleep_pending) begin
                    counter_en = 1'b1;
                    if (timing_elapsed(sleep, counter_q, counter_overflow)) begin
                        last_state_latch_d = 1'b0;
                    end
                end else begin
                    last_state_latch_d = 1'b0;
                    if (frame_start) begin
                        // Start transmission if FIFO has data and NeoPixels are defined
                        state_d = BIT_HIGH;
                        counter_clear = 1'b1;
                        bit_index_d = FirstBitIndex;
                        bit_d = fifo_data_i[FirstBitIndex];
                        word_valid_d = 1'b1;
                        // Keep the chain length coherent for the complete frame.
                        pixels_remaining_d = num_neopixel_cfg;
                    end
                end
            end

            BIT_HIGH: begin
                counter_en = 1'b1; // Enable the counter
                data_o = 1'b1;

                // Transition logic based on bit timing
                if (timing_elapsed(bit_q ? t1h : t0h, counter_q, counter_overflow)) begin
                    state_d = BIT_LOW;
                    counter_clear = 1'b1;
                end
            end

            BIT_LOW: begin
                counter_en = 1'b1; // Enable the counter

                // Transition logic based on bit timing
                if (timing_elapsed(bit_q ? t1l : t0l, counter_q, counter_overflow)) begin
                    counter_clear = 1'b1; // Reset counter for next state

                    if (bit_index_q != '0) begin
                        // More bits remain, continue with the next bit
                        state_d = BIT_HIGH;
                        bit_index_d = bit_index_q - 1'b1;
                        bit_d = word_available && fifo_data_i[bit_index_q - 1'b1];
                        // The last bit of the word is loaded now, so the word is complete
                        fifo_pop_o = word_available && (bit_index_q == 1);
                    end else if (pixels_remaining_q > 1'b1) begin
                        // We have more NeoPixel left to send data to
                        state_d = BIT_HIGH;
                        bit_index_d = FirstBitIndex;
                        pixels_remaining_d = pixels_remaining_q - 1'b1;

                        // Croc integration must continuously service the DMA FIFO;
                        // zero-fill is defensive waveform behavior if that is violated.
                        underrun_o = !fifo_head_valid;
                        word_valid_d = fifo_head_valid;
                        bit_d = fifo_head_valid && fifo_data_i[FirstBitIndex];
                    end else begin
                        // All NeoPixel have data, go to latch state
                        state_d = LATCH;
                    end
                end
            end

            LATCH: begin
                latch_state_o = 1'b1;
                counter_en = 1'b1; // Enable the counter

                if (timing_elapsed(t_latch, counter_q, counter_overflow)) begin
                    // Wait for the next frame, optionally after the sleep interval
                    state_d = IDLE;
                    counter_clear = 1'b1;
                    last_state_latch_d = 1'b1;
                end
            end

            default: state_d = IDLE;
        endcase

        // The word at the head is flushed, so no further bit may be taken from it
        if (fifo_flush_i) begin
            word_valid_d = 1'b0;
        end
    end

    // A frame remains active until the controller has completed the latch and
    // any configured sleep interval.  Include frame_start so the first pixel is
    // covered in the IDLE cycle in which it is accepted.
    assign frame_active_o = (state_q != IDLE) || last_state_latch_q || frame_start;

    // Flip-flops for state variables
    `FF(state_q, state_d, IDLE, clk_i, rst_ni)
    `FF(bit_index_q, bit_index_d, '0, clk_i, rst_ni)
    `FF(bit_q, bit_d, '0, clk_i, rst_ni)
    `FF(word_valid_q, word_valid_d, '0, clk_i, rst_ni)
    `FF(pixels_remaining_q, pixels_remaining_d, '0, clk_i, rst_ni)
    `FF(last_state_latch_q, last_state_latch_d, '0, clk_i, rst_ni)

endmodule
