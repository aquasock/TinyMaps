# Handoff — TinyMaps — 2026-10-26

- **State:** Phases 0–3 are verified in simulation, the integration closes
  timing, and the pack loader works on hardware. `tinymaps.8fe42ba24d8d.bin` is
  on the Tang, and a 589,824-byte test image sent over the BL616's UART was
  written to the SDRAM and drawn: twelve columns at the expected 106.7-pixel
  pitch, the staircase running white to dark from the top left, the level's
  border where it belongs. That is the first known image through the renderer,
  and it exercises the loader, both UARTs, the framing, the CRCs and the
  renderer's addressing at once. The palette now arrives over the link too, so
  the screen shows the real Phoenix map in its own colours, all four pack levels
  load over the link, and command `0x0A` switches between them without a
  reload. The top lines of every frame are now correct and confirmed on
  hardware: rows 0-20 are pixel-identical in a capture, where before rows 0-3
  were 20-85 levels out and changed every frame. One thing is open in the
  picture: a capture shows the levels lifted and clipped at the top because the
  capture path treats the RGB as limited range, which the source declaration
  does not change. One thing is open in timing: `hclk` has far less margin than
  this file used to record.

- **Landed:** `79bd168` scaffold + pack builder · `1e1de8f` Phase 0 skeleton ·
  `2e8ea8e` Phase 2 load receiver · `dbcf8e1` Phase 3 nearest renderer ·
  `ad099df` bilinear + three row buffers · `2107fae` row reuse across the
  magnifying range · `5e4db16`, `2a32611` blocker records · `32a8219`
  integration · `1342a0e` encoder pipeline, timing closed · `1595480` first
  deployment, user test passed · `876ade7` UART pair, loader wired, host tools ·
  this cycle: the loader deployed and a known image verified on hardware.

- **The main power input is dead.** Measured 2026-10-26 after the link dropped
  during a pack load: 1.4 V at 1.5 A from a bench supply on that port (about
  0.9 ohm), 1.0 ohm across its VBUS and ground on a meter with 0.1 ohm of leads
  nulled, the same in both directions, while the OTG input reads 27 kOhm and
  drifts as its input capacitor charges. A resistive short that low is a failed
  ceramic capacitor or ESD diode on that branch rather than a plain bridge; the
  board runs from the other input, so nothing downstream of the two input
  Schottkys is involved. Not repaired yet. Until it is, power the board from
  the battery connector J5 at 4.2 V or below -- 4.2 V is the recorded maximum
  for +BATT -- and the shell returns in two-wire; on the OTG cable alone the
  board comes up one-wire as SIPEED's FT2232 debugger and TinyTang does not
  run, so there is no shell and no way to load a pack.
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
  - **Operating range is `step` in (0.25, 1]** — source pixels per output pixel,
    so *below* 1 is magnifying. Above 1 a source row can advance by two per line
    and row rotation cannot engage. The floor was 0.5 while the finest pack level
    had no finer neighbour to hand over to; it moved to 0.25 when the zoom was
    made to keep magnifying there.
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
  - **The viewport arrives as command 0x0A, and its range guard is in the
    fabric.** The host computes the viewport from the pack, but the core
    refuses a step outside `(0.5, 1]` or a level that does not fit, and latches
    nothing on a refusal. That range is the renderer's operating limit, so it
    belongs where it cannot be bypassed.
  - **The palette arrives as command 0x08 on the link**, parsed by
    `maps_link_rx` alongside the image load, and written straight into the table
    the pixel path reads. The alternative — the renderer reading the palette out
    of SDRAM — was rejected because it puts a second reader on the part of the
    design that took the most work to get right.
  - **The encoder pipeline register stays.** `tmds_channel` registers `q_m` with
    `mode`, `control_data` and `data_island_data`, costing one pixel of latency
    across every mode; `sim/tb_hdmi_encode.sv` with `tools/check_tmds.py` keeps
    that honest.
  - **GPL-3.0-only.** `hdmi/` and `pll/` derive from nestang (GPL-3.0).

- **Fixed this cycle — the smear and the frame top.** Both had one cause, and
  neither was in the navigation.  A capture of the smear had all 720 rows
  identical: the renderer was drawing one source row repeatedly, which happens
  when the level width is zero, because every row address becomes
  `base + row*0`.  The level table's outputs had been declared and never
  assigned, so the core held width 0, and a pan was the first thing to read the
  table.  Once connected, the 16-bit width and height were taken from a word
  that had only shifted twice, so the width landed in the height.  Both are
  fixed and the pan is exact by measurement: 32 mouse counts move the origin
  19.2 source pixels at step 0.6.
- **Also changed, and load-bearing:** viewport writes go to a shadow swapped in
  at the top of the vertical blanking, and the renderer's blocking path now
  waits for its third row before drawing.  A viewport change costs two row
  fetches, about 2680 clocks against the 1650 a line has, so a mid-frame change
  tore the picture; and the priming fetch finished about 60 clocks after the
  emit that needed it, which put the next line into the blocking path too and
  cascaded for four lines -- the frame-top corruption.  The user reports pan and
  zoom work; the frame top has not been confirmed separately.
