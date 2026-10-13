// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Luisa Wüthrich <lwuethri@ethz.ch>

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

module neopixel import neopixel_pkg::*; #(
    /// OBI configuration of the subordinate (control) port.
    parameter obi_pkg::obi_cfg_t SbrObiCfg  = obi_pkg::ObiDefaultConfig,
    /// OBI request struct type of the subordinate port.
    parameter type sbr_obi_req_t            = logic,
    /// OBI response struct type of the subordinate port.
    parameter type sbr_obi_rsp_t            = logic,
    /// OBI configuration of the manager (DMA) port.
    parameter obi_pkg::obi_cfg_t MgrObiCfg  = obi_pkg::ObiDefaultConfig,
    /// OBI request struct type of the manager port.
    parameter type mgr_obi_req_t            = logic,
    /// OBI response struct type of the manager port.
    parameter type mgr_obi_rsp_t            = logic
) (
    /// Primary input clock. The control interface is supposed to be synchronous to
    /// this clock.
    input  logic clk_i,
    /// Asynchronous active-low reset
    input  logic rst_ni,
    /// Testmode
    input  logic testmode_i,

    /// This is the Subordinate, we want something from the neopixel
    /// Control interface request side using OBI.
    /// OBI request interface : a.addr, a.we, a.be, a.wdata, a.aid, a.a_optional | req
    input  sbr_obi_req_t obi_req_i,
    /// Control interface response side using OBI.
    /// OBI response interface : r.rdata, r.rid, r.err, r.r_optional | gnt, rvalid
    output sbr_obi_rsp_t obi_rsp_o,

    /// This is a Manager, it wants something from somewhere else
    /// DMA interface request side using OBI.
    /// OBI request interface : a.addr, a.we, a.be, a.wdata, a.aid, a.a_optional | req
    output mgr_obi_req_t mgr_obi_req_o,
    /// DMA interface response side using OBI.
    /// OBI response interface : r.rdata, r.rid, r.err, r.r_optional | gnt, rvalid
    input  mgr_obi_rsp_t mgr_obi_rsp_i,

    output logic interrupt_o,

    /// Output to NeoPixel data line
    output logic data_o
);

    /////////
    // DMA //
    /////////

    // Signal exchange between register and neopixel_dma module
    dma_write_reg_union_t dma_constraints;

    // DMA command: the DMA queues one command behind the transfer in progress
    logic dma_start;
    logic dma_req_ready;
    logic dma_busy;
    logic dma_abort;
    logic dma_transfer_done;

    // Signal exchange between FIFO and DMA
    logic [RegisterDepth-1:0] dma_fifo_data;
    logic                     dma_fifo_valid;
    logic                     dma_fifo_ready;

    neopixel_dma #(
        .DataWidth    ( MgrObiCfg.DataWidth ),
        .AddrWidth    ( MgrObiCfg.AddrWidth ),
        .TFLenWidth   ( FrameBytesWidth     ),
        .obi_req_t    ( mgr_obi_req_t       ),
        .obi_rsp_t    ( mgr_obi_rsp_t       )
    ) i_dma (
        .clk_i,
        .rst_ni,

        .src_addr_i       ( dma_constraints.str.src_addr  ),
        .num_bytes_i      ( FrameBytesWidth'(dma_constraints.str.num_bytes) ),
        .req_valid_i      ( dma_start         ),
        .req_ready_o      ( dma_req_ready     ),

        .busy_o           ( dma_busy          ),
        .abort_i          ( dma_abort         ),

        .transfer_done_o  ( dma_transfer_done ),

        .obi_req_o        ( mgr_obi_req_o     ),
        .obi_rsp_i        ( mgr_obi_rsp_i     ),

        .fifo_data_o      ( dma_fifo_data     ),
        .fifo_valid_o     ( dma_fifo_valid    ),
        .fifo_ready_i     ( dma_fifo_ready    )
    );

    ////////////////////////////////
    // Neopixel's Subordinate Bus //
    ////////////////////////////////

    sbr_obi_req_t [NumNeoPixelAddress-1:0] all_neopixel_obi_req;
    sbr_obi_rsp_t [NumNeoPixelAddress-1:0] all_neopixel_obi_rsp;

    // Error subordinate bus
    sbr_obi_req_t neopixel_error_obi_req;
    sbr_obi_rsp_t neopixel_error_obi_rsp;

    // Register subordinate bus
    sbr_obi_req_t neopixel_register_obi_req;
    sbr_obi_rsp_t neopixel_register_obi_rsp;

    // FIFO subordinate bus
    sbr_obi_req_t neopixel_fifo_obi_req;
    sbr_obi_rsp_t neopixel_fifo_obi_rsp;

    assign neopixel_error_obi_req                 = all_neopixel_obi_req[NeoPixelError];
    assign all_neopixel_obi_rsp[NeoPixelError]    = neopixel_error_obi_rsp;

    assign neopixel_register_obi_req              = all_neopixel_obi_req[NeoPixelRegister];
    assign all_neopixel_obi_rsp[NeoPixelRegister] = neopixel_register_obi_rsp;

    assign neopixel_fifo_obi_req                  = all_neopixel_obi_req[NeoPixelFifo];
    assign all_neopixel_obi_rsp[NeoPixelFifo]     = neopixel_fifo_obi_rsp;

    // The address is decoded in two steps. An access outside of the window of the IP is an error,
    // decided by comparing the upper address bits for equality. Inside the window the registers
    // are in the lower part and the FIFO in the rest, so a few bits tell them apart.
    `ASSERT_INIT(WindowIsPowerOfTwo_A,
                 (32'd1 << NeoPixelWindowWidth) == (NeoPixelRegisterAddrRange + NeoPixelFifoAddrRange))
    `ASSERT_INIT(WindowIsAligned_A, NeoPixelRegisterAddrOffset[NeoPixelWindowWidth-1:0] == '0)
    `ASSERT_INIT(RegistersFillPowerOfTwo_A,
                 (32'd1 << NeoPixelRegisterWidth) == NeoPixelRegisterAddrRange)

    logic [SbrObiCfg.AddrWidth-1:0] request_addr;
    logic window_hit;
    logic register_hit;
    logic [cf_math_pkg::idx_width(NumNeoPixelAddress)-1:0] neopixel_idx;

    assign request_addr = obi_req_i.a.addr;
    assign window_hit   = (request_addr[SbrObiCfg.AddrWidth-1:NeoPixelWindowWidth] ==
                           NeoPixelRegisterAddrOffset[SbrObiCfg.AddrWidth-1:NeoPixelWindowWidth]);
    assign register_hit = (request_addr[NeoPixelWindowWidth-1:NeoPixelRegisterWidth] == '0);

    always_comb begin
        neopixel_idx = NeoPixelError;
        if (window_hit) begin
            neopixel_idx = register_hit ? NeoPixelRegister : NeoPixelFifo;
        end
    end

    obi_demux #(
        .ObiCfg      ( SbrObiCfg          ),
        .obi_req_t   ( sbr_obi_req_t      ),
        .obi_rsp_t   ( sbr_obi_rsp_t      ),
        .NumMgrPorts ( NumNeoPixelAddress ),
        .NumMaxTrans ( 2                  )
    ) i_obi_demux (
        .clk_i,
        .rst_ni,

        .sbr_port_select_i ( neopixel_idx        ),
        .sbr_port_req_i    ( obi_req_i           ),
        .sbr_port_rsp_o    ( obi_rsp_o           ),

        .mgr_ports_req_o   ( all_neopixel_obi_req ),
        .mgr_ports_rsp_i   ( all_neopixel_obi_rsp )
    );

    obi_err_sbr #(
        .ObiCfg      ( SbrObiCfg      ),
        .obi_req_t   ( sbr_obi_req_t  ),
        .obi_rsp_t   ( sbr_obi_rsp_t  ),
        .NumMaxTrans ( 1              ),
        .RspData     ( ReadErrorData  )
    ) i_err_sbr (
        .clk_i,
        .rst_ni,
        .testmode_i,

        .obi_req_i   ( neopixel_error_obi_req ),
        .obi_rsp_o   ( neopixel_error_obi_rsp )
    );

    ///////////////
    // Registers //
    ///////////////

    // Signal exchange between register and neopixel_controller module
    neopixel_write_reg_union_t timing_constraints;

    // Signal exchange between register and write_to_fifo module
    logic [1:0]                    fifo_access;
    logic [FifoThresholdWidth-1:0] fifo_high_threshold, fifo_low_threshold;

    // Interrupt mask, status and raw events, see NEOPIXEL_IRQ_MASK_OFFSET
    logic [NumIrqEvents-1:0] irq_mask, irq_status;
    logic [NumIrqEvents-1:0] irq_events;

    // Status from the FIFO and the controller
    logic fifo_empty;
    logic fifo_low, fifo_high;
    logic fifo_flush;
    logic [FifoThresholdWidth-1:0] fifo_usage;
    logic frame_active;

    neopixel_reg #(
        .ObiCfg    ( SbrObiCfg      ),
        .obi_req_t ( sbr_obi_req_t  ),
        .obi_rsp_t ( sbr_obi_rsp_t  )
    ) i_neopixel_reg (
        .clk_i,
        .rst_ni,

        .obi_req_i             ( neopixel_register_obi_req ),
        .obi_rsp_o             ( neopixel_register_obi_rsp ),

        .timing_constraints_o  ( timing_constraints        ),
        .dma_constraints_o     ( dma_constraints           ),
        .dma_start_o           ( dma_start                 ),
        .dma_busy_i            ( dma_busy                  ),
        .dma_ready_i           ( dma_req_ready             ),
        .dma_abort_o           ( dma_abort                 ),
        .fifo_empty_i          ( fifo_empty                ),
        .fifo_usage_i          ( fifo_usage                ),
        .fifo_low_i            ( fifo_low                  ),
        .fifo_high_i           ( fifo_high                 ),
        .fifo_flush_o          ( fifo_flush                ),
        .frame_active_i        ( frame_active              ),

        .fifo_access_o         ( fifo_access               ),
        .fifo_high_threshold_o ( fifo_high_threshold       ),
        .fifo_low_threshold_o  ( fifo_low_threshold        ),

        .irq_mask_o            ( irq_mask                  ),
        .irq_status_o          ( irq_status                ),
        .irq_events_i          ( irq_events                )
    );

    //////////
    // FIFO //
    //////////

    // Signal exchange between FIFO and neopixel_controller module
    logic [NumBitsPerPixel-1:0] fifo_data;
    logic        fifo_pop;

    // The FIFO feeds the controller and can be written by either OBI or the DMA
    write_to_fifo #(
        .ObiCfg    ( SbrObiCfg      ),
        .obi_req_t ( sbr_obi_req_t  ),
        .obi_rsp_t ( sbr_obi_rsp_t  )
    ) i_write_to_fifo (
        .clk_i,
        .rst_ni,

        .fifo_empty_o          ( fifo_empty          ),
        .fifo_pop_i            ( fifo_pop            ),
        .fifo_flush_i          ( fifo_flush          ),
        .fifo_usage_o          ( fifo_usage          ),

        .fifo_data_o           ( fifo_data           ),

        .dma_data_i            ( dma_fifo_data       ),
        .dma_valid_push_i      ( dma_fifo_valid      ),
        .dma_ready_o           ( dma_fifo_ready      ),

        .fifo_access_i         ( fifo_access         ),
        .fifo_high_threshold_i ( fifo_high_threshold ),
        .fifo_low_threshold_i  ( fifo_low_threshold  ),

        .obi_req_i             ( neopixel_fifo_obi_req ),
        .obi_rsp_o             ( neopixel_fifo_obi_rsp ),

        .fifo_high_o           ( fifo_high           ),
        .fifo_low_o            ( fifo_low            )
    );

    ////////////////
    // Controller //
    ////////////////

    logic controller_latch;
    logic controller_underrun;

    neopixel_controller i_neopixel_controller (
        .clk_i,
        .rst_ni,

        .fifo_empty_i          ( fifo_empty          ),
        .fifo_flush_i          ( fifo_flush          ),
        .fifo_data_i           ( fifo_data           ),
        .fifo_pop_o            ( fifo_pop            ),

        .timing_constraints_i  ( timing_constraints  ),

        .data_o                ( data_o              ),
        .latch_state_o         ( controller_latch    ),
        .frame_active_o        ( frame_active        ),
        .underrun_o            ( controller_underrun )
    );

    ////////////////
    // Interrupts //
    ////////////////

    // Convert level conditions to one-cycle raw events for sticky status capture.
    logic fifo_low_interrupt, fifo_high_interrupt;
    logic fifo_low_interrupt_q, fifo_high_interrupt_q;
    logic controller_latch_q;
    logic frame_active_q;

    // Only software-driven operation uses the FIFO level interrupts
    assign fifo_low_interrupt  = (fifo_access == FIFO_ACCESS_OBI) && fifo_low;
    assign fifo_high_interrupt = (fifo_access == FIFO_ACCESS_OBI) && fifo_high;

    `FF(fifo_low_interrupt_q,  fifo_low_interrupt,  '0, clk_i, rst_ni)
    `FF(fifo_high_interrupt_q, fifo_high_interrupt, '0, clk_i, rst_ni)
    `FF(controller_latch_q,    controller_latch,    '0, clk_i, rst_ni)
    `FF(frame_active_q,        frame_active,        '0, clk_i, rst_ni)

    assign irq_events[0] = fifo_low_interrupt && !fifo_low_interrupt_q;
    assign irq_events[1] = fifo_high_interrupt && !fifo_high_interrupt_q;
    assign irq_events[2] = dma_transfer_done;
    assign irq_events[3] = controller_latch && !controller_latch_q;
    // Report latch leave only once the complete frame, latch, and configured
    // sleep interval have finished and the controller is fully idle.
    assign irq_events[4] = frame_active_q && !frame_active;
    assign irq_events[5] = dma_busy && mgr_obi_rsp_i.rvalid && mgr_obi_rsp_i.r.err;
    assign irq_events[6] = controller_underrun;

    assign interrupt_o = ((irq_mask & irq_status) != '0);

endmodule
