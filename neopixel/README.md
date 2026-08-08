# NeoPixel / WS2812 controller

This IP drives a WS2812-style single-wire LED chain. It provides a
memory-mapped timing and control block, a 16-entry color FIFO, an optional
32-bit DMA source, and maskable interrupt events. `neopixel_init_timing()`
clamps the programmed chain length to `NPX_MAX_NUM_PIXELS` (2048). WS2812B has
no fixed protocol cascade limit; at the nominal 800 kbit/s data rate, 2048 RGB
pixels take about 61.44 ms to shift, or roughly 16.3 frames per second before
the latch interval. This is the IP's practical supported limit, not a protocol
maximum. The existing 8 KiB DMA region holds exactly one 2048-pixel raw frame.
The bundled `neodisplay` layouts are a separate convenience layer and remain
limited to 576 pixels.

## State and compatibility

`reference` for Croc integration. The RTL and software are an extracted,
tapeout-derived snapshot; no current Croc source API, address map, timer
configuration, fast interrupt number, or global MIE setup is claimed to be
compatible. Version-specific Croc integration is deferred until those
interfaces are pinned and tested together.

The copied historical simulation is not self-checking. No FPGA or silicon
demonstration has been verified in this repository.

## Programming sequence

1. Call `neopixel_init()` or `neopixel_init_timing()`. Timing register values
   are clock cycles. A value of zero makes that phase complete immediately;
   the controller does not underflow a zero value. `sleep == 0` disables the
   idle delay after a latch.
2. Set the pixel count and timing before selecting a data source. Counts above
   2048 are clamped by the software helper and by the controller.
3. Select exactly one FIFO or DMA owner with `NPX_FIFO_REG_OFFSET`.
4. Send one complete frame. The controller shifts each 24-bit color word
   most-significant bit first and enters the latch period after the configured
   number of pixels.

For FIFO mode, write `NPX_FIFO_REG_MODE_FIFO` and then write color words to
`NPX_FIFO_DATA_REG_OFFSET`. `neopixel_fifo_write()` leaves FIFO mode selected,
so callers can queue several words. A FIFO/DMA owner transition is accepted
only when the FIFO is empty, the controller is fully idle (including its
configured sleep period), and `DMA_STATUS` is zero (no command pending or
active). Software must first observe the frame's `NPX_IRQ_LATCH_LEAVE` event;
the event is the software synchronization point for an owner transition. In
the current RTL, `LATCH_LEAVE` is raised only after the configured sleep period,
so it denotes fully idle hardware rather than merely the end of latch timing.
`NPX_FIFO_REG_DEACTIVATED` is not a normal ownership-switch mechanism and does
not flush the FIFO.

During an active transfer, the FIFO producer (including the DMA producer) must
keep the FIFO nonempty. A FIFO underrun is defensively zero-filled by the
controller, but it is an integration-contract violation, not a recoverable
peripheral event.

For DMA mode, provide a 32-bit-word-aligned buffer and a byte count exactly
equal to the configured pixel count times `sizeof(uint32_t)`. Each DMA command
is one complete raw frame; partial and multi-frame byte counts are rejected.
Select `NPX_FIFO_REG_MODE_DMA`, write
`NPX_DMA_START_REG_OFFSET` and `NPX_DMA_NUM_BYTES_REG_OFFSET`, then write one to
`NPX_DMA_VALID_REG_OFFSET`. `neopixel_setup_dma()` checks these constraints, the
configured pixel count, the FIFO owner, and `DMA_STATUS` locally and returns
whether it issued the command. A DMA command is rejected unless the FIFO owner
is DMA, the configured pixel count is nonzero, and the byte count names exactly
one configured frame. `DMA_VALID` is
a write-one command strobe; do not write zero afterward. `DMA_STATUS` bit
`NPX_DMA_STATUS_BUSY` is set while a request is pending or active. A completed
source transfer raises `NPX_IRQ_DMA_DONE`, but this does not mean that the
frame has finished displaying or that the controller is idle; wait for
`NPX_IRQ_LATCH_LEAVE` as well. `neopixel_wait_dma()` records `DMA_ERROR` while
polling and does not return failure until `DMA_STATUS_BUSY` is clear and the
request has reached its terminal state.

