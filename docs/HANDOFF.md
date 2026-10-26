# Handoff — TinyMaps — 2026-10-26

- **State:** Phases 0–3 are done and verified by simulation. Phase 4 (integration)
  is written and committed but **does not close timing**, so it produces no
  bitstream. Nothing has ever been deployed to the Tang.

- **Landed:** `79bd168` scaffold + pack builder · `1e1de8f` Phase 0 skeleton
  (builds, 137 MHz pixel clock) · `2e8ea8e` Phase 2 load receiver (5 sim cases
  pass) · `dbcf8e1` Phase 3 nearest renderer (3 pixel-exact cases) · `ad099df`
  bilinear + three row buffers · `2107fae` row reuse across the magnifying range
  · `5e4db16`, `2a32611` blocker records.

- **Branches/PRs:** none. Everything is on `main`, which is the only branch.

- **CI:** none configured. Verification is `tools/build_maps_core_open.sh` and
  `tools/run_sim.sh`; both are run by hand.

- **Blockers:** `hclk` reaches **66.16 MHz against a 74.25 MHz constraint**, so
  the timing gate refuses to pack. The failing path is the HDMI encoder's
  disparity accumulator, 14.48 ns, and the cause is that ABC merges the TMDS
  serialiser's multiplexers into it: the serialiser cluster synthesises to 545
  cells here against 261 in TinyTang's desktop core, which closes at 110 MHz on
  the same toolchain with the same `hdmi.sv`. Full measurements and nine
  exhausted levers are in `docs/integration-blocker.md`.

- **Decisions that must not be re-litigated:**
  - **Fabric-only loader, no AE350.** The load is a memcpy with a checksum; an
    AE350 would add a boot ROM, a second toolchain and D-cache writeback for
    nothing.
  - **`ahb_sdram` (vended as `sdram_ctrl.sv`), not `sdram_nes`.** `sdram_nes`
    partitions its 32 MB into per-channel NES banks of 4 MB and cannot address a
    flat 28 MB pack.
  - **Operating range is `step` in (0.5, 1]** — source pixels per output pixel,
    so *below* 1 is magnifying. Above 1 a source row can advance by two per line
    and row rotation cannot engage.
  - **One clock domain.** Everything on `hclk`; an `fclk` split was tried and
    bought nothing. Block RAM must never be written on one clock and read on
    another on this part (Apicula reads it back wrong on the GW5AST-138).
  - **Palette on the pixel clock**, line store as a synchronous block-RAM read.
  - **GPL-3.0-only.** `hdmi/` and `pll/` derive from nestang (GPL-3.0).

- **Next step:** put a register between `q_m` and the disparity accumulator in
  `fpga/tinymaps/hdmi/tmds_channel.sv`, which shortens the path regardless of
  what ABC does — and build a simulation harness that compares the encoder's
  output before and after, because it costs one clock of latency and HDMI pixel
  alignment is load-bearing on this design.

- **Continuation records:** `docs/integration-blocker.md` (the measurements).
  The Phoenix pack is at `work/pack/phoenix-18km.tmpk` (gitignored, 28.00 MiB,
  rebuilt by `tools/maps_pack.py`); tiles are cached in `~/.cache/tinymaps`.

- **Not wired:** the pack loader. `sdram_ctrl`'s write port is idle and the
  viewport registers are constants, so the SDRAM holds nothing. `maps_link_rx`
  is finished and verified but needs a UART receiver and the `0xAA` frame parser
  in front of it.
