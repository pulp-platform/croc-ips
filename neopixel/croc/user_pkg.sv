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

  /// Address rules given to the user-domain demultiplexer.
  localparam croc_pkg::addr_map_rule_t [0:0] UserAddrMap = '{
    '{
      idx:        UserNeoPixel,
      start_addr: UserNeoPixelAddrOffset,
      end_addr:   UserNeoPixelAddrOffset + UserNeoPixelAddrRange
    }
  };

  // One additional subordinate receives accesses outside UserAddrMap.
  localparam int unsigned NumDemuxSbr = $size(UserAddrMap) + 1;

endpackage
