// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Luisa Wüthrich <lwuethri@ethz.ch>

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

module write_to_fifo import neopixel_pkg::*; #(
    parameter obi_pkg::obi_cfg_t ObiCfg = obi_pkg::ObiDefaultConfig,
    /// OBI request struct type.
    parameter type obi_req_t            = logic,
    /// OBI response struct type.
    parameter type obi_rsp_t            = logic
) (
    /// Primary input clock
    input  logic clk_i,
    /// Asynchronous active-low reset
    input  logic rst_ni,

    /// FIFO control signals
    output logic fifo_empty_o,
    input  logic fifo_pop_i,
    /// Drop all entries (one-cycle pulse)
    input  logic fifo_flush_i,
    /// Number of entries, including a word the controller is still shifting out
    output logic [FifoThresholdWidth-1:0] fifo_usage_o,

    /// Data sent to the neopixel controller
    output logic [NumBitsPerPixel-1:0] fifo_data_o,

    /// Signals for DMA driven operation
    input  logic [RegisterDepth-1:0] dma_data_i,
    input  logic                     dma_valid_push_i,
    output logic                     dma_ready_o,

    /// Configuration signals
    /// Selects the producer, see FIFO_ACCESS_* in neopixel_pkg
    input  logic [1:0]                    fifo_access_i,
    input  logic [FifoThresholdWidth-1:0] fifo_high_threshold_i,
    input  logic [FifoThresholdWidth-1:0] fifo_low_threshold_i,

    /// Control interface request side using OBI.
    /// OBI request interface: a.addr, a.we, a.be, a.wdata, a.aid, a.a_optional | rready, req
    input  obi_req_t obi_req_i,
    /// Control interface response side using OBI.
    /// OBI response interface: r.rdata, r.rid, r.err, r.r_optional | gnt, rvalid
    output obi_rsp_t obi_rsp_o,

    /// Level conditions: the fill level is at or above the high threshold, or at or below the low one
    output logic fifo_high_o,
    output logic fifo_low_o
);

    // The default thresholds (2 and FifoDepth / 2) need at least four entries
    `ASSERT_INIT(FifoDepthMinimum_A, FifoDepth >= 4)

    ///////////////////
    // Producer Mode //
    ///////////////////

    // The access mode is registered locally so ownership changes have a complete
    // cycle in which all producer handshakes are disabled.
    logic [1:0] fifo_access_q;
    logic       owner_change_pending;

    assign owner_change_pending = (fifo_access_i != fifo_access_q);

    `FF(fifo_access_q, fifo_access_i, '0, clk_i, rst_ni)

    ////////////////
    // OBI Access //
    ////////////////

    // A write must own the FIFO and cover all three color bytes. Wrong-owner, invalid-mode, and
    // partial-byte writes are acknowledged with an error. Writes stall only during an ownership
    // update, in the cycle of a flush (a flush would drop the word) or when a valid write targets a
    // full FIFO.
    logic obi_write_request;
    logic obi_write_shape_valid;
    logic obi_write_stall;
    logic obi_write_accepted;
    logic obi_write_error;
    logic fifo_full;

    assign obi_write_request     = obi_req_i.req && obi_req_i.a.we;
    assign obi_write_shape_valid = (fifo_access_q == FIFO_ACCESS_OBI) &&
                                   (obi_req_i.a.be[2:0] == 3'b111);
    assign obi_write_stall       = obi_write_request &&
                                   (owner_change_pending || fifo_flush_i ||
                                    (obi_write_shape_valid && fifo_full));
    assign obi_write_accepted    = obi_write_request && !owner_change_pending && !fifo_flush_i &&
                                   obi_write_shape_valid && !fifo_full;
    assign obi_write_error       = obi_write_request && !obi_write_stall && !obi_write_accepted;

    // Keep one extra logical bit so a full FIFO reports its depth rather than 0.
    logic [FifoAddrDepth-1:0] fifo_usage_raw;
    logic [FifoAddrDepth:0]   fifo_usage;

    assign fifo_usage   = fifo_full ? (FifoAddrDepth + 1)'(FifoDepth) : {1'b0, fifo_usage_raw};
    assign fifo_usage_o = FifoThresholdWidth'(fifo_usage);

    // OBI response, registered: grants combinationally, responds in the following cycle
    logic                        valid_d, valid_q;
    logic                        err_d, err_q;
    logic [ObiCfg.IdWidth-1:0]   id_d, id_q;
    logic [ObiCfg.DataWidth-1:0] rdata_d, rdata_q;

    always_comb begin
        obi_rsp_o         = '0;
        obi_rsp_o.gnt     = obi_req_i.req && !obi_write_stall;
        obi_rsp_o.rvalid  = valid_q;
        obi_rsp_o.r.rid   = id_q;
        obi_rsp_o.r.err   = err_q;
        obi_rsp_o.r.rdata = rdata_q;
    end

    assign valid_d = obi_rsp_o.gnt;
    assign err_d   = obi_write_error && obi_rsp_o.gnt;
    assign id_d    = obi_req_i.a.aid;
    assign rdata_d = obi_req_i.a.we ? '0 : ObiCfg.DataWidth'(fifo_usage);

    `FF(valid_q, valid_d, '0, clk_i, rst_ni)
    `FF(err_q,   err_d,   '0, clk_i, rst_ni)
    `FF(id_q,    id_d,    '0, clk_i, rst_ni)
    `FF(rdata_q, rdata_d, '0, clk_i, rst_ni)

    //////////////////////////////////////////////
    // FIFO (Buffer for all NeoPixel Sequences) //
    //////////////////////////////////////////////

    logic        push;
    logic [NumBitsPerPixel-1:0] data;

    // DMA may handshake only while it is the selected producer, ownership is
    // stable, and the FIFO is not full.
    assign dma_ready_o = (fifo_access_q == FIFO_ACCESS_DMA) &&
                         !owner_change_pending &&
                         !fifo_full;

    always_comb begin
        push = 1'b0;
        data = '0;

        unique case (fifo_access_q)
            FIFO_ACCESS_OBI: begin
                push = obi_write_accepted;
                data = obi_req_i.a.wdata[NumBitsPerPixel-1:0];
            end
            FIFO_ACCESS_DMA: begin
                push = dma_valid_push_i && dma_ready_o;
                data = dma_data_i[NumBitsPerPixel-1:0];
            end
            // No producer selected or invalid mode: nothing is pushed
            default: ;
        endcase
    end

    fifo_v3 #(
        .DATA_WIDTH ( NumBitsPerPixel ),
        .DEPTH      ( FifoDepth )
    ) i_color_fifo (
        .clk_i,
        .rst_ni,
        .testmode_i ( 1'b0            ),

        // Software flushes through the CONTROL register, ownership changes never flush data.
        .flush_i    ( fifo_flush_i    ),

        .data_i     ( data            ),
        .push_i     ( push            ),

        .pop_i      ( fifo_pop_i      ),

        .full_o     ( fifo_full     ),
        .empty_o    ( fifo_empty_o    ),
        .usage_o    ( fifo_usage_raw  ),

        .data_o     ( fifo_data_o     )
    );

    //////////////////////
    // Level Conditions //
    //////////////////////

    // These hold whichever producer is selected. Only software-driven operation turns them
    // into interrupt events.
    assign fifo_high_o = (fifo_usage >= fifo_high_threshold_i);
    assign fifo_low_o  = (fifo_usage <= fifo_low_threshold_i);

endmodule