Color words use GRB byte order: bits 23:16 are green, bits 15:8 are red, and
bits 7:0 are blue. For example, `NEODISPLAY_PACK_GRB(r, g, b)` produces the
word expected by the controller. The controller transmits the complete
configured frame as one chain; the display helper does not rewrite the count
mid-frame.

## Registers and events

The software definitions in [`sw/lib/inc/neopixel.h`](sw/lib/inc/neopixel.h)
are the public register contract. In addition to the timing, FIFO, and DMA
configuration registers, the block exposes:

| Register | Offset | Access | Meaning |
| --- | ---: | --- | --- |
| `IRQ_MASK` | `0x1A0` | R/W | Enable event bits 0..5. |
| `IRQ_STATUS` | `0x1B0` | R/W1C | Read latched events; write ones to clear. |
| `DMA_STATUS` | `0x1D0` | R | Bit 0 is pending-or-active DMA busy. |
| `FIFO_LOW_THRES` | `0x1C0` | R/W | FIFO-low threshold, valid range 0..16. |
| `FIFO_HIGH_THRES` | `0x1E0` | R/W | FIFO-high threshold, valid range 0..16. |

The six event masks are `NPX_IRQ_FIFO_LOW`, `NPX_IRQ_FIFO_HIGH`,
`NPX_IRQ_DMA_DONE`, `NPX_IRQ_LATCH_ENTER`, `NPX_IRQ_LATCH_LEAVE`, and
`NPX_IRQ_DMA_ERROR` (bits 0 through 5). Use `neopixel_irq_status()` to read
events and `neopixel_irq_clear(mask)` to acknowledge them. W1C writes of zero
have no effect; preserve unrelated events when clearing a subset. Events latch
in `IRQ_STATUS` regardless of `IRQ_MASK`; the mask only controls the interrupt
output. Clear stale `DMA_DONE`, `DMA_ERROR`, and `LATCH_LEAVE` events before a
new DMA command. Use `neopixel_wait_dma()` to wait for source-transfer
completion while detecting `DMA_ERROR`, then
`neopixel_wait_latch_leave()` to wait for the fully idle controller after the
configured sleep period. `neopixel_wait_frame()` combines those waits. Use
`neopixel_dma_busy()` to inspect the DMA status bit.

## Croc extraction notes

The `croc/` files are historical user-domain collateral, not a supported
versioned Croc integration recipe. Croc source-list APIs, peripheral addresses,
timer setup, fast interrupt assignment, and global machine-interrupt enable
must be adapted to the target Croc revision before use.

## Sources and provenance

* The RTL and interrupt integration are from the Skoll tapeout import recorded
  locally as commit `05c1705fd55dff5770f82d1b96447c7469929096` (Luisa Wüthrich;
  imported by Thomas Benz, 2025-08-21).
* The bare-metal driver and display example are historical MLEM material. The
  retained source headers identify Philippe Sauter, with prior integration
  work by Hannah Pochert and Luisa Wüthrich.
* `sw/font8x8_basic.h` is a local copy of the `font8x8_basic.h` file from
  [dhepper/font8x8](https://github.com/dhepper/font8x8/blob/master/font8x8_basic.h).
  Its original IBM VGA/public-domain attribution is retained in that file; no
  network fetch is needed to build this repository. The imported copy does not
  retain an upstream commit identifier, so that URL is not a pinned provenance
  anchor.

The commit hash and local copies above are the reproducibility anchors. This
repository does not claim that the historical source trees remain API
compatible with current Croc or MLEM releases.

## Software integration

The `sw/` directory contains only NeoPixel-specific drivers, display helpers,
and examples. Copy its headers and source files into the corresponding
`croc/sw/lib/inc`, `croc/sw/lib/src`, and `croc/sw` locations, then use Croc's
existing `Makefile`, `crt0.S`, `link.ld`, and common software libraries.

`sw/config.h` is a visible copy of the Croc software configuration with the
NeoPixel address and clock-frequency macros included. Copy it alongside the
NeoPixel sources, then update the address map, UART settings, and other Croc
platform constants for the target integration. The `neopixel_test.c` example
uses Croc's `obi_timer` API and supplies its OBI-timer interrupt handler
locally.

The files under `test/` retain historical FPGA/JTAG commands and a Genesys2
constraint reference; they are not a portable or self-checking test flow.
