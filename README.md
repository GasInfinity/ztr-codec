# ztr-codec

A reimplementation of the 3DS `codec` sysmodule written in zig.

## Building

The only dependency is `zig 0.16.0` (already available in the repo flake if you use nix)

Run `zig build`; it'll download dependencies and build `zitrus` tools first, afterwards rebuilds are instantaneous.

You should see `codec.cxi` in `zig-out/bin` alongside `codec.elf`.

## Running (Luma3DS)

Copy `codec.cxi` to `/luma/sysmodules/0004013000001802.cxi` in your sd card.
  
...
  
Profit?

## Credits

All credits go to `3dbrew` and `GBATEK` as I could not do this without all the available documentation.
