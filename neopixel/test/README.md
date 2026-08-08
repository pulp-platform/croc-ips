# NeoPixel bring-up

`neopixel.gdb` is a simple bring-up sequence for the Neopixel peripheral.
Start OpenOCD for the target, then run it with:

```sh
riscv32-unknown-elf-gdb -x test/neopixel.gdb
```

The script configures a four-pixel DMA frame and neopixel sends it via its DMA.
You should be able to see four LEDs light-up as Green, Red, Blue and Magenta.
On a logic analyzer you should see the four 24-bit GRB words being transmitted in the neopixel protocol.
To use it you may need to adapt the OpenOCD configuration, address map, clock-derived timing values, and memory address.
