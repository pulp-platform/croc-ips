# NeoPixel controller

This controller IP drives a chain of NeoPixel RGB LEDs.
It provides memory-mapped timing and flow control registers,
a 16-entry color FIFO, an optional 32-bit DMA and maskable interrupt events.
It is slightly modified from the tapeout version used in MLEM, Koopa, Skoll and Hati.

The controller supports up to 2048 pixels.
The NeoPixel protocol has no fixed cascade limit; at the nominal 800 kbit/s data rate,
2048 RGB pixels take about 61.44 ms to shift (16 fps) before the latch interval.
The existing 8 KiB DMA region holds one 2048-pixel raw frame.
The optional `neodisplay` layouts are a separate convenience layer and remain limited to 576 pixels.

## Quick start

1. Copy the required RTL, Croc integration, and software as described in [Croc integration](#croc-integration).
2. Adapt `sw/config.h` to the target Croc address map and clock frequency.
3. Call `neopixel_init()` or `neopixel_init_timing()`.
4. Send a frame through either `neopixel_setup_dma()` or `neopixel_fifo_write()`.
5. Wait for the frame: use `neopixel_wait_frame()` for DMA or `neopixel_wait_latch_leave()` for FIFO.

## Hardware overview

Each pixel consumes a 24-bit GRB word. Bits 23:16 are green, bits 15:8 are red,
and bits 7:0 are blue. Use `NEODISPLAY_PACK_GRB(r, g, b)` to get this format.
Words are shifted out most-significant bit first (MSB of green first).

The neopixel protocol works by altering the ratio of high and low period to transmit bits.
The neopixel IP takes the per-pixel GRB values and generates the needed waveform, followed by a latch period.
The timing register values are given in clock cycles. A value of zero means the phase completes immediately.
The provided software helpers convert nanoseconds to clock cycles.

`neopixel.sv` combines the OBI subordinate interface, control/timing registers, FIFO, DMA,
and waveform controller.
You can either continuously fill the FIFO with data or tell the DMA where to fetch the data from.
The FIFO is 16 words deep by default. A data-producer must keep it nonempty while the controller is shifting out a frame.
If the producer were to miss this and the FIFO runs empty, a value of `0x000000` (black) is used in the meantime.

## Croc integration

The files in `croc/` show you one possibility to integrate the IP in your design:

* `user_pkg.sv` declares the user-domain address range and NeoPixel parameters.
* `user_domain.sv` instantiates the peripheral and routes interrupt and data output.
* `croc_soc.sv` exposes the NeoPixel output at the SoC boundary.
* `tb_croc_soc.sv` is the corresponding testbench wrapper with the added neopixel pin.

Copy and adapt these files to your needs.
In particular, file-lists, peripheral addresses, timer setup and interrupt assignment might need adapting.

The `sw/` directory is an extension, not an independent Croc software tree.
Copy its headers and sources into `croc/sw/lib/inc`, `croc/sw/lib/src`, and `croc/sw`,
then use together with Croc's `Makefile`, `crt0.S`, linker script, and common libraries.
`sw/config.h` is a visible Croc configuration copy with the NeoPixel address and clock-frequency macros added.
It serves as an example and we recommend copying the NeoPixel defines into your version instead of replacing it.

## Verification and hardware bring-up

The MLEM NeoPixel design was simulated and tested on an FPGA before tapeout.
The bring-up sequence in [`test/neopixel.gdb`](test/neopixel.gdb)
configures one four-pixel DMA frame through an OpenOCD GDB server.
It uses the MLEM/Genesys2 address map and is neither portable nor a self-checking test.

This IP does not provide a self-checking RTL testbench.
Verifying functionality via simulation or FPGA testing is up to the integrator.

## Software API

`neopixel_init()` initializes the default pixel count and NeoPixel timing,
`neopixel_init_timing()` accepts explicit cycle counts.
`neopixel_fifo_write()` selects the FIFO mode and writes one GRB word.
`neopixel_setup_dma()` selects DMA mode, validates a raw frame, and starts the transfer.
It returns false when the request is invalid or it cannot safely change DMA configurations (eg frame in progress).

`neopixel_wait_dma()` waits for DMA completion and detects possible DMA errors.
`neopixel_wait_latch_leave()` waits until the controller is fully idle, including the configured sleep period.
`neopixel_wait_frame()` combines both waits.
The `neodisplay` helper builds simple layouts but is limited to 576 pixels and
does not change the controller's configured pixel count while a frame is active.

## Programming model

Configure the pixel count and timings before setting a data source.
The controller then shifts exactly the configured number of words/pixels before entering its latch period.

### FIFO mode

Select `NPX_FIFO_REG_MODE_FIFO`, then write color words to `NPX_FIFO_DATA_REG_OFFSET`.
`neopixel_fifo_write()` leaves FIFO mode selected so callers can continuously queue more words.
Writes to the FIFO in another mode (DMA) receive an OBI error.
Writes to an already full FIFO will stall the request, causing backpressure to the OBI manager.

### DMA mode

DMA buffers must be 32-bit-word aligned. Each command transfers exactly one raw frame:
the byte count for the frame buffer equals the configured pixel count times `sizeof(uint32_t)`.
Select `NPX_FIFO_REG_MODE_DMA`, then set the source address and byte count, then write `1` to `NPX_DMA_VALID_REG_OFFSET`.
This signals the DMA configuration is valid and it can start.

`NPX_IRQ_DMA_DONE` signals the DMA transfer finished. It does not mean that the last pixel has left the controller.
Wait for `NPX_IRQ_LATCH_LEAVE`, or use `neopixel_wait_frame()` to wait for the frame to be fully shifted out and latched.

### Mode transitions

A FIFO/DMA mode transition is accepted only when the FIFO is empty, the controller is fully idle (including its configured sleep period)
and `DMA_STATUS` is zero (DMA not running).
Software must observe `NPX_IRQ_LATCH_LEAVE` before such a transition.
`NPX_FIFO_REG_DEACTIVATED` is not a normal mode-switch and does not flush the FIFO.

## Registers and events

| Register | Offset | Access | Meaning |
| --- | ---: | --- | --- |
| `IRQ_MASK` | `0x1A0` | R/W | Enables event bits 0..5 at the interrupt output. |
| `IRQ_STATUS` | `0x1B0` | R/W1C | Sticky events; write ones to clear selected bits. |
| `DMA_STATUS` | `0x1D0` | R | Bit 0 is set while a DMA request is pending or active. |
| `FIFO_LOW_THRES` | `0x1C0` | R/W | FIFO-low threshold, range 0..16. |
| `FIFO_HIGH_THRES` | `0x1E0` | R/W | FIFO-high threshold, range 0..16. |

The event bits are `NPX_IRQ_FIFO_LOW`, `NPX_IRQ_FIFO_HIGH`, `NPX_IRQ_DMA_DONE`,
`NPX_IRQ_LATCH_ENTER`, `NPX_IRQ_LATCH_LEAVE`, and `NPX_IRQ_DMA_ERROR`.
Events get latched regardless of `IRQ_MASK`. The mask only controls the interrupt output.
Clear stale `DMA_DONE`, `DMA_ERROR`, and `LATCH_LEAVE` events before starting a new DMA command.
W1C writes of zero do not alter any event bits.

## Design history and errata

### Taped MLEM design

The neopixel controller was developed for MLEM by Luisa Wüthrich during her bachelor thesis.
The neopixel was then further used in the Croc tapeouts Koopa, Hati and Skoll.
The RTL and interrupt integration in this repository were imported from the Skoll tapeout source tree.
The current repository should not be treated as the exact taped RTL.

### Changes after the taped design

For MLEM the following limitations were discovered:

* The interrupts were not expressive enough for all use-cases.
* The number of supported pixels was limited to 511 without workaround.
* FIFO writes outside FIFO mode were not reported to the OBI manager.
* A zero sleep duration could stall the controller.

The version here fixes the four discovered limitations.
Invalid FIFO writes are reported as OBI errors and zero-duration phases are handled.

The repository also adds robustness changes not established as problems while using the chip:
sticky W1C event status, DMA pending/active status, exact-frame DMA validation,
guarded FIFO/DMA mode transitions, bounded pixel configuration and FIFO-threshold saturation.

## Provenance and license

The bare-metal driver and display examples are derived from MLEM's software.
Retained source headers identify the authors. `sw/font8x8_basic.h` is a local copy of
[`font8x8_basic.h`](https://github.com/dhepper/font8x8/blob/master/font8x8_basic.h)
from dhepper/font8x8; its original IBM VGA/public-domain attribution is retained.

See the repository license for licensing terms.
