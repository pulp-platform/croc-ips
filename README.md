# Croc-IPs

Reusable IPs targetting student tapeouts based on the [Croc](https://github.com/pulp-platform/croc), the education-oriented SoC used at ETH Zürich in the VLSI 2 course and more.

Croc-IPs are developed by students and maintained as part of the PULP project, a joint effort between ETH Zurich and the University of Bologna.

Each directory is a self-contained IP to allow for easy integration in the `user_domain` of Croc.  
Use `neopixel/` as an example for the intended structure:

```text
<IP>/
  README.md    What it is, how to integrate it, and the maturity
  rtl/         Added RTL implementing the hardware IP
  croc/        Example integration in Croc with user-domain and SoC testbench
  sw/          Drivers and example/test programs running on a Croc SoC
  test/        Optional wave scripts, FPGA setups or IP-specific (unit) tests
```

To integrate an IP in your project:

1. Copy the `<IP>/rtl/*` files to `rtl/<IP>/` in your Croc project
2. Add the files to `Bender.yml` in your Croc project and regenerate the synthesis/simulation file lists (or add them directly to the file lists, both works)
3. Either copy the provided `user_pkg.sv`, `user_domain.sv`, and `tb_croc_soc.sv` files or use them as a reference to integrate them in your Croc Project. Pay attention to address maps, bus wiring, instantiation and additional testbench connections.
4. Copy the IP-specific software sources and headers into `croc/sw/`. Build
   them with Croc's existing `Makefile`, startup code, linker script, and
   common software libraries.
5. Run one of the provided software tests to confirm the integration was successful (might need minor adjustments to address maps etc)

## Maintained IPs

| IP | State | Authors | Description |
| --- | --- | --- | --- |
| [neopixel](neopixel/README.md) | `silicon-proven` | Luisa Wüthrich for [MLEM](http://asic.ee.ethz.ch/2024/MLEM.html) | NeoPixel controller IP with FIFO, DMA, and interrupt support. |

## State

The state given is not a guarantee, it is intended as a reference to know what to expect and how much additional work is necessary.  
We always expect the integrator will test the integration and IP thoroughly for their use-case.

* `integrated`: an IP with complete Croc integration, small tests (eg read/write) pass, no functional tests exist.
* `simulation-proven`: a reproducible self-checking Croc simulation passes.
* `fpga-proven`: functionality demonstrated on a documented FPGA board.
* `silicon-proven`: functionality demonstrated on fabricated silicon (possible with _minor_ RTL fixes after-the-fact).

## License

Unless specified otherwise in the respective file headers, all code checked into this repository is made available under a permissive license.
All hardware sources and tool scripts are licensed under the Solderpad Hardware License 0.51 (see `LICENSE.md`). All software sources are licensed under Apache 2.0.
