// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Luisa Wüthrich <lwuethri@ethz.ch>

`include "common_cells/registers.svh"

module neopixel_reg import neopixel_pkg::*; #(
    /// The OBI configuration for all ports.
    parameter obi_pkg::obi_cfg_t           ObiCfg      = obi_pkg::ObiDefaultConfig,
    /// OBI request type
    parameter type obi_req_t = logic,
    /// OBI response type
    parameter type obi_rsp_t = logic
) (
    input logic clk_i,
    input logic rst_ni,

    /// OBI subordinate request and response.
    input  obi_req_t  obi_req_i,
    output obi_rsp_t obi_rsp_o,

    /// Configuration outputs.
    output neopixel_write_reg_union_t timing_constraints_o,
    output dma_write_reg_union_t      dma_constraints_o,
    output logic                      dma_start_o,
    input  logic                      dma_status_i,
    input  logic                      fifo_empty_i,
    input  logic                      frame_active_i,

    /// FIFO producer configuration.
    output logic [1:0]                  fifo_access_o,
    output logic [FifoThresholdWidth-1:0] fifo_high_threshold_o,
    output logic [FifoThresholdWidth-1:0] fifo_low_threshold_o,

    /// Interrupt mask/status.
    output logic [5:0] irq_mask_o,
    output logic [5:0] irq_status_o,
    input  logic [5:0] irq_events_i
);

    ///////////////////////////////////////
    // OBI request/response bookkeeping. //
    ///////////////////////////////////////

    logic                           valid_d, valid_q;
    logic                           we_d, we_q;
    logic                           req_d, req_q;
    logic [AddressWidth-1:0]        write_addr;
    logic [AddressWidth-1:0]        read_addr_d, read_addr_q;
    logic [ObiCfg.IdWidth-1:0]      id_d, id_q;
    logic                           err_d, err_q;
    logic [ObiCfg.DataWidth-1:0]    obi_rdata;
    logic [ObiCfg.DataWidth-1:0]    obi_wdata;
    logic                           obi_read_request, obi_write_request;

    assign obi_wdata         = obi_req_i.a.wdata;
    assign obi_read_request  = req_q & ~we_q;
    assign obi_write_request = obi_req_i.req & obi_req_i.a.we;

    assign id_d        = obi_req_i.a.aid;
    assign valid_d     = obi_req_i.req;
    assign write_addr  = obi_req_i.a.addr[AddressWidth-1:2];
    assign read_addr_d = obi_req_i.a.addr[AddressWidth-1:2];
    assign we_d        = obi_req_i.a.we;
    assign req_d       = obi_req_i.req;

    always_comb begin
        obi_rsp_o             = '0;
        obi_rsp_o.r.rdata     = obi_rdata;
        obi_rsp_o.r.rid       = id_q;
        obi_rsp_o.r.err       = err_q;
        obi_rsp_o.gnt         = obi_req_i.req;
        obi_rsp_o.rvalid      = valid_q;
    end

    `FF(id_q,        id_d,        '0, clk_i, rst_ni)
    `FF(valid_q,     valid_d,     '0, clk_i, rst_ni)
    `FF(read_addr_q, read_addr_d, '0, clk_i, rst_ni)
    `FF(req_q,       req_d,       '0, clk_i, rst_ni)
    `FF(we_q,        we_d,        '0, clk_i, rst_ni)
    `FF(err_q,       err_d,       '0, clk_i, rst_ni)

    //////////////////////////
    // Register state/data. //
    //////////////////////////

    neopixel_write_reg_union_t reg_neopixel_d, reg_neopixel_q;
    dma_write_reg_union_t      reg_dma_d, reg_dma_q;
    logic [1:0]                reg_fifo_d, reg_fifo_q;
    logic [5:0]                reg_irq_mask_d, reg_irq_mask_q;
    logic [5:0]                reg_irq_status_d, reg_irq_status_q;
    logic [FifoThresholdWidth-1:0] reg_fifo_high_d, reg_fifo_high_q;
    logic [FifoThresholdWidth-1:0] reg_fifo_low_d, reg_fifo_low_q;
    logic [RegisterDepth-1:0]       dma_frame_bytes;
    logic [ObiCfg.DataWidth-1:0]    reg_fifo_high_q_obi, reg_fifo_low_q_obi;
    logic [ObiCfg.DataWidth-1:0]    fifo_high_write_data, fifo_low_write_data;

    localparam logic [ObiCfg.DataWidth-1:0] FifoDepthObi = FifoDepth;

    logic [1:0] fifo_access_next;
    logic       fifo_access_change_allowed;

    // Byte-enable expansion for register writes.
    logic [ObiCfg.DataWidth-1:0] bit_mask;
    for (genvar i = 0; unsigned'(i) < ObiCfg.DataWidth/8; ++i) begin : gen_write_mask
        assign bit_mask[8*i +: 8] = {8{obi_req_i.a.be[i]}};
    end

    assign fifo_access_next = (~bit_mask[1:0] & reg_fifo_q) |
                              (bit_mask[1:0] & obi_wdata[1:0]);
    assign fifo_access_change_allowed = !dma_status_i &&
                                        !frame_active_i &&
                                        fifo_empty_i;
    assign reg_fifo_high_q_obi = reg_fifo_high_q;
    assign reg_fifo_low_q_obi  = reg_fifo_low_q;
    assign fifo_high_write_data = (~bit_mask & reg_fifo_high_q_obi) |
                                  (bit_mask & obi_wdata);
    assign fifo_low_write_data  = (~bit_mask & reg_fifo_low_q_obi) |
                                  (bit_mask & obi_wdata);
    // DMA_VALID accepts exactly one configured frame of 32-bit words.
    assign dma_frame_bytes = reg_neopixel_q.str.num_neopixel << 2;

    always_comb begin
        reg_neopixel_d.arr = reg_neopixel_q.arr;
        reg_dma_d.arr      = reg_dma_q.arr;
        reg_fifo_d         = reg_fifo_q;
        reg_fifo_low_d     = reg_fifo_low_q;
        reg_fifo_high_d    = reg_fifo_high_q;
        reg_irq_mask_d     = reg_irq_mask_q;
        reg_irq_status_d   = reg_irq_status_q;
        err_d              = 1'b0;
        dma_start_o        = 1'b0;
        obi_rdata          = '0;

        ////////////////////////
        // Request phase write.
        ////////////////////////
        if (obi_write_request) begin
            case ({write_addr, 2'b00})
                NUM_NEOPIXEL_OFFSET: begin
                    if (!fifo_access_change_allowed) begin
                        err_d = 1'b1;
                    end else begin
                        reg_neopixel_d.str.num_neopixel =
                            (~bit_mask & reg_neopixel_q.str.num_neopixel) |
                            (bit_mask & obi_wdata);
                        // Bound storage after the byte-enable merge as well as controller use.
                        if (reg_neopixel_d.str.num_neopixel > MaxNumNeoPixel)
                            reg_neopixel_d.str.num_neopixel = MaxNumNeoPixel;
                    end
                end
                NEOPIXEL_T1H_OFFSET: begin
                    reg_neopixel_d.str.t1h =
                        (~bit_mask & reg_neopixel_q.str.t1h) | (bit_mask & obi_wdata);
                end
                NEOPIXEL_T1L_OFFSET: begin
                    reg_neopixel_d.str.t1l =
                        (~bit_mask & reg_neopixel_q.str.t1l) | (bit_mask & obi_wdata);
                end
                NEOPIXEL_T0H_OFFSET: begin
                    reg_neopixel_d.str.t0h =
                        (~bit_mask & reg_neopixel_q.str.t0h) | (bit_mask & obi_wdata);
                end
                NEOPIXEL_T0L_OFFSET: begin
                    reg_neopixel_d.str.t0l =
                        (~bit_mask & reg_neopixel_q.str.t0l) | (bit_mask & obi_wdata);
                end
                NEOPIXEL_T_LATCH_OFFSET: begin
                    reg_neopixel_d.str.t_latch =
                        (~bit_mask & reg_neopixel_q.str.t_latch) | (bit_mask & obi_wdata);
                end
                NEOPIXEL_SLEEP_OFFSET: begin
                    reg_neopixel_d.str.sleep =
                        (~bit_mask & reg_neopixel_q.str.sleep) | (bit_mask & obi_wdata);
                end
                DMA_SRC_ADDR_OFFSET: begin
                    reg_dma_d.str.src_addr =
                        (~bit_mask & reg_dma_q.str.src_addr) | (bit_mask & obi_wdata);
                end
                DMA_NUM_BYTES_OFFSET: begin
                    reg_dma_d.str.num_bytes =
                        (~bit_mask & reg_dma_q.str.num_bytes) | (bit_mask & obi_wdata);
                end
                DMA_VALID_OFFSET: begin
                    // This field is a write-one command strobe, so it never becomes state.
                    reg_dma_d.str.valid = '0;
                    if (bit_mask[0] && obi_wdata[0]) begin
                        if (dma_status_i ||
                            (reg_fifo_q != 2'b10) ||
                            (reg_neopixel_q.str.num_neopixel == '0) ||
                            (reg_dma_q.str.src_addr == '0) ||
                            (reg_dma_q.str.src_addr[1:0] != '0) ||
                            (reg_dma_q.str.num_bytes == '0) ||
                            (reg_dma_q.str.num_bytes[1:0] != '0) ||
                            (reg_dma_q.str.num_bytes != dma_frame_bytes)) begin
                            err_d = 1'b1;
                        end else begin
                            dma_start_o = 1'b1;
                        end
                    end
                end
                FIFO_ACCESS_OFFSET: begin
                    // Producer ownership is only changed while the queue and
                    // controller are quiescent.  Invalid values are rejected
                    // without changing the stored owner.
                    if (fifo_access_next > 2'b10) begin
                        err_d = 1'b1;
                    end else if ((fifo_access_next != reg_fifo_q) &&
                                 !fifo_access_change_allowed) begin
                        err_d = 1'b1;
                    end else begin
                        reg_fifo_d = fifo_access_next;
                    end
                end
                NEOPIXEL_IRQ_MASK_OFFSET: begin
                    reg_irq_mask_d = (~bit_mask[5:0] & reg_irq_mask_q) |
                                     (bit_mask[5:0] & obi_wdata[5:0]);
                end
                IRQ_STATUS_OFFSET: begin
                    // W1C; raw events below are applied after this clear.
                    reg_irq_status_d = reg_irq_status_q &
                                       ~(bit_mask[5:0] & obi_wdata[5:0]);
                end
                NEOPIXEL_FIFO_LOW_OFFSET: begin
                    if (fifo_low_write_data > FifoDepthObi)
                        reg_fifo_low_d = FifoThresholdWidth'(FifoDepth);
                    else
                        reg_fifo_low_d = fifo_low_write_data[FifoThresholdWidth-1:0];
                end
                NEOPIXEL_FIFO_HIGH_OFFSET: begin
                    if (fifo_high_write_data > FifoDepthObi)
                        reg_fifo_high_d = FifoThresholdWidth'(FifoDepth);
                    else
                        reg_fifo_high_d = fifo_high_write_data[FifoThresholdWidth-1:0];
                end
                default: begin
                    err_d = 1'b1;
                end
            endcase
        end

        ///////////////////////
        // Response phase read.
        ///////////////////////
        if (obi_read_request) begin
            case ({read_addr_q, 2'b00})
                MAX_NUM_NEOPIXEL_OFFSET:  obi_rdata = MaxNumNeoPixel;
                MIN_FREQ_OFFSET:          obi_rdata = 3_000_000;
                NUM_NEOPIXEL_OFFSET:      obi_rdata = reg_neopixel_q.str.num_neopixel;
                NEOPIXEL_T1H_OFFSET:      obi_rdata = reg_neopixel_q.str.t1h;
                NEOPIXEL_T1L_OFFSET:      obi_rdata = reg_neopixel_q.str.t1l;
                NEOPIXEL_T0H_OFFSET:      obi_rdata = reg_neopixel_q.str.t0h;
                NEOPIXEL_T0L_OFFSET:      obi_rdata = reg_neopixel_q.str.t0l;
                NEOPIXEL_T_LATCH_OFFSET:  obi_rdata = reg_neopixel_q.str.t_latch;
                NEOPIXEL_SLEEP_OFFSET:    obi_rdata = reg_neopixel_q.str.sleep;
                DMA_SRC_ADDR_OFFSET:      obi_rdata = reg_dma_q.str.src_addr;
                DMA_NUM_BYTES_OFFSET:     obi_rdata = reg_dma_q.str.num_bytes;
                DMA_VALID_OFFSET:         obi_rdata = '0;
                DMA_STATUS_OFFSET:        obi_rdata = {{(ObiCfg.DataWidth-1){1'b0}}, dma_status_i};
                FIFO_ACCESS_OFFSET:      obi_rdata = reg_fifo_q;
                NEOPIXEL_IRQ_MASK_OFFSET: obi_rdata = reg_irq_mask_q;
                IRQ_STATUS_OFFSET:        obi_rdata = reg_irq_status_q;
                NEOPIXEL_FIFO_LOW_OFFSET: obi_rdata = reg_fifo_low_q;
                NEOPIXEL_FIFO_HIGH_OFFSET:obi_rdata = reg_fifo_high_q;
                default: begin
                    obi_rdata = 32'hBADCAB1E;
                end
            endcase
        end

        // Decode read errors from the request that is being registered.  This keeps
        // a following write from changing the response error of an earlier read.
        if (obi_req_i.req && !obi_req_i.a.we) begin
            case (obi_req_i.a.addr[AddressWidth-1:0])
                MAX_NUM_NEOPIXEL_OFFSET,
                MIN_FREQ_OFFSET,
                NUM_NEOPIXEL_OFFSET,
                NEOPIXEL_T1H_OFFSET,
                NEOPIXEL_T1L_OFFSET,
                NEOPIXEL_T0H_OFFSET,
                NEOPIXEL_T0L_OFFSET,
                NEOPIXEL_T_LATCH_OFFSET,
                NEOPIXEL_SLEEP_OFFSET,
                DMA_SRC_ADDR_OFFSET,
                DMA_NUM_BYTES_OFFSET,
                DMA_VALID_OFFSET,
                DMA_STATUS_OFFSET,
                FIFO_ACCESS_OFFSET,
                NEOPIXEL_IRQ_MASK_OFFSET,
                IRQ_STATUS_OFFSET,
                NEOPIXEL_FIFO_LOW_OFFSET,
                NEOPIXEL_FIFO_HIGH_OFFSET: ;
                default: err_d = 1'b1;
            endcase
        end

        // Events win over a simultaneous W1C write.
        reg_irq_status_d = reg_irq_status_d | irq_events_i;

        timing_constraints_o  = reg_neopixel_q;
        dma_constraints_o     = reg_dma_q;
        fifo_access_o         = reg_fifo_q;
        fifo_high_threshold_o = reg_fifo_high_q;
        fifo_low_threshold_o  = reg_fifo_low_q;
        irq_mask_o            = reg_irq_mask_q;
        irq_status_o          = reg_irq_status_q;
    end

    `FF(reg_neopixel_q.arr, reg_neopixel_d.arr, '0, clk_i, rst_ni)
    `FF(reg_fifo_q,         reg_fifo_d,         '0, clk_i, rst_ni)
    `FF(reg_fifo_high_q,    reg_fifo_high_d,    FifoHighThresholdDefault, clk_i, rst_ni)
    `FF(reg_fifo_low_q,     reg_fifo_low_d,     FifoLowThresholdDefault,  clk_i, rst_ni)
    `FF(reg_irq_mask_q,     reg_irq_mask_d,     '0, clk_i, rst_ni)
    `FF(reg_irq_status_q,   reg_irq_status_d,   '0, clk_i, rst_ni)
    `FF(reg_dma_q.arr,       reg_dma_d.arr,      '0, clk_i, rst_ni)

endmodule
