# Handoff — TinyMaps — 2026-10-26

- **State:** Phases 0–3 are verified in simulation. The integration closes timing
  and packs. An earlier bitstream has been on the Tang and works: 1280x720p60
  locks and the picture is stable. The pack loader is now wired — UART in and
  out on the BL616's link, `maps_link_rx` behind them on the SDRAM's A25 port —
  and that build passes every simulation and packs a bitstream, but it has not
  been on the board. What has never happened is a *known image* through the
  renderer: until one is loaded, the screen proves the path runs, not that it
  indexes correctly.

- **Landed:** `79bd168` scaffold + pack builder · `1e1de8f` Phase 0 skeleton ·
  `2e8ea8e` Phase 2 load receiver · `dbcf8e1` Phase 3 nearest renderer ·
  `ad099df` bilinear + three row buffers · `2107fae` row reuse across the
  magnifying range · `5e4db16`, `2a32611` blocker records · `32a8219`
  integration · `1342a0e` encoder pipeline, timing closed · `1595480` first
  deployment, user test passed · this cycle: UART pair, loader wired, host
  tools, and the viewport constants pointed at a test image.

- **Branches/PRs:** none. Everything is on `main`, which is the only branch.

- **CI:** none configured. Verification is `tools/build_maps_core_open.sh` and
  `tools/run_sim.sh`; both are run by hand.

- **Bitstream:** `build/tinymaps/open-s1/tinymaps.8fe42ba24d8d.bin`
  (4,381,164 bytes) and `tinymaps.ea8a7368d345.fs`, placement seed 1, `hclk`
  83.06 MHz against 74.25 and `clk` 426.26 against 21.49, setup=0 hold=0. Built
  from an empty `build/` to the same hashes twice. This is the first build that
  carries the loader. The bitstream that ran on the board was
  `tinymaps.46bc5de68231.bin`, which has no loader in it.

- **On the Tang:** `/root/cores/console138k/tinymaps.bin` on the card holds the
  loader-less image. `tangload /root/cores/console138k/tinymaps.bin` programs
  the FPGA from the shell or from `TinyTang/tools/tinytang_run.py`, and the load
  is to SRAM, so a power cycle returns the console core. To put the loader build
  on the board, upload it with TinyTang's `tangput` first — it is not there yet.

- **Decisions that must not be re-litigated:**
  - **Fabric-only loader, no AE350.** The load is a memcpy with a checksum; an
    AE350 would add a boot ROM, a second toolchain and D-cache writeback for
    nothing.
  - **`ahb_sdram` (vended as `sdram_ctrl.sv`), not `sdram_nes`.** `sdram_nes`
    partitions its 32 MB into per-channel NES banks of 4 MB and cannot address a
    flat 28 MB pack.
  - **The loader parses the link's frames itself.** `maps_link_rx` hunts `0xAA`,
    takes the big-endian length and command `0x07`, and writes the payload
    through the A25 port. There is no separate frame-parser module to keep in
    step with it.
  - **The loader and the renderer share the SDRAM through the controller's own
    arbitration.** The A25 port and the video channel are separate ports on
    `sdram_ctrl`, which gives a pending video line priority, so a load cannot
    stall a scanline. Nothing else arbitrates.
  - **Operating range is `step` in (0.5, 1]** — source pixels per output pixel,
    so *below* 1 is magnifying. Above 1 a source row can advance by two per line
    and row rotation cannot engage.
  - **The viewport constants are set for a 768x768 level at SDRAM byte 0 with
    step 0.600006** (0.6 × 1280 = 768, so the level fills the line exactly).
    That is both the test image's geometry and the pack's L3 level.
  - **One clock domain.** Everything on `hclk`; an `fclk` split was tried and
    bought nothing. Block RAM must never be written on one clock and read on
    another on this part (Apicula reads it back wrong on the GW5AST-138).
  - **The encoder pipeline register stays.** `tmds_channel` registers `q_m` with
    `mode`, `control_data` and `data_island_data`, costing one pixel of latency
    across every mode; `sim/tb_hdmi_encode.sv` with `tools/check_tmds.py` keeps
    that honest.
  - **GPL-3.0-only.** `hdmi/` and `pll/` derive from nestang (GPL-3.0).

- **Next step:** put `tinymaps.8fe42ba24d8d.bin` on the card, `tangload` it, and
  run `tools/load_image.py work/test/test-image.bin`. The screen should become a
  12 by 12 staircase, white at the top left and black at the bottom right, in
  grey. That is the first known image through the renderer. If it arrives, the
  next work is the pack's palette (the fabric grey ramp has to become the pack's
  own 256 colours) and then a level selector.

- **Continuation records:** `docs/integration-blocker.md` (timing result, the
  fix, the exhausted levers, the encoder's open conformance question).

- **Unverified:** the loader has never run on hardware, and the UART pins
  (`uart_rx` V14, `uart_tx` U15) are taken from TinyTang's desktop core without
  having been exercised from this core. The host tool's framing is proven only
  against the testbench's, which is the same byte sequence the RTL accepts in
  simulation. The palette is still a grey ramp, so a loaded image is shown in
  grey rather than in its own colours. The renderer's real-time claim is by
  construction, not measured: whether the SDRAM delivers a 1284-entry row inside
  a 1650-clock line has not been exercised with real data.
