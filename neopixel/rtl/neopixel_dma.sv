// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Luisa Wüthrich <lwuethri@ethz.ch>

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

/// Reads one frame of words from memory over OBI and streams them to the FIFO.
///
/// One command (`req_valid_i` while `req_ready_o`) transfers `num_bytes_i` bytes starting at
/// `src_addr_i`. The command must be non-zero and a multiple of the word size; this is checked by
/// `neopixel_reg` before the command is issued. A one-entry command queue accepts the next command
/// while a transfer is running, so `req_ready_o` is only low while a command waits for the
/// transfer in progress. Reads are issued one at a time: a new read is requested only after the
/// previous response has been accepted by the FIFO. A read is only requested while the FIFO has
/// room, so a response is never refused. `transfer_done_o` pulses for one cycle after
/// the last word of each command has been accepted. `busy_o` is high while a command is queued or
/// running. `abort_i` discards the queued and the running command: a read that is already issued is
/// completed on the bus and its data is dropped, so no word reaches the FIFO after the abort and
/// `transfer_done_o` does not pulse. A response with an error ends the transfer in the same way:
/// its data is dropped and `transfer_done_o` does not pulse.
module neopixel_dma #(
    /// Data width
    parameter int unsigned DataWidth  = 32'd32,
    /// Address width
    parameter int unsigned AddrWidth  = 32'd32,
    /// Width of a transfer length in bytes: the maximum transfer is `2**TFLenWidth - 1` bytes
    parameter int unsigned TFLenWidth = 32'd32,
    /// OBI request struct type.
    parameter type obi_req_t          = logic,
    /// OBI response struct type.
    parameter type obi_rsp_t          = logic,
    /// *DO NOT OVERWRITE*: Address type
    parameter type addr_t             = logic [AddrWidth-1:0],
    /// *DO NOT OVERWRITE*: Data type
    parameter type data_t             = logic [DataWidth-1:0],
    /// *DO NOT OVERWRITE*: Length type
    parameter type tf_len_t           = logic [TFLenWidth-1:0]
) (
    input  logic     clk_i,
    input  logic     rst_ni,

    /// Command channel
    input  addr_t    src_addr_i,
    input  tf_len_t  num_bytes_i,
    input  logic     req_valid_i,
    output logic     req_ready_o,

    /// A command is queued or running
    output logic     busy_o,

    /// Discard the queued and the running command (one-cycle pulse)
    input  logic     abort_i,

    /// Single-cycle pulse after the last word of a command has been accepted
    output logic     transfer_done_o,

    /// OBI read port
    output obi_req_t obi_req_o,
    input  obi_rsp_t obi_rsp_i,

    /// FIFO interface
    output data_t    fifo_data_o,
    output logic     fifo_valid_o,
    input  logic     fifo_ready_i
);

    localparam int unsigned BytesPerBeat = DataWidth / 8;
    // Commands are whole beats at beat-aligned addresses, so the low bits are never stored
    localparam int unsigned BeatShift    = $clog2(BytesPerBeat);

    typedef logic [AddrWidth-1:BeatShift]  beat_addr_t;
    typedef logic [TFLenWidth-1:BeatShift] beat_count_t;

    `ASSERT_INIT(DataWidthIsBytes_A, (DataWidth > 0) && (DataWidth % 8 == 0))
    `ASSERT_INIT(DataWidthIsPowerOfTwo_A, BytesPerBeat == (32'd1 << BeatShift))

    ///////////////////
    // Shared Status //
    ///////////////////

    // Issues one read per word: StRequest presents the address until it is granted, StResponse
    // waits for the data. A response that arrives together with the grant (combined grant and
    // response of some subordinates) skips StResponse. Croc's SRAM responds in a later cycle.
    typedef enum logic [1:0] {
        StIdle,
        StRequest,
        StResponse
    } state_e;

    state_e state_d, state_q;

    logic transfer_active;
    logic dma_request;
    logic grant_accepted;
    logic response_accepted;
    logic beat_completed;
    logic discard_q, discard_d;
    logic discard;
    logic response_dropped;

    assign transfer_active = (state_q != StIdle);
    // A read is only requested while the FIFO has room. Only this DMA pushes into the FIFO, so the
    // room stays until the response arrives: it is always accepted and OBI needs no rready.
    assign dma_request     = (state_q == StRequest) && fifo_ready_i;
    assign grant_accepted  = dma_request && obi_rsp_i.gnt;

    //////////////////////////////
    // OBI Read and FIFO Stream //
    //////////////////////////////

    // The response data is forwarded directly. It is only a FIFO beat while a read is outstanding.
    beat_addr_t read_addr_q, read_addr_d;

    assign fifo_data_o       = obi_rsp_i.r.rdata;
    assign fifo_valid_o      = transfer_active && obi_rsp_i.rvalid && !discard && !obi_rsp_i.r.err;
    assign response_accepted = fifo_valid_o && fifo_ready_i;

    // A word is complete once the FIFO has taken its response
    assign beat_completed = (grant_accepted || (state_q == StResponse)) && response_accepted;

    // After an abort a read that is already presented still runs to its response, which is dropped.
    // A read that is not presented yet, because the FIFO has no room, is never issued. A response
    // with an error is dropped as well: its data is not a pixel, and the transfer ends.
    logic request_cancelled;

    assign discard           = discard_q || abort_i;
    assign request_cancelled = discard && (state_q == StRequest) && !fifo_ready_i;
    assign response_dropped  = (discard || obi_rsp_i.r.err) && obi_rsp_i.rvalid &&
                               (grant_accepted || (state_q == StResponse));
    assign discard_d         = discard && transfer_active &&
                               !response_dropped && !request_cancelled;

    always_comb begin
        obi_req_o = '0;

        if (dma_request) begin
            obi_req_o.a.addr = addr_t'({read_addr_q, BeatShift'(0)});
            obi_req_o.a.we   = 1'b0;
            obi_req_o.a.be   = '1;
            obi_req_o.req    = 1'b1;
        end
    end

    `ASSERT(ResponseAccepted_A, fifo_valid_o |-> fifo_ready_i, clk_i, !rst_ni)
    `ASSERT(RequestHeldUntilGranted_A, dma_request && !obi_rsp_i.gnt |=> dma_request,
            clk_i, !rst_ni)

    ///////////////////
    // Command Queue //
    ///////////////////

    // A command waits here until the transfer in progress has finished. It leaves as soon as the
    // transfer engine is idle, so the queue is free again one cycle after a transfer starts.
    beat_addr_t  queued_addr_q;
    beat_count_t queued_beats_q;
    logic        queued_valid_q, queued_valid_d;
    logic        command_accepted;
    logic        command_started;

    assign req_ready_o      = !queued_valid_q;
    assign command_accepted = req_valid_i && req_ready_o;
    assign command_started  = queued_valid_q && !transfer_active && !abort_i;
    // An abort discards the commands issued before it, a command accepted in the same cycle was
    // issued after the abort and is kept.
    assign queued_valid_d   = command_accepted ||
                              (queued_valid_q && !command_started && !abort_i);
    assign busy_o           = queued_valid_q || transfer_active;

    `FFL(queued_addr_q,  src_addr_i[AddrWidth-1:BeatShift],  command_accepted, '0, clk_i, rst_ni)
    `FFL(queued_beats_q, num_bytes_i[TFLenWidth-1:BeatShift], command_accepted, '0, clk_i, rst_ni)
    `FF(queued_valid_q,  queued_valid_d,                      1'b0,                clk_i, rst_ni)

    `ASSERT(CommandAligned_A, command_accepted |->
            (num_bytes_i != '0) && (num_bytes_i % BytesPerBeat == '0) &&
            (src_addr_i % BytesPerBeat == '0), clk_i, !rst_ni)

    //////////////////////
    // Transfer Control //
    //////////////////////

    beat_count_t beats_remaining_q, beats_remaining_d;
    logic        last_beat;

    assign last_beat = (beats_remaining_q == beat_count_t'(1));

    /////////
    // FSM //
    /////////

    logic transfer_done_d, transfer_done_q;

    assign transfer_done_o = transfer_done_q;

    always_comb begin
        state_d           = state_q;
        read_addr_d       = read_addr_q;
        beats_remaining_d = beats_remaining_q;
        transfer_done_d   = 1'b0;

        unique case (state_q)
            // Wait for a queued command
            StIdle: begin
                if (command_started) begin
                    read_addr_d       = queued_addr_q;
                    beats_remaining_d = queued_beats_q;
                    state_d           = StRequest;
                end
            end
            // Present the read address until it is granted
            StRequest: begin
                if (grant_accepted) begin
                    state_d = StResponse;
                end
            end
            // Wait until the FIFO has accepted the response
            StResponse: ;
            default: state_d = StIdle;
        endcase

        // A dropped response or a cancelled request ends the transfer
        if (response_dropped || request_cancelled) begin
            state_d = StIdle;
        end

        // Completing a word overrides the transition above: continue with the next word or finish
        if (beat_completed) begin
            if (last_beat) begin
                state_d         = StIdle;
                transfer_done_d = 1'b1;
            end else begin
                state_d           = StRequest;
                read_addr_d       = read_addr_q + beat_addr_t'(1);
                beats_remaining_d = beats_remaining_q - beat_count_t'(1);
            end
        end
    end

    `FF(state_q,           state_d,           StIdle, clk_i, rst_ni)
    `FF(read_addr_q,       read_addr_d,       '0,     clk_i, rst_ni)
    `FF(beats_remaining_q, beats_remaining_d, '0,     clk_i, rst_ni)
    `FF(transfer_done_q,   transfer_done_d,   1'b0,   clk_i, rst_ni)
    `FF(discard_q,         discard_d,         1'b0,   clk_i, rst_ni)

    `ASSERT_KNOWN(ReqReadyKnown_A,     req_ready_o,     clk_i, !rst_ni)
    `ASSERT_KNOWN(BusyKnown_A,         busy_o,          clk_i, !rst_ni)
    `ASSERT_KNOWN(TransferDoneKnown_A, transfer_done_o, clk_i, !rst_ni)
    `ASSERT_KNOWN(FifoValidKnown_A,    fifo_valid_o,    clk_i, !rst_ni)

endmodule
