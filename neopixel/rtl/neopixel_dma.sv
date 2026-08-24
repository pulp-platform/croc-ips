// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Luisa Wüthrich <lwuethri@ethz.ch>

module neopixel_dma #(
    /// Data width
    parameter int unsigned DataWidth        = 32'd32,
    /// Address width
    parameter int unsigned AddrWidth        = 32'd32,
    /// OBI user width
    parameter int unsigned UserWidth        = 32'd1,
    /// OBI ID width
    parameter int unsigned ObiIdWidth       = 32'd1,
    /// With of a transfer: max transfer size is `2**TFLenWidth` bytes
    parameter int unsigned TFLenWidth       = 32'd32,
    /// OBI config
    parameter obi_pkg::obi_cfg_t ObiCfg     = obi_pkg::ObiDefaultConfig,
    /// OBI A channel type
    parameter type obi_a_chan_t       = logic,
    /// OBI request struct type.
    parameter type obi_req_t          = logic,
    /// OBI response struct type.
    parameter type obi_rsp_t          = logic,
    /// *NOT OVERWRITE*: Address type
    parameter type addr_t             = logic [AddrWidth-1:0],
    /// *NOT OVERWRITE*: Data type
    parameter type data_t             = logic [DataWidth-1:0],
    /// *NOT OVERWRITE*: Length type
    parameter type tf_len_t           = logic [TFLenWidth-1:0]
)(
    input  logic     clk_i,
    input  logic     rst_ni,
    /// Request channel
    input  addr_t    src_addr_i,
    input  tf_len_t  num_bytes_i,
    input  logic     req_valid_i,
    output logic     req_ready_o,
    /// Response
    output logic     transfer_done_o,
    /// OBI read port
    output obi_req_t obi_req_o,
    input  obi_rsp_t obi_rsp_i,
    /// FIFO interface
    output data_t    fifo_data_o,
    output logic     fifo_valid_o,
    input  logic     fifo_ready_i,
    // Status
    output logic     busy_o
);

    localparam int unsigned BytesPerBeat = DataWidth / 8;

    logic    active_q;
    logic    wait_response_q;
    addr_t   read_addr_q;
    tf_len_t bytes_remaining_q;

    logic response_accepted;

    assign req_ready_o       = !active_q;
    assign busy_o            = active_q;
    assign fifo_data_o       = obi_rsp_i.r.rdata;
    assign fifo_valid_o      = active_q && obi_rsp_i.rvalid;
    assign response_accepted = fifo_valid_o && fifo_ready_i;

    always_comb begin
        obi_req_o        = '0;
        obi_req_o.rready = active_q && fifo_ready_i;

        if (active_q && !wait_response_q) begin
            obi_req_o.a.addr  = read_addr_q;
            obi_req_o.a.we    = 1'b0;
            obi_req_o.a.be    = '1;
            obi_req_o.a.wdata = '0;
            obi_req_o.a.aid   = '0;
            obi_req_o.req     = 1'b1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            active_q          <= 1'b0;
            wait_response_q   <= 1'b0;
            read_addr_q       <= '0;
            bytes_remaining_q <= '0;
            transfer_done_o   <= 1'b0;
        end else begin
            transfer_done_o <= 1'b0;

            if (!active_q) begin
                if (req_valid_i) begin
                    // DMA commands are validated by neopixel_reg and describe
                    // a non-zero, word-aligned raw frame.
                    active_q          <= 1'b1;
                    wait_response_q   <= 1'b0;
                    read_addr_q       <= src_addr_i;
                    bytes_remaining_q <= num_bytes_i;
                end
            end else if (!wait_response_q && obi_rsp_i.gnt) begin
                // Croc's SRAM normally responds in a later cycle. Handle a
                // combined grant/response as well to keep the OBI handshake
                // complete for other compatible subordinates.
                if (response_accepted) begin
                    if (bytes_remaining_q == BytesPerBeat) begin
                        active_q        <= 1'b0;
                        transfer_done_o <= 1'b1;
                    end else begin
                        read_addr_q       <= read_addr_q + BytesPerBeat;
                        bytes_remaining_q <= bytes_remaining_q - BytesPerBeat;
                    end
                end else begin
                    wait_response_q <= 1'b1;
                end
            end else if (wait_response_q && response_accepted) begin
                if (bytes_remaining_q == BytesPerBeat) begin
                    active_q        <= 1'b0;
                    transfer_done_o <= 1'b1;
                end else begin
                    read_addr_q       <= read_addr_q + BytesPerBeat;
                    bytes_remaining_q <= bytes_remaining_q - BytesPerBeat;
                    wait_response_q   <= 1'b0;
                end
            end
        end
    end

endmodule
