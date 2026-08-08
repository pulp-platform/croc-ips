# Auxiliary test collateral

`fpga_neopixel_commands.bat` and `genesys2.xdc.reference` are historical
MLEM/Genesys2 collateral. They document an earlier FPGA/JTAG setup and are not
a maintained, portable, or self-checking test flow. The register sequence in
the batch file predates the `IRQ_STATUS`, `DMA_STATUS`, and write-one DMA
command semantics documented in the parent README; adapt it before use. In
particular, a FIFO/DMA owner change requires an empty FIFO, a fully idle
controller (including its configured sleep period), no pending or active DMA
command, and software observation of `LATCH_LEAVE`; deactivation is not a FIFO
flush. The current RTL raises `LATCH_LEAVE` only once that fully idle state is
reached.

No Croc simulation, FPGA run, or hardware test is claimed by this directory.