- **Fixed this cycle - the first lines of every frame.** The corruption was
  never in the line store and never a matter of the renderer being late.  Three
  instruments settled it in order.  A capture with the store tagged by line
  identity showed the store always holding the right line.  A stale-read marker,
  painted per row and defined as the writer writing the slot being read while at
  or behind the reader, never fired in 329 frames.  A testbench that runs the
  real renderer behind the real store with a static viewport produced two
  identical frames, 0 of 921,600 pixels apart, once a faithful model of
  `sdram_ctrl`'s video channel was in the path.  The fault was in
  `maps_video_rd`: the renderer drops `f_busy` on the last entry it accepts,
  which is not the end of the 256-byte SDRAM line, so a request that arrived
  while a line was still open reloaded `base`, `skip` and `left` and fired
  `vstart` under it.  `sdram_ctrl` only queues a `vstart` and services it when
  idle, so the stray pulse scheduled an extra line, and the old line's `vdone`
  then read as the new request's end-of-line and asked for one more: a row came
  back one SDRAM line out of place.  Only the blocking path issues fetches back
  to back, which is why the damage was the first lines of a frame and the lines
  after a pan, and why which fetch it hit varied with SDRAM latency.  The
  adapter now holds a request until the channel is idle and leaves one clear
  cycle between lines.  Measured before and after on the same testbench: 60
  vstarts during a live line, then none.
- **Timing, measured properly this cycle.**  An eight-seed sweep of the design
  that ships gives `hclk` between 66.63 and 75.65 MHz against 74.25, and seven
  of the eight fail; seed 7 passes and is the bitstream deployed.  The 83-96 MHz
  figures recorded earlier in this file were single placements, not margin.
- **Zoom range (this cycle):** the five-entry step table is gone.  A turn now
  multiplies the step by about 1/1.078 -- nine steps to the octave instead of
  five at 19% -- and a level crossing normalises to exactly 1.0 or 0.5 so the
  rounding never accumulates.  The finest level keeps magnifying below 0.5,
  where previously it stopped, down to a floor of 0.25; below 0.5 the step is
  magnification and there is no finer level left to choose.  Total range went
  from 16x to 32x, and the viewport guard's floor moved from 0.5 to 0.25 with
  it.  The nine-turn test found a real bug on the way: the crossing was judged
  against the step in force rather than the step about to be written, so a turn
  could leave the step below 0.5 on a level that had a finer neighbour.  Built
  and simulated, **not deployed** -- the Tang dropped off USB again.
- **Instrument:** command `0x0C` and `tools/read_status.py` report the viewport
  the renderer is given.  It found both table defects.  Its own known bug: the
  top byte of a base above 16 MB reads wrong, so L3 reports `0xb7b703d8` for
  `0x01b703d8`; the other fields are right.
- **Open issue — the top of every frame (older note, kept for the record).** Line 0 was being drawn only on the
  last raster line, which gave the renderer one line period (1650 clocks) for a
  discontinuity it needs about 2680 for: two row fetches at roughly 700 clocks
  plus 1280 emits. It now gets the whole vertical blanking, and line 0 measures
  correct (correlation 0.936 against the expected line, 5% of pixels off,
  against 42% before). **Lines 1 to 4 are still wrong** — 37 to 52 percent of
  their pixels off, matching no line of the expected frame — and asking for line
  1 during the blanking as well made line 0 wrong again, so the renderer cannot
  use more than one line of head start while the line store has two slots. What
  corrupts lines 1 to 4 is not established. A testbench has been written and
  abandoned once for this: a top-like model with the line store, the pixel read
  and a video-channel fetch model reproduces a frame-start failure but not this
  one, and its comparison (frame N against frame N+1) cannot catch a fault that
  repeats identically every frame. The right instrument is probably a per-line
  lateness counter read back over the link, rather than more simulation.
- **Pan and zoom:** commands `0x16` (mouse) and `0x17` (keyboard) move the view
  through `maps_nav.sv`, with `0x0B` loading the level table the zoom crosses
  with.  Verified in simulation only — `sim/tb_maps_nav.sv` checks the pan
  arithmetic, both clamps, one zoom step with the centre held, both level
  crossings and both end stops — and **has not been on hardware**, because the
  Tang was disconnected when it was built.  Nothing has exercised the mouse or
  the keyboard path at all: the frame layouts come from the BL616's own sender.
- **Next step:** the frame-start issue above, which now has a clean reproducer
  in the field: an HDMI monitor shows it with no capture in the path. The
  instrument to add is a per-line lateness counter read back over the link.
  After that, pan and zoom as controls the core reads, rather than the host
  re-sending a viewport.

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
