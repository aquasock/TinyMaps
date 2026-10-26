# Handoff — TinyMaps — 2026-10-26

- **State:** Phases 0–3 are verified in simulation, the integration closes
  timing, and the pack loader works on hardware. `tinymaps.8fe42ba24d8d.bin` is
  on the Tang, and a 589,824-byte test image sent over the BL616's UART was
  written to the SDRAM and drawn: twelve columns at the expected 106.7-pixel
  pitch, the staircase running white to dark from the top left, the level's
  border where it belongs. That is the first known image through the renderer,
  and it exercises the loader, both UARTs, the framing, the CRCs and the
  renderer's addressing at once. What is left is colour: the palette is still a
  grey ramp in fabric, and the picture arrives lifted and clipped at the top
  because the sink treats the RGB as limited range.

- **Landed:** `79bd168` scaffold + pack builder · `1e1de8f` Phase 0 skeleton ·
  `2e8ea8e` Phase 2 load receiver · `dbcf8e1` Phase 3 nearest renderer ·
  `ad099df` bilinear + three row buffers · `2107fae` row reuse across the
  magnifying range · `5e4db16`, `2a32611` blocker records · `32a8219`
  integration · `1342a0e` encoder pipeline, timing closed · `1595480` first
  deployment, user test passed · `876ade7` UART pair, loader wired, host tools ·
  this cycle: the loader deployed and a known image verified on hardware.

- **Branches/PRs:** none. Everything is on `main`, which is the only branch.

- **CI:** none configured. Verification is `tools/build_maps_core_open.sh` and
  `tools/run_sim.sh`; both are run by hand.

- **Bitstream:** `build/tinymaps/open-s1/tinymaps.8fe42ba24d8d.bin`
  (4,381,164 bytes) and `tinymaps.ea8a7368d345.fs`, placement seed 1, `hclk`
  83.06 MHz against 74.25 and `clk` 426.26 against 21.49, setup=0 hold=0. Built
  from an empty `build/` to the same hashes twice. This is the first build that
  carries the loader. The bitstream that ran on the board was
  `tinymaps.46bc5de68231.bin` and now holds `tinymaps.8fe42ba24d8d.bin`; the
  board was running the loader build when the test image was loaded.

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
  - **The AVI InfoFrame declares full-range RGB.** `RGB_QUANTIZATION_RANGE =
    2'b01`, set in `maps_hdmi.sv`. The first hardware capture showed full-range
    data arriving as if it were limited range (236 as 255, everything above
    about 235 clipped), so the source now says what it means. The vendored
    modules carry the parameter with their defaults unchanged. Note that this
    did **not** change what a capture shows — see Unverified — so the
    declaration is the honest thing to send, not a fix for the capture.
  - **The encoder pipeline register stays.** `tmds_channel` registers `q_m` with
    `mode`, `control_data` and `data_island_data`, costing one pixel of latency
    across every mode; `sim/tb_hdmi_encode.sv` with `tools/check_tmds.py` keeps
    that honest.
  - **GPL-3.0-only.** `hdmi/` and `pll/` derive from nestang (GPL-3.0).

- **Next step:** the pack's palette, which is the last thing between this and a
  real map, and needs a decision on how the loader supplies 256 entries — a
  palette command on the link, a second pass over the pack's palette section,
  or a region of SDRAM that the renderer reads. Then a level selector that
  holds `step` inside `(0.5, 1]` across the pack's four levels, and the first
  load of the full 28 MB pack.

- **Continuation records:** `docs/integration-blocker.md` (timing result, the
  fix, the exhausted levers, the encoder's open conformance question).

- **Unverified:** whether the sink honours the full-range declaration. It is on
  the board, and a capture of that build is pixel-identical to a capture of the
  one that declared limited range, so the capture path expands regardless; the
  display cannot be measured from here. The renderer's real-time claim is by
  construction, not
  measured — whether the SDRAM delivers a 1284-entry row inside a 1650-clock
  line has held so far only with a 768-wide level and a static picture, and no
  one has panned or changed level on hardware. The loader has no idle timeout.
  Nothing has loaded more than 576 KiB, so the pack's 28 MB has not been tried;
  at 190 kB/s that is about two and a half minutes.
