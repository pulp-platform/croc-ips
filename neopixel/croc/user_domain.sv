// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

`include "common_cells/assertions.svh"

module user_domain import user_pkg::*; import croc_pkg::*; #(
  parameter int unsigned GpioCount = 16,
  parameter int unsigned NumExternalIrqs = 4
) (
  input  logic      clk_i,
  input  logic      ref_clk_i,
  input  logic      rst_ni,
  input  logic      testmode_i,

  input  sbr_obi_req_t user_sbr_obi_req_i, // User Sbr (rsp_o), Croc Mgr (req_i)
  output sbr_obi_rsp_t user_sbr_obi_rsp_o,

  output mgr_obi_req_t user_mgr_obi_req_o, // User Mgr (req_o), Croc Sbr (rsp_i)
  input  mgr_obi_rsp_t user_mgr_obi_rsp_i,

  input  logic [      GpioCount-1:0] gpio_in_sync_i, // synchronized GPIO inputs
  output logic [NumExternalIrqs-1:0] interrupts_o,   // interrupts to core
  output logic                       neopixel_o
);

  logic neopixel_interrupt;
  always_comb begin
    interrupts_o    = '0;
    interrupts_o[0] = neopixel_interrupt;
  end


  ////////////////////////////
  // User Subordinate DEMUX //
  ////////////////////////////

  // ----------------------------------------------------------------------------------------------
  // User Subordinate Buses
  // ----------------------------------------------------------------------------------------------

  // collection of signals from the demultiplexer
  sbr_obi_req_t [NumDemuxSbr-1:0] all_user_sbr_obi_req;
  sbr_obi_rsp_t [NumDemuxSbr-1:0] all_user_sbr_obi_rsp;

  // Error Subordinate Bus
  sbr_obi_req_t user_error_obi_req;
  sbr_obi_rsp_t user_error_obi_rsp;

  // OBI bus to the NeoPixel controller.
  sbr_obi_req_t user_neopixel_obi_req;
  sbr_obi_rsp_t user_neopixel_obi_rsp;

  // Fanout into more readable signals
  assign user_error_obi_req               = all_user_sbr_obi_req[UserError];
  assign all_user_sbr_obi_rsp[UserError]  = user_error_obi_rsp;
  assign user_neopixel_obi_req              = all_user_sbr_obi_req[UserNeoPixel];
  assign all_user_sbr_obi_rsp[UserNeoPixel] = user_neopixel_obi_rsp;


  //-----------------------------------------------------------------------------------------------
  // Demultiplex to User Subordinates according to address map
  //-----------------------------------------------------------------------------------------------

  logic [cf_math_pkg::idx_width(NumDemuxSbr)-1:0] user_idx;

  // An access outside of the window of a subordinate is an error. Windows are powers of two, so the
  // decision is an equality compare of the upper address bits.
  `ASSERT_INIT(NeoPixelWindowIsPowerOfTwo_A,
               (32'd1 << UserNeoPixelAddrWidth) == UserNeoPixelAddrRange)
  `ASSERT_INIT(NeoPixelWindowIsAligned_A,
               UserNeoPixelAddrOffset[UserNeoPixelAddrWidth-1:0] == '0)

  logic neopixel_hit;

  assign neopixel_hit = (user_sbr_obi_req_i.a.addr[SbrObiCfg.AddrWidth-1:UserNeoPixelAddrWidth] ==
                         UserNeoPixelAddrOffset[SbrObiCfg.AddrWidth-1:UserNeoPixelAddrWidth]);
  assign user_idx     = neopixel_hit ? UserNeoPixel : UserError;

  obi_demux #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMgrPorts ( NumDemuxSbr   ),
    .NumMaxTrans ( 2             )
  ) i_obi_demux (
    .clk_i,
    .rst_ni,

    .sbr_port_select_i ( user_idx             ),
    .sbr_port_req_i    ( user_sbr_obi_req_i   ),
    .sbr_port_rsp_o    ( user_sbr_obi_rsp_o   ),

    .mgr_ports_req_o   ( all_user_sbr_obi_req ),
    .mgr_ports_rsp_i   ( all_user_sbr_obi_rsp )
  );


//-------------------------------------------------------------------------------------------------
// User Subordinates
//-------------------------------------------------------------------------------------------------

  neopixel #(
    .SbrObiCfg     ( SbrObiCfg     ),
    .sbr_obi_req_t ( sbr_obi_req_t ),
    .sbr_obi_rsp_t ( sbr_obi_rsp_t ),
    .MgrObiCfg     ( MgrObiCfg     ),
    .mgr_obi_req_t ( mgr_obi_req_t ),
    .mgr_obi_rsp_t ( mgr_obi_rsp_t )
  ) i_neopixel (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .obi_req_i      ( user_neopixel_obi_req ),
    .obi_rsp_o      ( user_neopixel_obi_rsp ),
    .mgr_obi_req_o  ( user_mgr_obi_req_o    ),
    .mgr_obi_rsp_i  ( user_mgr_obi_rsp_i    ),
    .interrupt_o    ( neopixel_interrupt    ),
    .data_o          ( neopixel_o            )
  );

  // Error Subordinate
  obi_err_sbr #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMaxTrans ( 1             ),
    .RspData     ( 32'hBADCAB1E  )
  ) i_user_err (
    .clk_i,
    .rst_ni,
    .testmode_i ( testmode_i         ),
    .obi_req_i  ( user_error_obi_req ),
    .obi_rsp_o  ( user_error_obi_rsp )
  );

endmodule
