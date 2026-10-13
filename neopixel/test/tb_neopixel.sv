// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/// Directed testbench of the NeoPixel IP on Croc's OBI types.
///
/// The first frame is sent as two chunks and the second one as a single command, all started
/// through the register interface. The second chunk is queued in the DMA while the first one runs.
/// Afterwards a short frame provokes an underrun, and an abort with a FIFO flush in the middle of a
/// transfer is followed by a complete frame. The memory behind the DMA grants and responds after
/// random delays. The bit timing is slow compared to the DMA, so the FIFO fills up and the DMA
/// has to wait for room. The testbench decodes `data_o` from its pulse widths and compares every
/// word with the memory. Build it with assertions enabled.
module tb_neopixel import croc_pkg::*; import neopixel_pkg::*; ();

    localparam int unsigned NumPixels   = 20;
    localparam int unsigned T1H         = 6;
    localparam int unsigned T1L         = 3;
    localparam int unsigned T0H         = 3;
    localparam int unsigned T0L         = 6;
    localparam int unsigned TLatch      = 20;
    localparam int unsigned MemWords    = 1024;
    localparam int unsigned FrameWordsA = 64;   // word index of the first frame
    localparam int unsigned FrameWordsB = 256;  // word index of the second frame
    localparam int unsigned ChunkAPixels = 12;  // the first frame is two chunks

    logic clk_i = 1'b0;
    logic rst_ni;

    always #5ns clk_i = ~clk_i;

    sbr_obi_req_t sbr_req;
    sbr_obi_rsp_t sbr_rsp;
    mgr_obi_req_t mgr_req;
    mgr_obi_rsp_t mgr_rsp;
    logic         interrupt;
    logic         data;

    neopixel #(
        .SbrObiCfg     ( SbrObiCfg     ),
        .sbr_obi_req_t ( sbr_obi_req_t ),
        .sbr_obi_rsp_t ( sbr_obi_rsp_t ),
        .MgrObiCfg     ( MgrObiCfg     ),
        .mgr_obi_req_t ( mgr_obi_req_t ),
        .mgr_obi_rsp_t ( mgr_obi_rsp_t )
    ) i_dut (
        .clk_i,
        .rst_ni,
        .testmode_i     ( 1'b0      ),
        .obi_req_i      ( sbr_req   ),
        .obi_rsp_o      ( sbr_rsp   ),
        .mgr_obi_req_o  ( mgr_req   ),
        .mgr_obi_rsp_i  ( mgr_rsp   ),
        .interrupt_o    ( interrupt ),
        .data_o         ( data      )
    );

    /////////////////////////
    // Memory behind a DMA //
    /////////////////////////

    logic [31:0] mem [MemWords];

    // Grant and response with random delays. The grant does not depend on the request.
    logic        gnt_q;
    logic        resp_pending_q;
    int unsigned resp_delay_q;
    logic [31:0] resp_data_q;
    logic        resp_err_q;
    // Word index of the memory for which the response is an error, -1 for none
    int          error_word = -1;

    assign mgr_rsp.gnt        = gnt_q;
    assign mgr_rsp.rvalid     = resp_pending_q && (resp_delay_q == 0);
    assign mgr_rsp.r.rdata    = resp_data_q;
    assign mgr_rsp.r.rid      = '0;
    assign mgr_rsp.r.err      = resp_err_q;
    assign mgr_rsp.r.r_optional = 1'b0;

    int unsigned num_reads = 0;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            gnt_q          <= 1'b0;
            resp_pending_q <= 1'b0;
            resp_delay_q   <= 0;
            resp_data_q    <= '0;
            resp_err_q     <= 1'b0;
        end else begin
            gnt_q <= ($urandom_range(3) != 0);
            if (mgr_rsp.rvalid) begin
                resp_pending_q <= 1'b0;
            end else if (resp_pending_q) begin
                resp_delay_q <= resp_delay_q - 1;
            end
            if (mgr_req.req && mgr_rsp.gnt) begin
                if (resp_pending_q && !mgr_rsp.rvalid) $fatal(1, "read issued while one is outstanding");
                if (mgr_req.a.we) $fatal(1, "DMA must not write");
                resp_pending_q <= 1'b1;
                resp_delay_q   <= $urandom_range(3);
                resp_data_q    <= mem[(mgr_req.a.addr >> 2) % MemWords];
                resp_err_q     <= (int'(mgr_req.a.addr >> 2) == error_word);
                num_reads      <= num_reads + 1;
            end
        end
    end

    // The request must stay put until it is granted
    logic        req_held_q;
    logic [31:0] req_addr_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            req_held_q <= 1'b0;
        end else begin
            if (req_held_q && !(mgr_req.req && mgr_req.a.addr == req_addr_q))
                $fatal(1, "request dropped or changed before the grant");
            req_held_q <= mgr_req.req && !mgr_rsp.gnt;
            req_addr_q <= mgr_req.a.addr;
        end
    end

    ////////////////////////////
    // Decode the data output //
    ////////////////////////////

    logic        bits_q [$];
    int unsigned high_width;
    int unsigned low_width;
    logic        data_prev;
    logic        last_bit;
    int unsigned latch_width;
    int unsigned num_latches = 0;

    always_ff @(posedge clk_i) begin
        data_prev <= data;
        if (data) begin
            high_width <= high_width + 1;
            if (!data_prev) begin
                // Rising edge: check the low time of the bit before
                if (bits_q.size() > 0 && low_width < TLatch) begin
                    if (low_width != (last_bit ? T1L : T0L))
                        $fatal(1, "bit %0d: low time %0d for a %0d", bits_q.size() - 1, low_width,
                               last_bit);
                end
                if (low_width >= TLatch) num_latches <= num_latches + 1;
                low_width  <= 0;
                high_width <= 1;
            end
        end else begin
            low_width <= low_width + 1;
            if (data_prev) begin
                // Falling edge: the high time tells the bit
                if (high_width == T1H) begin
                    bits_q.push_back(1'b1);
                    last_bit <= 1'b1;
                end else if (high_width == T0H) begin
                    bits_q.push_back(1'b0);
                    last_bit <= 1'b0;
                end else begin
                    $fatal(1, "bit %0d: high time %0d", bits_q.size(), high_width);
                end
                low_width <= 1;
            end
        end
    end

    ////////////////
    // OBI Access //
    ////////////////

    // Drive a request at the falling edge. The grant is sampled before the rising edge, where the
    // flip-flops change, so that it cannot race with the clock.
    // The response that was on the bus when the request was driven belongs to the previous one
    logic prev_rvalid, prev_err;

    task automatic obi_drive(input logic [31:0] addr, input logic we, input logic [31:0] wdata);
        @(negedge clk_i);
        prev_rvalid = sbr_rsp.rvalid;
        prev_err    = sbr_rsp.r.err;
        sbr_req.req          = 1'b1;
        sbr_req.a.addr       = addr;
        sbr_req.a.we         = we;
        sbr_req.a.be         = '1;
        sbr_req.a.wdata      = wdata;
        sbr_req.a.aid        = '0;
        sbr_req.a.a_optional = '0;
        #1ns;
        while (!sbr_rsp.gnt) begin
            @(negedge clk_i);
            #1ns;
        end
    endtask

    // Finish the request that was driven last and wait for its response, which stays in sbr_rsp
    task automatic obi_finish();
        @(negedge clk_i);
        sbr_req = '0;
        while (!sbr_rsp.rvalid) @(negedge clk_i);
    endtask

    task automatic obi_write(input logic [9:0] offset, input logic [31:0] value);
        obi_drive(neopixel_pkg::NeoPixelRegisterAddrOffset + 32'(offset), 1'b1, value);
        obi_finish();
    endtask

    task automatic obi_read(input logic [9:0] offset, output logic [31:0] value);
        obi_drive(neopixel_pkg::NeoPixelRegisterAddrOffset + 32'(offset), 1'b0, '0);
        obi_finish();
        value = sbr_rsp.r.rdata;
    endtask

    // Read from an absolute address, the response error is left in sbr_rsp.r.err
    task automatic obi_read_abs(input logic [31:0] addr);
        obi_drive(addr, 1'b0, '0);
        obi_finish();
    endtask

    // A write must be accepted without an error response
    task automatic obi_write_ok(input logic [9:0] offset, input logic [31:0] value);
        obi_write(offset, value);
        if (sbr_rsp.r.err) $fatal(1, "write to 0x%0h returned an error", offset);
    endtask

    //////////////
    // Stimulus //
    //////////////

    logic [31:0] status;
    logic [31:0] value;
    int unsigned expected_bits;

    // Two writes in consecutive cycles, the second one is the next thing the bus sees after the
    // first. Both must be accepted without an error response.
    task automatic obi_write_back_to_back(input logic [31:0] addr_first, input logic [31:0] data_first,
                                          input logic [31:0] addr_second, input logic [31:0] data_second);
        obi_drive(addr_first, 1'b1, data_first);
        obi_drive(addr_second, 1'b1, data_second);
        // The response of the first write is on the bus when the second one is driven
        if (!prev_rvalid || prev_err) $fatal(1, "first write to 0x%0h failed", addr_first);
        obi_finish();
        if (sbr_rsp.r.err) $fatal(1, "second write to 0x%0h failed", addr_second);
        repeat (4) @(negedge clk_i);
    endtask

    // The pixel is the leading bits of the word followed by zeros: it was cut short
    function automatic logic pixel_is_cut(input logic [23:0] got, input logic [23:0] word);
        for (int sent = 0; sent <= 24; sent++) begin
            logic [23:0] expected;
            expected = '0;
            for (int b = 0; b < sent; b++) expected[23 - b] = word[23 - b];
            if (got === expected) return 1'b1;
        end
        return 1'b0;
    endfunction

    // The pixel the n-th 24 bits sent after bit index `first` carry
    function automatic logic [23:0] sent_pixel(input int unsigned first, input int unsigned n);
        logic [23:0] got;
        for (int b = 0; b < 24; b++) got[23 - b] = bits_q[first + n * 24 + b];
        return got;
    endfunction

    // A start with the current DMA registers must be rejected
    task automatic expect_start_rejected(input string reason);
        obi_write(DMA_VALID_OFFSET, 32'd1);
        if (!sbr_rsp.r.err) $fatal(1, "a start with %s was accepted", reason);
    endtask

    // Wait until the controller has finished its frame, latch and sleep
    task automatic wait_frame_done();
        int unsigned polls = 0;
        do begin
            obi_read(STATUS_OFFSET, value);
            if (++polls > 20000) $fatal(1, "frame never finished");
        end while (value[0]);
    endtask

    int unsigned reads_at_abort;
    int unsigned bits_before;

    initial begin
        sbr_req = '0;
        rst_ni  = 1'b0;
        for (int i = 0; i < MemWords; i++) mem[i] = $urandom();
        repeat (5) @(posedge clk_i);
        rst_ni = 1'b1;
        repeat (5) @(posedge clk_i);

        obi_write_ok(NUM_NEOPIXEL_OFFSET,     NumPixels);
        obi_write_ok(NEOPIXEL_T1H_OFFSET,     T1H);
        obi_write_ok(NEOPIXEL_T1L_OFFSET,     T1L);
        obi_write_ok(NEOPIXEL_T0H_OFFSET,     T0H);
        obi_write_ok(NEOPIXEL_T0L_OFFSET,     T0L);
        obi_write_ok(NEOPIXEL_T_LATCH_OFFSET, TLatch);
        obi_write_ok(NEOPIXEL_SLEEP_OFFSET,   0);
        obi_write_ok(FIFO_ACCESS_OFFSET,      32'(FIFO_ACCESS_DMA));

        // Registers store as many bits as the register map says and saturate above that
        obi_write_ok(NEOPIXEL_T1H_OFFSET, 32'hFFFF_FFFF);
        obi_read(NEOPIXEL_T1H_OFFSET, value);
        if (value !== 32'h0000_3FFF) $fatal(1, "T1H saturated to %0h", value);
        obi_write_ok(NEOPIXEL_T_LATCH_OFFSET, 32'h0200_0000);
        obi_read(NEOPIXEL_T_LATCH_OFFSET, value);
        if (value !== 32'h000F_FFFF) $fatal(1, "T_LATCH saturated to %0h", value);
        obi_write_ok(NEOPIXEL_SLEEP_OFFSET, 32'hFFFF_FFFF);
        obi_read(NEOPIXEL_SLEEP_OFFSET, value);
        if (value !== 32'h00FF_FFFF) $fatal(1, "SLEEP saturated to %0h", value);
        obi_write_ok(NEOPIXEL_T1H_OFFSET,     T1H);
        obi_write_ok(NEOPIXEL_T_LATCH_OFFSET, TLatch);
        obi_write_ok(NEOPIXEL_SLEEP_OFFSET,   0);
        obi_read(NEOPIXEL_T1H_OFFSET, value);
        if (value !== T1H) $fatal(1, "T1H reads %0h", value);

        // Commands that are not a non-zero number of words up to one frame are rejected
        obi_write_ok(DMA_SRC_ADDR_OFFSET,  32'(FrameWordsA * 4));
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'((NumPixels + 1) * 4));
        expect_start_rejected("more than one frame");
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'd0);
        expect_start_rejected("no bytes");
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'd6);
        expect_start_rejected("a partial word");

        // First frame as two chunks
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'(ChunkAPixels * 4));
        obi_write_ok(DMA_VALID_OFFSET,     32'd1);
        obi_read(DMA_STATUS_OFFSET, status);
        if (status[0] !== 1'b1) $fatal(1, "DMA is not busy after the first start: %0h", status);

        // The second chunk is prepared while the first one runs
        obi_write_ok(DMA_SRC_ADDR_OFFSET,  32'((FrameWordsA + ChunkAPixels) * 4));
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'((NumPixels - ChunkAPixels) * 4));
        obi_write_ok(DMA_VALID_OFFSET,     32'd1);
        obi_read(DMA_STATUS_OFFSET, status);
        if (status[1:0] !== 2'b11) $fatal(1, "second chunk is not queued: %0h", status);

        // A third start finds the queue full
        expect_start_rejected("a full queue");

        // Second frame as one command, as soon as the queue has room
        obi_write_ok(DMA_SRC_ADDR_OFFSET,  32'(FrameWordsB * 4));
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'(NumPixels * 4));
        do obi_read(DMA_STATUS_OFFSET, status); while (status[1]);
        obi_write_ok(DMA_VALID_OFFSET,     32'd1);

        expected_bits = 2 * NumPixels * 24;
        fork
            begin
                while (bits_q.size() < expected_bits) @(posedge clk_i);
                // The last latch
                while (num_latches < 2) @(posedge clk_i);
            end
            begin
                repeat (200000) @(posedge clk_i);
                $fatal(1, "timeout: %0d of %0d bits", bits_q.size(), expected_bits);
            end
        join_any
        disable fork;

        // Compare the bits with the memory
        for (int frame = 0; frame < 2; frame++) begin
            for (int pixel = 0; pixel < NumPixels; pixel++) begin
                logic [31:0] word;
                logic [23:0] got;
                word = mem[(frame == 0 ? FrameWordsA : FrameWordsB) + pixel];
                for (int b = 0; b < 24; b++) got[23 - b] = bits_q[(frame * NumPixels + pixel) * 24 + b];
                if (got !== word[23:0])
                    $fatal(1, "frame %0d pixel %0d: sent %6h, expected %6h", frame, pixel, got,
                           word[23:0]);
            end
        end
        if (bits_q.size() != expected_bits) $fatal(1, "%0d bits instead of %0d", bits_q.size(), expected_bits);
        if (num_reads != 2 * NumPixels) $fatal(1, "%0d reads instead of %0d", num_reads, 2 * NumPixels);

        repeat (50) @(posedge clk_i);
        obi_read(DMA_STATUS_OFFSET, status);
        if (status[1:0] !== 2'b00) $fatal(1, "DMA still busy at the end: %0h", status);

        // Address decoding: the window is registers then FIFO, anything else is an error
        obi_read_abs(NeoPixelRegisterAddrOffset + 32'(STATUS_OFFSET));
        if (sbr_rsp.r.err) $fatal(1, "STATUS read failed");
        obi_read_abs(NeoPixelFifoAddrOffset);
        if (sbr_rsp.r.err) $fatal(1, "FIFO window read failed");
        obi_read_abs(NeoPixelFifoAddrOffset + NeoPixelFifoAddrRange - 4);
        if (sbr_rsp.r.err) $fatal(1, "last word of the window read failed");
        obi_read_abs(NeoPixelFifoAddrOffset + NeoPixelFifoAddrRange);
        if (!sbr_rsp.r.err) $fatal(1, "read above the window did not fail");
        obi_read_abs(NeoPixelRegisterAddrOffset - 4);
        if (!sbr_rsp.r.err) $fatal(1, "read below the window did not fail");
        obi_read_abs(NeoPixelRegisterAddrOffset ^ 32'h0010_0000);
        if (!sbr_rsp.r.err) $fatal(1, "read in a far window did not fail");

        // Levels at rest
        obi_read(STATUS_OFFSET, value);
        if (value !== 32'b010) $fatal(1, "STATUS at rest: %0h", value);
        obi_read(FIFO_LEVEL_OFFSET, value);
        if (value !== 32'd0) $fatal(1, "FIFO_LEVEL at rest: %0h", value);

        // Underrun: four words of a 20 pixel frame. The other pixels are sent as zeros.
        bits_before = bits_q.size();
        obi_write_ok(IRQ_STATUS_OFFSET, 32'h7F);
        obi_write_ok(DMA_SRC_ADDR_OFFSET,  32'(FrameWordsB * 4));
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'd16);
        obi_write_ok(DMA_VALID_OFFSET,     32'd1);
        do obi_read(DMA_STATUS_OFFSET, status); while (status[0]);
        wait_frame_done();
        obi_read(IRQ_STATUS_OFFSET, value);
        if (value[6] !== 1'b1) $fatal(1, "no underrun event: %0h", value);
        if (value[4] !== 1'b1) $fatal(1, "no LATCH_LEAVE: %0h", value);
        if (bits_q.size() - bits_before != NumPixels * 24) $fatal(1, "short frame sent %0d bits",
                                                                   bits_q.size() - bits_before);
        for (int pixel = 0; pixel < NumPixels; pixel++) begin
            logic [23:0] got;
            for (int b = 0; b < 24; b++) got[23 - b] = bits_q[bits_before + pixel * 24 + b];
            if (got !== (pixel < 4 ? mem[FrameWordsB + pixel][23:0] : 24'd0))
                $fatal(1, "short frame pixel %0d: %6h", pixel, got);
        end

        // Abort and flush during a transfer: no further word is read or pushed
        obi_write_ok(IRQ_STATUS_OFFSET, 32'h7F);
        obi_write_ok(DMA_SRC_ADDR_OFFSET,  32'(FrameWordsA * 4));
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'(NumPixels * 4));
        obi_write_ok(DMA_VALID_OFFSET,     32'd1);
        do obi_read(FIFO_LEVEL_OFFSET, value); while (value < 4);
        obi_write_ok(CONTROL_OFFSET, 32'b11);
        repeat (20) @(posedge clk_i);
        obi_read(DMA_STATUS_OFFSET, status);
        if (status[1:0] !== 2'b00) $fatal(1, "DMA busy after the abort: %0h", status);
        reads_at_abort = num_reads;
        obi_read(FIFO_LEVEL_OFFSET, value);
        if (value != 0) $fatal(1, "FIFO holds %0d entries after the flush", value);
        repeat (200) @(posedge clk_i);
        if (num_reads != reads_at_abort) $fatal(1, "reads continue after the abort");
        obi_read(IRQ_STATUS_OFFSET, value);
        if (value[2] === 1'b1) $fatal(1, "DMA_DONE after an abort: %0h", value);
        wait_frame_done();

        // The next frame is sent completely and correctly
        bits_before = bits_q.size();
        obi_write_ok(DMA_SRC_ADDR_OFFSET,  32'(FrameWordsB * 4));
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'(NumPixels * 4));
        obi_write_ok(DMA_VALID_OFFSET,     32'd1);
        do obi_read(DMA_STATUS_OFFSET, status); while (status[0]);
        wait_frame_done();
        if (bits_q.size() - bits_before != NumPixels * 24) $fatal(1, "frame after abort: %0d bits",
                                                                   bits_q.size() - bits_before);
        for (int pixel = 0; pixel < NumPixels; pixel++) begin
            logic [23:0] got;
            for (int b = 0; b < 24; b++) got[23 - b] = bits_q[bits_before + pixel * 24 + b];
            if (got !== mem[FrameWordsB + pixel][23:0])
                $fatal(1, "frame after abort pixel %0d: %6h", pixel, got);
        end

        // A flush in the middle of a pixel cuts it. Words that arrive afterwards belong to the pixels
        // that follow, they must not complete the cut pixel.
        obi_write_ok(IRQ_STATUS_OFFSET, 32'h7F);
        bits_before = bits_q.size();
        obi_write_ok(DMA_SRC_ADDR_OFFSET,  32'(FrameWordsA * 4));
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'(NumPixels * 4));
        obi_write_ok(DMA_VALID_OFFSET,     32'd1);
        obi_write_ok(DMA_SRC_ADDR_OFFSET,  32'(FrameWordsB * 4));
        while (bits_q.size() < bits_before + 5) @(posedge clk_i);
        obi_write_ok(CONTROL_OFFSET,   32'b11);
        obi_write_ok(DMA_VALID_OFFSET, 32'd1);
        do obi_read(DMA_STATUS_OFFSET, status); while (status[0]);
        wait_frame_done();
        if (bits_q.size() - bits_before != 2 * NumPixels * 24)
            $fatal(1, "cut frame: %0d bits", bits_q.size() - bits_before);
        if (!pixel_is_cut(sent_pixel(bits_before, 0), mem[FrameWordsA][23:0]))
            $fatal(1, "cut pixel is %6h", sent_pixel(bits_before, 0));
        for (int pixel = 1; pixel < NumPixels; pixel++)
            if (sent_pixel(bits_before, pixel) !== mem[FrameWordsB + pixel - 1][23:0])
                $fatal(1, "cut frame pixel %0d is %6h", pixel, sent_pixel(bits_before, pixel));
        // The word that did not fit into the first frame starts the next one
        if (sent_pixel(bits_before, NumPixels) !== mem[FrameWordsB + NumPixels - 1][23:0])
            $fatal(1, "word after the cut frame is %6h", sent_pixel(bits_before, NumPixels));
        for (int pixel = 1; pixel < NumPixels; pixel++)
            if (sent_pixel(bits_before, NumPixels + pixel) !== 24'd0)
                $fatal(1, "pixel %0d of the short frame is %6h", pixel,
                       sent_pixel(bits_before, NumPixels + pixel));

        // A command in the cycle after an abort was issued after it and runs
        obi_write_ok(IRQ_STATUS_OFFSET, 32'h7F);
        bits_before = bits_q.size();
        obi_write_ok(DMA_SRC_ADDR_OFFSET,  32'(FrameWordsA * 4));
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'(NumPixels * 4));
        obi_write_back_to_back(NeoPixelRegisterAddrOffset + 32'(CONTROL_OFFSET), 32'b01,
                               NeoPixelRegisterAddrOffset + 32'(DMA_VALID_OFFSET), 32'd1);
        do obi_read(DMA_STATUS_OFFSET, status); while (status[0]);
        obi_read(IRQ_STATUS_OFFSET, value);
        if (value[2] !== 1'b1) $fatal(1, "command after an abort did not run: %0h", value);
        wait_frame_done();
        for (int pixel = 0; pixel < NumPixels; pixel++)
            if (sent_pixel(bits_before, pixel) !== mem[FrameWordsA + pixel][23:0])
                $fatal(1, "frame after back-to-back pixel %0d is %6h", pixel,
                       sent_pixel(bits_before, pixel));

        // A word written in the cycle after a flush was written after it and stays
        obi_write_ok(FIFO_ACCESS_OFFSET, 32'(FIFO_ACCESS_OBI));
        bits_before = bits_q.size();
        obi_write_back_to_back(NeoPixelRegisterAddrOffset + 32'(CONTROL_OFFSET), 32'b10,
                               NeoPixelFifoAddrOffset, 32'h00A5_5A3C);
        wait_frame_done();
        if (bits_q.size() - bits_before != NumPixels * 24)
            $fatal(1, "word after a flush: %0d bits", bits_q.size() - bits_before);
        if (sent_pixel(bits_before, 0) !== 24'hA5_5A3C)
            $fatal(1, "word after a flush is %6h", sent_pixel(bits_before, 0));
        obi_write_ok(FIFO_ACCESS_OFFSET, 32'(FIFO_ACCESS_DMA));

        // A response with an error ends the transfer: DMA_ERROR is flagged, the word is not a pixel
        obi_write_ok(IRQ_STATUS_OFFSET, 32'h7F);
        bits_before = bits_q.size();
        error_word  = FrameWordsA + 3;
        obi_write_ok(DMA_SRC_ADDR_OFFSET,  32'(FrameWordsA * 4));
        obi_write_ok(DMA_NUM_BYTES_OFFSET, 32'(NumPixels * 4));
        obi_write_ok(DMA_VALID_OFFSET,     32'd1);
        do obi_read(DMA_STATUS_OFFSET, status); while (status[0]);
        wait_frame_done();
        error_word = -1;
        obi_read(IRQ_STATUS_OFFSET, value);
        if (value[5] !== 1'b1) $fatal(1, "no DMA error event: %0h", value);
        if (value[2] !== 1'b0) $fatal(1, "DMA done after an error: %0h", value);
        for (int pixel = 0; pixel < NumPixels; pixel++)
            if (sent_pixel(bits_before, pixel) !== (pixel < 3 ? mem[FrameWordsA + pixel][23:0] : 24'd0))
                $fatal(1, "frame after an error pixel %0d is %6h", pixel,
                       sent_pixel(bits_before, pixel));

        $display("tb_neopixel: PASSED (%0d bits, %0d reads)", bits_q.size(), num_reads);
        $finish;
    end

endmodule
