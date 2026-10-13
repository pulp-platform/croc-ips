#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Apply the known Croc main overlay. This intentionally overwrites Croc
# integration files and is therefore a CI helper, not a merge tool.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <croc-root>" >&2
    exit 1
fi

ip_root="$(cd "$(dirname "$0")/../.." && pwd)/neopixel"
croc_root="$(cd "$1" && pwd)"
bender_file="$croc_root/Bender.yml"

for required_file in \
    "$croc_root/rtl/user_pkg.sv" \
    "$croc_root/rtl/user_domain.sv" \
    "$croc_root/rtl/croc_soc.sv" \
    "$croc_root/rtl/croc_chip.sv" \
    "$croc_root/rtl/test/tb_croc_soc.sv" \
    "$bender_file"; do
    [[ -f "$required_file" ]] || {
        echo "Missing Croc integration file: $required_file" >&2
        exit 1
    }
done

mkdir -p "$croc_root/rtl/neopixel"
cp "$ip_root"/rtl/*.sv "$croc_root/rtl/neopixel/"
cp "$ip_root/croc/user_pkg.sv" "$croc_root/rtl/user_pkg.sv"
cp "$ip_root/croc/user_domain.sv" "$croc_root/rtl/user_domain.sv"
cp "$ip_root/croc/croc_soc.sv" "$croc_root/rtl/croc_soc.sv"
cp "$ip_root/croc/croc_chip.sv" "$croc_root/rtl/croc_chip.sv"
cp "$ip_root/croc/tb_croc_soc.sv" "$croc_root/rtl/test/tb_croc_soc.sv"

grep -Fqx '  - rtl/user_pkg.sv' "$bender_file" || {
    echo "Unsupported Croc Bender package section" >&2
    exit 1
}
if ! grep -Fqx '  - rtl/neopixel/neopixel_pkg.sv' "$bender_file"; then
    sed -i '/^  - rtl\/user_pkg\.sv$/a\  - rtl/neopixel/neopixel_pkg.sv' "$bender_file"
fi

grep -Fqx '      - rtl/user_domain.sv' "$bender_file" || {
    echo "Unsupported Croc Bender RTL section" >&2
    exit 1
}
if ! grep -Fqx '      - rtl/neopixel/neopixel.sv' "$bender_file"; then
    sed -i '/^      - rtl\/user_domain\.sv$/i\      - rtl/neopixel/neopixel_controller.sv\n      - rtl/neopixel/neopixel_dma.sv\n      - rtl/neopixel/neopixel_reg.sv\n      - rtl/neopixel/write_to_fifo.sv\n      - rtl/neopixel/neopixel.sv' "$bender_file"
fi

cp "$ip_root/sw/lib/inc/neopixel.h" "$croc_root/sw/lib/inc/"
cp "$ip_root/sw/lib/src/neopixel.c" "$croc_root/sw/lib/src/"
cp "$ip_root/test/neopixel_integration_test.c" "$croc_root/sw/test/"

if ! grep -Fqx '#define NPX_BASE_ADDR 0x20001000' "$croc_root/sw/config.h"; then
cat >> "$croc_root/sw/config.h" <<'EOF'

// NeoPixel controller integration.
#define NPX_BASE_ADDR 0x20001000
#define NPX_FREQ      TB_FREQUENCY
EOF
fi
