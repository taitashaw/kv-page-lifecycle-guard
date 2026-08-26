# Scratch aperture reservation

The guard's read master is confined in the block design to:

    offset 0x0000000070000000   range 256M

QSPI (512M) and LPS_OCM (16M) are excluded from its address space entirely.

## What this does and does not guarantee

The address editor bounds what the hardware **can address**. It does not stop
Linux from allocating in that range. Both are required before the HIL gate.

## Required boot-time reservation

Reserve the same window from the kernel, either via device tree:

    reserved-memory {
        #address-cells = <2>;
        #size-cells = <2>;
        ranges;
        kv_scratch: kv-scratch@70000000 {
            reg = <0x0 0x70000000 0x0 0x10000000>;
            no-map;
        };
    };

or by capping usable DDR on the kernel command line:

    mem=1792M

1792M = 0x70000000, so everything at and above the aperture base is left out of
the kernel's usable map.

## Verification before the board is trusted

    cat /proc/iomem | grep -i 70000000

Must NOT show System RAM covering the aperture. If it does, the reservation did
not take and the HIL run must not proceed.
