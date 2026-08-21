// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Luisa Wüthrich <lwuethri@ethz.ch>

`include "common_cells/registers.svh"

module write_to_fifo import neopixel_pkg::*; #(
    parameter obi_pkg::obi_cfg_t  ObiCfg    = obi_pkg::ObiDefaultConfig,
    /// Regbus request struct type.
    parameter type obi_req_t                = logic,
    /// Regbus response struct type.
    parameter type obi_rsp_t                = logic
)(
    /// Primary input clock
    input  logic clk_i,
    /// Asynchronous active-low reset
    input  logic rst_ni,

    /// FIFO control signals
    output logic fifo_empty_o,
    output logic fifo_full_o,
    input  logic fifo_pop_i,

    /// Data sent to the neopixel controller
    output logic [23:0] fifo_data_o,

    /// Signals for DMA driven operation
    input [RegisterDepth-1:0] dma_data_i,
    input dma_valid_push_i,
    output logic dma_ready_o,

    /// Configuration signals
    /// 0: off, 1: OBI is on 2: DMA is on
    input logic [1:0] fifo_access_i,
    input logic [FifoThresholdWidth-1:0] fifo_high_threshold_i,
    input logic [FifoThresholdWidth-1:0] fifo_low_threshold_i,

    /// Control interface request side using register_interface protocol.
    /// OBI request interface: a.addr, a.we, a.be, a.wdata, a.aid, a.a_optional | rready, req
    input  obi_req_t obi_req_i,
    /// Control interface request side using register_interface protocol.
    /// OBI response interface: r.rdata, r.rid, r.err, r.r_optional | gnt, rvalid
    output obi_rsp_t obi_rsp_o,

    /// An interrput signal if we don't use the dma and the fifo is almost full or empty
    output logic high_interrupt_o,
    output logic low_interrupt_o
);
    // Keep one extra logical bit so a full 16-entry FIFO reports 16 rather than 0.
    logic [FifoAddrDepth-1:0] fifo_usage_raw;
    logic [FifoAddrDepth:0] fifo_usage;
    localparam logic [FifoAddrDepth:0] FifoDepthValue = FifoDepth;
    
    // Obi signals
    logic                       valid_d, valid_q;
    logic                       we_d, we_q;
    logic                       err_d, err_q;
    logic [ObiCfg.DataWidth-1:0] rdata_d, rdata_q;
    logic [ObiCfg.IdWidth-1:0]  id_d, id_q;

    // Access mode is registered locally so ownership changes have a complete
    // cycle in which all producer handshakes are disabled.
    logic [1:0]     fifo_access_q, fifo_access_d;
    logic           owner_change_pending;
    logic           fifo_write_request;
    logic           fifo_write_stall;
    logic           fifo_write_valid;
    logic           fifo_write_error;

    assign owner_change_pending = fifo_access_i != fifo_access_q;
    assign fifo_write_request   = obi_req_i.req && obi_req_i.a.we;
    assign fifo_write_stall     = fifo_write_request &&
                                  (owner_change_pending ||
                                   ((fifo_access_q == 2'b01) &&
                                    (obi_req_i.a.be[2:0] == 3'b111) &&
                                    fifo_full_o));
    assign fifo_write_valid     = fifo_write_request &&
                                  !owner_change_pending &&
                                  (fifo_access_q == 2'b01) &&
                                  (obi_req_i.a.be[2:0] == 3'b111) &&
                                  !fifo_full_o;
    assign fifo_write_error     = fifo_write_request && !fifo_write_stall &&
                                  !fifo_write_valid;

    // Wrong-owner, invalid-mode, and partial-byte writes are acknowledged with
    // an error. Writes stall only during an ownership update or when a valid
    // OBI-owner write targets a genuinely full FIFO.
    always_comb begin
        obi_rsp_o             = '0;
        obi_rsp_o.gnt         = obi_req_i.req && !fifo_write_stall;
        obi_rsp_o.r.rid       = id_q;
        obi_rsp_o.r.err       = err_q;
        obi_rsp_o.r.rvalid    = valid_q;
        obi_rsp_o.r.rdata     = rdata_q;
        obi_rsp_o.r.r_optional = '0;
    end

    assign valid_d     = obi_req_i.req && obi_rsp_o.gnt;
    assign id_d        = obi_req_i.a.aid;
    assign rdata_d     = obi_req_i.a.we ? '0 : fifo_usage;
    assign we_d        = obi_req_i.a.we;
    assign err_d       = fifo_write_error && obi_rsp_o.gnt;

    // Register outputs for valid, ID, and read data
    `FF(valid_q, valid_d, '0, clk_i, rst_ni)
    `FF(id_q, id_d, '0, clk_i, rst_ni)
    `FF(rdata_q, rdata_d, '0, clk_i, rst_ni)
    `FF(we_q, we_d, '0, clk_i, rst_ni)
    `FF(err_q, err_d, '0, clk_i, rst_ni)

    //////////////////////////////////////////////
    // FIFO (Buffer for all NeoPixel Sequences) //
    //////////////////////////////////////////////

    // FIFO and Access Control logic
    logic           obi_push, dma_push;
    logic [23:0]    data;
    logic           push;

    assign fifo_access_d = fifo_access_i;
    assign fifo_usage = fifo_full_o ? FifoDepthValue : {1'b0, fifo_usage_raw};

    // DMA may handshake only while it is the selected producer, ownership is
    // stable, and the FIFO is not full.
    assign dma_ready_o = (fifo_access_q == 2'b10) &&
                         !owner_change_pending &&
                         !fifo_full_o;

    // Determine push conditions for OBI and DMA
    assign obi_push = fifo_write_valid;
    assign dma_push = dma_valid_push_i & dma_ready_o;

    always_comb begin
        push = 1'b0;
        data = '0;

        case (fifo_access_q)
            2'b00:begin
                // Valid access mode
            end
            2'b01: begin
                push = obi_push;
                data = obi_req_i.a.wdata[23:0];
            end
            2'b10: begin
                push = dma_push;
                data = dma_data_i[23:0];
            end
            default: begin
                // Invalid access mode
            end
        endcase
    end

    `FF(fifo_access_q, fifo_access_d, '0, clk_i, rst_ni)

    // Instantiate FIFO module for NeoPixel data storage
    fifo_v3 #(
        .DATA_WIDTH ( 24        ),
        .DEPTH      ( FifoDepth )
    ) color_fifo (
        .clk_i      ( clk_i         ),
        .rst_ni     ( rst_ni        ),
        .testmode_i ( 1'b0          ),

        // Ownership changes are guarded by neopixel_reg and never flush data.
        .flush_i    ( 1'b0         ),

        .data_i     ( data          ),
        .push_i     ( push          ),

        .pop_i      ( fifo_pop_i    ),

        .full_o     ( fifo_full_o   ),
        .empty_o    ( fifo_empty_o  ),
        .usage_o    ( fifo_usage_raw ),

        .data_o     ( fifo_data_o   )
    );

    //----------------------------------------------------------------------------------------------------
    // Interrupt for OBI if the FIFO has not enough elements or is almost full //
    //----------------------------------------------------------------------------------------------------

    logic fifo_high_interrupt;
    logic fifo_low_interrupt;

    always_comb begin
        fifo_high_interrupt = (fifo_usage >= fifo_high_threshold_i);
        fifo_low_interrupt  = (fifo_usage <= fifo_low_threshold_i);
    end

    assign high_interrupt_o = (fifo_access_q == 2'b01) ? fifo_high_interrupt : 1'b0;
    assign low_interrupt_o = (fifo_access_q == 2'b01) ? fifo_low_interrupt : 1'b0;

endmodule
