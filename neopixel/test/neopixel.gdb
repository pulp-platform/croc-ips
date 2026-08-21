# SPDX-License-Identifier: SHL-0.51
#
# Start an OpenOCD server for the target before running:
#   riscv32-unknown-elf-gdb -x test/neopixel.gdb
#
# This FPGA bring-up sequence configures and starts one four-pixel DMA frame.
# It is not a self-checking test and is only meant for a quick bring-up test.
# The address map of the original MLEM/Genesys2 setup is used.

set pagination off
set confirm off
set architecture riscv:rv32
target extended-remote localhost:3333
monitor reset halt

set $npx_base = 0x20001000
set $frame = 0x10000374

# One GRB word per pixel.
set {unsigned int}$frame = 0x00ff0000
set {unsigned int}($frame + 4) = 0x0000ff00
set {unsigned int}($frame + 8) = 0x000000ff
set {unsigned int}($frame + 12) = 0x0000ffff

# Four pixels and NeoPixel timings for a 20 MHz clock.
set {unsigned int}($npx_base + 0x040) = 4
set {unsigned int}($npx_base + 0x060) = 16
set {unsigned int}($npx_base + 0x080) = 9
set {unsigned int}($npx_base + 0x0a0) = 8
set {unsigned int}($npx_base + 0x0c0) = 17
set {unsigned int}($npx_base + 0x0e0) = 2000
set {unsigned int}($npx_base + 0x100) = 2000

# Clear sticky events, select DMA ownership, and launch exactly one frame.
set {unsigned int}($npx_base + 0x1b0) = 0x3f
set {unsigned int}($npx_base + 0x180) = 2
set {unsigned int}($npx_base + 0x120) = $frame
set {unsigned int}($npx_base + 0x140) = 16
set {unsigned int}($npx_base + 0x160) = 1

echo NeoPixel DMA frame started. Inspect DMA_STATUS (0x200011d0) and IRQ_STATUS (0x200011b0).\n
