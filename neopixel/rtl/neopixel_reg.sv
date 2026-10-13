// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Luisa Wüthrich <lwuethri@ethz.ch>

`include "common_cells/assertions.svh"
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
    input  logic                      dma_busy_i,
    input  logic                      dma_ready_i,
    output logic                      dma_abort_o,
    input  logic                      fifo_empty_i,
    input  logic [FifoThresholdWidth-1:0] fifo_usage_i,
    input  logic                      fifo_low_i,
    input  logic                      fifo_high_i,
    output logic                      fifo_flush_o,
    input  logic                      frame_active_i,

    /// FIFO producer configuration.
    output logic [1:0]                  fifo_access_o,
    output logic [FifoThresholdWidth-1:0] fifo_high_threshold_o,
    output logic [FifoThresholdWidth-1:0] fifo_low_threshold_o,

    /// Interrupt mask/status.
    output logic [NumIrqEvents-1:0] irq_mask_o,
    output logic [NumIrqEvents-1:0] irq_status_o,
    input  logic [NumIrqEvents-1:0] irq_events_i
);

    ///////////////////////////////////
    // OBI Request/Response Handling //
    ///////////////////////////////////

    logic [AddressWidth-1:0]        request_addr;
    logic [AddressWidth-1:0]        read_addr_q;
    logic                           req_q;
    logic                           we_q;
    logic [ObiCfg.IdWidth-1:0]      id_q;
    logic                           err_d, err_q;
    logic                           write_err, read_err;
    logic [ObiCfg.DataWidth-1:0]    obi_rdata;
    logic [ObiCfg.DataWidth-1:0]    obi_wdata;
    logic                           obi_read_request, obi_write_request;

    assign obi_wdata         = obi_req_i.a.wdata;
    assign obi_read_request  = req_q & ~we_q;
    assign obi_write_request = obi_req_i.req & obi_req_i.a.we;
    assign request_addr      = obi_req_i.a.addr[AddressWidth-1:2];
    assign err_d             = write_err | read_err;

    always_comb begin
        obi_rsp_o         = '0;
        obi_rsp_o.r.rdata = obi_rdata;
        obi_rsp_o.r.rid   = id_q;
        obi_rsp_o.r.err   = err_q;
        obi_rsp_o.gnt     = obi_req_i.req;
        obi_rsp_o.rvalid  = req_q;
    end

    `FF(id_q,        obi_req_i.a.aid,   '0, clk_i, rst_ni)
    `FF(req_q,       obi_req_i.req,     '0, clk_i, rst_ni)
    `FF(we_q,        obi_req_i.a.we,    '0, clk_i, rst_ni)
    `FF(read_addr_q, request_addr,      '0, clk_i, rst_ni)
    `FF(err_q,       err_d,             '0, clk_i, rst_ni)

    ////////////////////
    // Register State //
    ////////////////////

    neopixel_write_reg_union_t     reg_neopixel_d, reg_neopixel_q;
    dma_write_reg_union_t          reg_dma_d, reg_dma_q;
    logic [1:0]                    reg_fifo_d, reg_fifo_q;
    // The abort and flush strobes act one cycle after the write, so that no path leads from the
    // request port to the DMA queue or the FIFO. DMA_VALID starts the DMA in the cycle of the
    // write and is checked against dma_ready_i.
    logic                          dma_abort_d, dma_abort_q;
    logic                          fifo_flush_d, fifo_flush_q;
    logic [NumIrqEvents-1:0]       reg_irq_mask_d, reg_irq_mask_q;
    logic [NumIrqEvents-1:0]       reg_irq_status_d, reg_irq_status_q;
    logic [FifoThresholdWidth-1:0] reg_fifo_high_d, reg_fifo_high_q;
    logic [FifoThresholdWidth-1:0] reg_fifo_low_d, reg_fifo_low_q;

    // Byte-enable expansion for register writes.
    logic [ObiCfg.DataWidth-1:0] bit_mask;
    for (genvar i = 0; unsigned'(i) < ObiCfg.DataWidth/8; ++i) begin : gen_write_mask
        assign bit_mask[8*i +: 8] = {8{obi_req_i.a.be[i]}};
    end

    // Stored value overwritten by the bytes the write enables
    function automatic logic [ObiCfg.DataWidth-1:0] merge_write(
        logic [ObiCfg.DataWidth-1:0] stored,
        logic [ObiCfg.DataWidth-1:0] mask,
        logic [ObiCfg.DataWidth-1:0] data
    );
        return (~mask & stored) | (mask & data);
    endfunction

    // A value above the largest one that fits a field is stored as the largest one
    function automatic logic [ObiCfg.DataWidth-1:0] saturate(
        logic [ObiCfg.DataWidth-1:0] value,
        int unsigned                 width
    );
        return ((value >> width) != '0) ? ((ObiCfg.DataWidth'(1) << width) - 1'b1) : value;
    endfunction

    // All values written to a register, merged with its stored value by byte enable
    logic [ObiCfg.DataWidth-1:0] num_neopixel_write, num_neopixel_value;
    logic [ObiCfg.DataWidth-1:0] fifo_high_write, fifo_low_write;
    logic [1:0]                  fifo_access_next;
    assign num_neopixel_write = merge_write(ObiCfg.DataWidth'(reg_neopixel_q.str.num_neopixel),
                                            bit_mask, obi_wdata);
    assign num_neopixel_value = (num_neopixel_write > MaxNumNeoPixel) ?
                                    ObiCfg.DataWidth'(MaxNumNeoPixel) : num_neopixel_write;
    assign fifo_high_write    = merge_write(ObiCfg.DataWidth'(reg_fifo_high_q), bit_mask, obi_wdata);
    assign fifo_low_write     = merge_write(ObiCfg.DataWidth'(reg_fifo_low_q),  bit_mask, obi_wdata);
    assign fifo_access_next   = merge_write(ObiCfg.DataWidth'(reg_fifo_q), bit_mask, obi_wdata);

    // The owner of the FIFO only changes while nothing is running and nothing is left to send
    logic fifo_access_change_allowed;
    assign fifo_access_change_allowed = !dma_busy_i && !frame_active_i && fifo_empty_i;

    // DMA_VALID accepts a chunk of up to one configured frame of 32-bit words. Several chunks
    // can make up a frame: the FIFO takes the words in order.
    logic [RegisterDepth-1:0] dma_frame_bytes;
    assign dma_frame_bytes = RegisterDepth'(reg_neopixel_q.str.num_neopixel) << 2;

    logic dma_command_valid;
    assign dma_command_valid = dma_ready_i &&
                               (reg_fifo_q == FIFO_ACCESS_DMA) &&
                               (reg_neopixel_q.str.num_neopixel != '0) &&
                               (reg_dma_q.str.src_addr != '0) &&
                               (reg_dma_q.str.src_addr[1:0] == '0) &&
                               (reg_dma_q.str.num_bytes != '0) &&
                               (reg_dma_q.str.num_bytes[1:0] == '0) &&
                               (reg_dma_q.str.num_bytes <= dma_frame_bytes);

    /////////////////////
    // Register Writes //
    /////////////////////

    always_comb begin
        reg_neopixel_d.arr = reg_neopixel_q.arr;
        reg_dma_d.arr      = reg_dma_q.arr;
        reg_fifo_d         = reg_fifo_q;
        reg_fifo_low_d     = reg_fifo_low_q;
        reg_fifo_high_d    = reg_fifo_high_q;
        reg_irq_mask_d     = reg_irq_mask_q;
        reg_irq_status_d   = reg_irq_status_q;
        write_err          = 1'b0;
        dma_start_o        = 1'b0;
        dma_abort_d        = 1'b0;
        fifo_flush_d       = 1'b0;

        if (obi_write_request) begin
            case ({request_addr, 2'b00})
                NUM_NEOPIXEL_OFFSET: begin
                    if (!fifo_access_change_allowed) begin
                        write_err = 1'b1;
                    end else begin
                        reg_neopixel_d.str.num_neopixel = num_neopixel_value[PixelCountWidth-1:0];
                    end
                end
                NEOPIXEL_T1H_OFFSET: begin
                    reg_neopixel_d.str.t1h = saturate(
                        merge_write(ObiCfg.DataWidth'(reg_neopixel_q.str.t1h), bit_mask, obi_wdata),
                        PulseWidth);
                end
                NEOPIXEL_T1L_OFFSET: begin
                    reg_neopixel_d.str.t1l = saturate(
                        merge_write(ObiCfg.DataWidth'(reg_neopixel_q.str.t1l), bit_mask, obi_wdata),
                        PulseWidth);
                end
                NEOPIXEL_T0H_OFFSET: begin
                    reg_neopixel_d.str.t0h = saturate(
                        merge_write(ObiCfg.DataWidth'(reg_neopixel_q.str.t0h), bit_mask, obi_wdata),
                        PulseWidth);
                end
                NEOPIXEL_T0L_OFFSET: begin
                    reg_neopixel_d.str.t0l = saturate(
                        merge_write(ObiCfg.DataWidth'(reg_neopixel_q.str.t0l), bit_mask, obi_wdata),
                        PulseWidth);
                end
                NEOPIXEL_T_LATCH_OFFSET: begin
                    reg_neopixel_d.str.t_latch = saturate(
                        merge_write(ObiCfg.DataWidth'(reg_neopixel_q.str.t_latch), bit_mask,
                                    obi_wdata),
                        LatchWidth);
                end
                NEOPIXEL_SLEEP_OFFSET: begin
                    reg_neopixel_d.str.sleep = saturate(
                        merge_write(ObiCfg.DataWidth'(reg_neopixel_q.str.sleep), bit_mask,
                                    obi_wdata),
                        SleepWidth);
                end
                DMA_SRC_ADDR_OFFSET: begin
                    reg_dma_d.str.src_addr = merge_write(reg_dma_q.str.src_addr, bit_mask, obi_wdata);
                end
                DMA_NUM_BYTES_OFFSET: begin
                    reg_dma_d.str.num_bytes = merge_write(reg_dma_q.str.num_bytes, bit_mask, obi_wdata);
                end
                DMA_VALID_OFFSET: begin
                    // This field is a write-one command strobe, so it never becomes state.
                    reg_dma_d.str.valid = '0;
                    if (bit_mask[0] && obi_wdata[0]) begin
                        write_err   = !dma_command_valid;
                        dma_start_o = dma_command_valid;
                    end
                end
                CONTROL_OFFSET: begin
                    // Write-one command strobes, never stored
                    dma_abort_d  = bit_mask[0] && obi_wdata[0];
                    fifo_flush_d = bit_mask[1] && obi_wdata[1];
                end
                FIFO_ACCESS_OFFSET: begin
                    // Invalid values are rejected without changing the stored owner. The values
                    // are numbered in ascending order, FIFO_ACCESS_DMA is the largest.
                    if ((fifo_access_next > FIFO_ACCESS_DMA) ||
                        ((fifo_access_next != reg_fifo_q) && !fifo_access_change_allowed)) begin
                        write_err = 1'b1;
                    end else begin
                        reg_fifo_d = fifo_access_next;
                    end
                end
                NEOPIXEL_IRQ_MASK_OFFSET: begin
                    reg_irq_mask_d = merge_write(ObiCfg.DataWidth'(reg_irq_mask_q), bit_mask,
                                                 obi_wdata);
                end
                IRQ_STATUS_OFFSET: begin
                    // W1C; raw events below are applied after this clear.
                    reg_irq_status_d = reg_irq_status_q & ~(bit_mask[NumIrqEvents-1:0] &
                                                            obi_wdata[NumIrqEvents-1:0]);
                end
                NEOPIXEL_FIFO_LOW_OFFSET: begin
                    reg_fifo_low_d = (fifo_low_write > FifoDepth) ? FifoThresholdWidth'(FifoDepth) :
                                         fifo_low_write[FifoThresholdWidth-1:0];
                end
                NEOPIXEL_FIFO_HIGH_OFFSET: begin
                    reg_fifo_high_d = (fifo_high_write > FifoDepth) ? FifoThresholdWidth'(FifoDepth) :
                                          fifo_high_write[FifoThresholdWidth-1:0];
                end
                default: begin
                    write_err = 1'b1;
                end
            endcase
        end

        // Events win over a simultaneous W1C write.
        reg_irq_status_d = reg_irq_status_d | irq_events_i;
    end

    ////////////////////
    // Register Reads //
    ////////////////////

    // The data is returned in the cycle after the request, from the registered address
    always_comb begin
        obi_rdata = '0;

        if (obi_read_request) begin
            case ({read_addr_q, 2'b00})
                MAX_NUM_NEOPIXEL_OFFSET:   obi_rdata = MaxNumNeoPixel;
                MIN_FREQ_OFFSET:           obi_rdata = MinFreqHz;
                NUM_NEOPIXEL_OFFSET:       obi_rdata = reg_neopixel_q.str.num_neopixel;
                NEOPIXEL_T1H_OFFSET:       obi_rdata = reg_neopixel_q.str.t1h;
                NEOPIXEL_T1L_OFFSET:       obi_rdata = reg_neopixel_q.str.t1l;
                NEOPIXEL_T0H_OFFSET:       obi_rdata = reg_neopixel_q.str.t0h;
                NEOPIXEL_T0L_OFFSET:       obi_rdata = reg_neopixel_q.str.t0l;
                NEOPIXEL_T_LATCH_OFFSET:   obi_rdata = reg_neopixel_q.str.t_latch;
                NEOPIXEL_SLEEP_OFFSET:     obi_rdata = reg_neopixel_q.str.sleep;
                DMA_SRC_ADDR_OFFSET:       obi_rdata = reg_dma_q.str.src_addr;
                DMA_NUM_BYTES_OFFSET:      obi_rdata = reg_dma_q.str.num_bytes;
                DMA_VALID_OFFSET:          obi_rdata = '0;
                DMA_STATUS_OFFSET:         obi_rdata = {!dma_ready_i, dma_busy_i};
                CONTROL_OFFSET:            obi_rdata = '0;
                FIFO_LEVEL_OFFSET:         obi_rdata = fifo_usage_i;
                STATUS_OFFSET:             obi_rdata = {fifo_high_i, fifo_low_i, frame_active_i};
                FIFO_ACCESS_OFFSET:        obi_rdata = reg_fifo_q;
                NEOPIXEL_IRQ_MASK_OFFSET:  obi_rdata = reg_irq_mask_q;
                IRQ_STATUS_OFFSET:         obi_rdata = reg_irq_status_q;
                NEOPIXEL_FIFO_LOW_OFFSET:  obi_rdata = reg_fifo_low_q;
                NEOPIXEL_FIFO_HIGH_OFFSET: obi_rdata = reg_fifo_high_q;
                default:                   obi_rdata = ReadErrorData;
            endcase
        end
    end

    // Decode read errors from the request that is being registered. This keeps a following write
    // from changing the response error of an earlier read.
    always_comb begin
        read_err = 1'b0;

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
                CONTROL_OFFSET,
                FIFO_LEVEL_OFFSET,
                STATUS_OFFSET,
                FIFO_ACCESS_OFFSET,
                NEOPIXEL_IRQ_MASK_OFFSET,
                IRQ_STATUS_OFFSET,
                NEOPIXEL_FIFO_LOW_OFFSET,
                NEOPIXEL_FIFO_HIGH_OFFSET: ;
                default: read_err = 1'b1;
            endcase
        end
    end

    /////////////
    // Outputs //
    /////////////

    assign timing_constraints_o  = reg_neopixel_q;
    assign dma_constraints_o     = reg_dma_q;
    assign dma_abort_o           = dma_abort_q;
    assign fifo_flush_o          = fifo_flush_q;
    assign fifo_access_o         = reg_fifo_q;
    assign fifo_high_threshold_o = reg_fifo_high_q;
    assign fifo_low_threshold_o  = reg_fifo_low_q;
    assign irq_mask_o            = reg_irq_mask_q;
    assign irq_status_o          = reg_irq_status_q;

    `FF(reg_neopixel_q.arr, reg_neopixel_d.arr, '0,                       clk_i, rst_ni)
    `FF(reg_dma_q.arr,      reg_dma_d.arr,      '0,                       clk_i, rst_ni)
    `FF(reg_fifo_q,         reg_fifo_d,         '0,                       clk_i, rst_ni)
    `FF(dma_abort_q,        dma_abort_d,        1'b0,                     clk_i, rst_ni)
    `FF(fifo_flush_q,       fifo_flush_d,       1'b0,                     clk_i, rst_ni)
    `FF(reg_fifo_high_q,    reg_fifo_high_d,    FifoHighThresholdDefault, clk_i, rst_ni)
    `FF(reg_fifo_low_q,     reg_fifo_low_d,     FifoLowThresholdDefault,  clk_i, rst_ni)
    `FF(reg_irq_mask_q,     reg_irq_mask_d,     '0,                       clk_i, rst_ni)
    `FF(reg_irq_status_q,   reg_irq_status_d,   '0,                       clk_i, rst_ni)

    ////////////////
    // Assertions //
    ////////////////

    `ASSERT_INIT(DataWidthIs32_A, ObiCfg.DataWidth == 32)
    `ASSERT(FifoAccessLegal_A, reg_fifo_q <= FIFO_ACCESS_DMA)
    `ASSERT(DmaStartNeedsReady_A, dma_start_o |-> dma_ready_i)

endmodule
