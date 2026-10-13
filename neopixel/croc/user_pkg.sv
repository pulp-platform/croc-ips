// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>

`include "obi/typedef.svh"

package user_pkg;

  // The base address of the user domain can be retrieved from `croc_pkg::UserBaseAddr`.
  // Keep subordinates on 4 KiB boundaries.
  typedef enum bit [3:0]  {
    UserError    = 0,
    UserNeoPixel = 1
  } user_demux_outputs_e;

  localparam bit [31:0] UserNeoPixelAddrOffset = croc_pkg::UserBaseAddr + 32'h0000_1000;
  localparam bit [31:0] UserNeoPixelAddrRange  = 32'h0000_1000;

  // Subordinates are decoded by equality on the address bits above their window, which must
  // therefore be a power of two in size and aligned to its size.
  localparam int unsigned UserNeoPixelAddrWidth = $clog2(UserNeoPixelAddrRange);

  // One additional subordinate receives accesses outside of all windows.
  localparam int unsigned NumDemuxSbr = 2;

endpackage
