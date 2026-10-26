# Handoff — TinyMaps — 2026-10-26

- **State:** Phases 0–3 are done and verified by simulation. Phase 4 (integration)
  is written, **closes timing**, packs a bitstream, and that bitstream has run
  on the Tang: 1280x720p60 locks and the picture is stable. The loader is not
  wired, so what it draws is the palette over empty SDRAM, not a map.

- **Landed:** `79bd168` scaffold + pack builder · `1e1de8f` Phase 0 skeleton ·
  `2e8ea8e` Phase 2 load receiver (5 sim cases pass) · `dbcf8e1` Phase 3 nearest
  renderer (3 pixel-exact cases) · `ad099df` bilinear + three row buffers ·
  `2107fae` row reuse across the magnifying range · `5e4db16`, `2a32611` blocker
  records · `32a8219` integration, committed with timing open · `1342a0e`
  encoder pipeline, timing closed at `hclk` 84.28 MHz.

- **Branches/PRs:** none. Everything is on `main`, which is the only branch.

- **CI:** none configured. Verification is `tools/build_maps_core_open.sh` and
  `tools/run_sim.sh`; both are run by hand.

- **Bitstream:** `build/tinymaps/open-s1/tinymaps.46bc5de68231.bin`
  (4,399,798 bytes) and `tinymaps.46f5c35cbda5.fs`, placement seed 1, built from
  an empty `build/` to the same hashes twice. `hclk` 84.28 MHz against 74.25,
  `clk` 428.08 against 21.49, setup=0 hold=0. Gitignored, rebuild with
  `tools/build_maps_core_open.sh`.

- **On the Tang:** that `.bin` is on the card at
  `/root/cores/console138k/tinymaps.bin` (uploaded with TinyTang's `tangput`,
  size confirmed on the card). Program it over the board's JTAG with
  `tangload /root/cores/console138k/tinymaps.bin` from the shell or with
  `TinyTang/tools/tinytang_run.py`. `tangload` reports `ID=0001081b` and
  `Load SRAM`, so it is volatile: a power cycle returns the console core.
  Deployed and confirmed on 2026-10-26.

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
  - **The encoder pipeline register stays.** `tmds_channel` registers `q_m` with
    `mode`, `control_data` and `data_island_data`, costing one pixel of latency
    across every mode. Delaying the video without the mode would shift the
    picture against its own sync, and the parity harness exists to keep that
    honest.
  - **GPL-3.0-only.** `hdmi/` and `pll/` derive from nestang (GPL-3.0).

- **Next step:** wire the pack loader — `sdram_ctrl`'s A25 write port is idle and
  the viewport registers in `tinymaps_top.sv` are constants, so the SDRAM holds
  nothing and the picture is the default palette over empty memory. That means a
  UART receiver and the `0xAA` frame parser in front of `maps_link_rx`, the
  loader writing through the idle write port, and a loader-versus-renderer
  arbitration rule for the SDRAM. Then a level selector that keeps `step` inside
  `(0.5, 1]`.

- **Continuation records:** `docs/integration-blocker.md` (the timing result, the
  fix, the nine exhausted levers, and the encoder's open conformance question).
  The Phoenix pack is at `work/pack/phoenix-18km.tmpk` (gitignored, 28.00 MiB,
  rebuilt by `tools/maps_pack.py`); tiles are cached in `~/.cache/tinymaps`.

- **Unverified:** what the SDRAM holds. Nothing has sent a known image, so the
  picture path past the palette is unproven: the screen shows a locked, stable
  field of noise, which is the expected result of a palette lookup over
  uninitialised memory and is not evidence that the renderer is indexing
  correctly. The link is silent too -- `fpga` on the shell reports no answer on
  UART1 because no UART responder exists yet. HDMI, the clock topology and the
  fact that the design runs at 74.25 MHz on silicon are now hardware-confirmed;
  the renderer's real-time claim is still by construction, not measured, since
  whether the SDRAM delivers a 1284-entry row inside a 1650-clock line has not
  been exercised with real data either.
