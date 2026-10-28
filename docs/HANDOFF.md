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

- **Fixed this cycle — the stretched, smeared picture.** The picture on the Tang
  was stretched vertically, broken into vertical bars and smeared on the first
  move. It was not the loader, the pack, the palette or the addressing: it was
  the renderer failing to draw most of the lines it was offered. The new bench
  `sim/tb_maps_line_budget.sv` runs the real renderer, the real chunk sequencer
  and the real page table at the top's own geometry — `OUT_W` 1280, `SPAN` 644
  entries, 128-pixel tiles — pre-fills the pool so every fetch hits because what
  is under test is time and not data, and paces `cy` one line per 1650 clocks,
  which is what a 1280-pixel line has at 74.25 MHz. With a pool that answers
  every clock the engine kept up, and that is why nothing had ever caught this:
  every other bench models a channel about twice as fast as the real one. At two
  clocks an entry — the rate the handoff's own measurement of a 644-entry row at
  about 1340 clocks implies — the engine completed **26 of 48 lines**.

  The mechanism, from the instrumented bench rather than from reading the code: a
  row fetch takes 1486 clocks and the emit that hides it is 1285, so the prefetch
  started at a line's `S_PLAN` landed about 200 clocks *after* the next line had
  begun. That line found its second row still arriving, took the blocking path —
  refetch both rows and a third, 4461 clocks — and lost 2.7 lines. Emits then
  started alternately 1285 and 5963 clocks apart: four row fetches per two lines
  where one would do, a period of 7248 clocks against a 1650-clock raster. Two
  thirds of the lines are never drawn and the line store repeats what it has,
  which is the stretch, the bars and the smear.

  The fix is in `maps_render.sv`. A fourth row buffer, and the buffer a row lives
  in is now its own row number modulo four rather than a `cur`/`nxt`/`fre`
  rotation, so a line the raster skips is answered out of the buffers it should
  be answered from instead of failing a check that only ever looked one place
  along. Each line fetches the row *three* on from its own first row, which gives
  that fetch two line times instead of one. And the prefetch is issued from
  `S_EMIT` as soon as the channel is free, not only at the plan: the request used
  to be dropped whenever the channel was still busy with the row started a line
  ago, and one dropped prefetch became a blocking path two lines later. A
  bounded `S_HOLD` state waits for a row already in flight when the line's own
  measured period has the slack for it, rather than refetching three rows the
  line cannot afford. At two clocks an entry the bench goes from 26/48 to 42/48
  with **zero** blocking paths after warm-up, the six remaining losses being the
  cold start where the buffers begin empty; the same bench run against the
  pre-fix renderer reports 26/48 with three blocking paths, so it measures the
  fault and not a coincidence, and both versions pass at one clock an entry.

  What that leaves is throughput, not deadline: one row per line means the
  channel has to deliver an entry faster than every 2.5 clocks. At the measured
  1340 clocks a row that is 310 clocks of headroom per line, and the two-line
  lead absorbs up to 1960 clocks of jitter — refresh, arbitration with the
  scan-out — in any single fetch, which is what the old one-line deadline had
  none of. A 32-bit pool read would double that headroom and is the change to
  make if the channel turns out slower than measured.

  The fourth row buffer and the second row-address multiply cost nothing that
  shows: eight seeds pack, 75.62 to 85.48 MHz, best at seed 3, which is the band
  this design sat in before the change. The best artefact is
  `build/seed-3/open/tinymaps.a8ba28a06bf9.bin`; seed 2 at 75.62 MHz is the one
  to use if a particular board needs more margin than the picture needs speed.
  Twenty of twenty simulations pass, the new bench included.

- **Verified on hardware, and what that does and does not cover.**
  `tinymaps.a8ba28a06bf9.bin` is on the Tang and all four levels of
  `phoenix-18km.tmpk` are in its SDRAM. The user reports the map perfect while
  still, panning and zooming within a level perfect, and level crossings working
  once every level was loaded. That is the renderer and the line engine proven:
  the stretch, the bars and the smear are gone, which was the fault this cycle
  set out to fix. It does **not** cover streaming. Every one of those tests drew
  from the pack in SDRAM; the tile pool was never shown to be feeding a picture.
  One attempt with `serve_tiles.py` running ended with the core in the fallback,
  asking only for level-1 tiles — 126 requests over 16 tiles and not one for the
  level-0 tile it wanted — and that run is not evidence of a defect, because the
  server had been killed twice mid-flight and the pool source is latched in the
  fabric. Streaming needs its own clean run: tangload, level table, level-0 view,
  then the server started once and left alone.

- **A level crossing that shows static is an unloaded level, not a fault.** Cost
  one round trip this cycle: only level 1 had been loaded, the level table still
  said four levels were there, and crossing into level 0 or 2 read erased SDRAM —
  0xFF through the palette, which looks like the old corruption and is not. Load
  every level the table advertises before judging a crossing, or advertise only
  the levels that are loaded.

- **Open — streaming does not converge, and the board leaves USB.** The
  fallback's retry timer was reloaded on every miss, so the epoch that is meant
  to end the fallback could never expire and the host was never asked for a
  fine tile; that is fixed and bracketed by `sim/tb_maps_stream_epoch.sv`
  (pre-fix: still in fallback after 400 lines, no fine request; fixed: retries
  at line 337). What is still open is whether a delivered tile becomes resident.
  On hardware the core asks for two to eight distinct tiles over and over, the
  host answers each with sixteen blocks and every block is acknowledged, and the
  core asks again. Three serve sessions in a row ended with the board gone from
  USB within about thirty seconds — `write failed: [Errno 19] No such device`, a
  request frame carrying a nonsense tile coordinate, then no `/dev/ttyACM` — so
  part of that behaviour may be a board that is leaving rather than a pool that
  is not filling, and the dead main power input is the first thing to suspect.
  The next move is an instrument, not another guess: `maps_tiles` already counts
  `hits` and `misses`, they are wired to nothing, and putting them plus a commit
  counter through the status command answers "is a delivered tile resident" in
  one rebuild and one run. `sim/tb_maps_stream_wide.sv` is a first attempt at the
  same question at the top's geometry and is deliberately not in the suite: its
  pixel mismatches are its own line pacing, not the design's.

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

- **On the Tang:** `/root/cores/console138k/tinymaps.a8ba28a06bf9.bin` is the
  build running as of 2026-10-27 — seed 3, 85.48 MHz, the line-engine fix — and
  its SDRAM holds all four levels of `work/pack/phoenix-18km.tmpk` loaded with
  `tools/load_pack.py --levels all`. `tangload` programs the FPGA from the shell
  or from `TinyTang/tools/tinytang_run.py`, and a load that does not print
  `tangload: core loaded` did nothing. The load is to SRAM, so a power cycle
  returns the console core. `tinymaps.bin` on the card is an older image and not
  what the board is running.

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
- **Fixed this cycle - the pan's arithmetic, and with it the 5 Mbaud margin.**
  The link work left the 5 Mbaud build marginal, one seed of eight passing at
  74.97, and the placement report said why: once the renderer's row pair and
  fetch base had their own cycles, the critical path moved into `maps_nav`, where
  `N_PAN` computed four clamped candidates -- add, compare, mux, each 32 bits --
  into the same register's enable, 13.48 ns against a 13.47 ns period with 1.27
  ns of it a route from a site to itself. A new `N_PRE` state registers those
  candidates one clock before `N_PAN` chooses between them, costing one clock in
  the sixteen a nudge takes. The controlled comparison first established that the
  link constants were innocent: the same tree at 2 Mbaud gave 82.41 and 78.79 at
  seeds 1 and 7 where 5 Mbaud gave 74.21 and 74.97, so the netlist's placement
  had changed, not the UART. With the fix the same two seeds give 82.21 and
  84.35 at 5 Mbaud -- better than the 2 Mbaud build at the same seeds. Deployed
  as `tinymaps.ac916e42ed71.bin` at seed 7, 84.35 MHz, with the pack reloaded and
  the view on L3, and the user reports it behaves exactly like the previous
  build. The committed default stays 2 Mbaud and sixteen samples: a 5 Mbaud
  default leaves the core deaf after `tangload` until `fpgabaud 5000000` is
  typed, which is a poor default for a viewer, so the faster link is a build
  parameter plus one console command rather than the shipped default.
- **Measured last cycle - the link, and 12 Mbaud ruled out.**  The BL616 link
  was measured at 190 kB/s on 2 Mbaud (95% of its wire rate, so framing costs
  about 5%) and at **431 kB/s on 5 Mbaud**, the same 4 MiB in 9.7 s against
  22.0 s.  The oversampling is what sets the ceiling: sixteen samples a bit
  needs sixteen clocks a bit, so the 74.25 MHz pixel clock cannot pass 4.64
  Mbaud, and 5 Mbaud runs at eight samples with a bit 14.85 clocks wide.  The
  plan to reach 12 Mbaud by putting the PHY on the 371.25 MHz TMDS clock failed
  and is recorded so it is not retried: the receiver closes at 189 MHz against
  371 (154 before the accumulator was narrowed from twenty bits to twelve), and
  a baud accumulator is a feedback loop, so pipelining cannot split its depth.
  12 Mbaud needs a ~200 MHz clock from the PLL.  On the BL616 side the rate only
  moves when asked, so TinyTang gained `fpgabaud <rate>`, which sets UART1
  directly without negotiating with the core; a mis-set rate is one command from
  recovery, which was verified both ways on the board.  The 5 Mbaud build is
  **marginal**: one of eight placement seeds passed at 74.97 MHz against 74.25,
  where the previous build swept 78.44 to 82.41 with seven of eight, so the next
  cycle measures the same tree at 2 Mbaud to see whether the constants cost
  about six megahertz or the design was always this close to the wall.
- **Added last cycle - the marker doubled and the hand pulls the right way.**
  Two corrections the user asked for after driving the first cursor build: the
  marker is thirty-two pixels instead of sixteen, with a four-pixel frame and a
  four-pixel crosshair so the proportions are unchanged, and a mouse drag now
  *pulls* the land the way the cursor goes rather than sending it the other way.
  The inversion is only in the drag: a keyboard pan still adds its report,
  because the arrows move the view toward the arrow and a key press is not a
  hand.  Both were cheap and neither moved the timing much -- the eight-seed
  sweep gives seven of eight passing at 78.44 to 82.41 MHz, one more than the
  previous build, and the shipped seed 1 at 82.41 MHz is
  `tinymaps.e8242e81daf7.bin`.  Two of the pan tests had to move their starting
  origin to mid-level, because a rightward drag now walks the origin *down* and
  a test starting at zero was clamping instead of panning; a new test pins the
  keyboard's own direction so the two mappings cannot drift together.
- **Added last cycle - the cursor, the hand and zoom about the cursor.**  The
  mouse now drives a marker drawn over the picture: a green frame with no button
  down and a red crosshair while one is, taken from TinyCreature's scheme
  (`docs` there: a 16x16 green frame idle and a red crosshair held, changed on
  the button state rather than on movement).  `maps_link_rx` was latching the
  mouse's button byte and dropping it and now forwards the buttons plus a
  mouse-versus-keyboard flag; `maps_nav` tracks the cursor in output pixels,
  clamped to the screen, moves it on every report but pans the land only while
  the left button is held, and zooms about the cursor instead of the screen
  centre.  Two multiplies came with it (`s_diff * ptr_x`, `s_diff * ptr_y`), and
  each needed a clock of its own before timing would close: the step change is
  narrowed to seventeen bits and registered in a new `N_PIVOT` state, and the
  renderer's fetch-base `r_pf * level_w` is now `S_RADDR`.  That took seed 1 from
  65.79 to 73.91 MHz and the sweep to six of eight passing, 74.58 to 81.81, so
  this build has about seven megahertz less margin than the timing-only one and
  is again seed-sensitive at the low end.  Deployed as
  `tinymaps.f3aec678d40b.bin` at seed 7 (81.81 MHz) and the user reports the
  interaction right.  Free rotation is still out of scope: the row-based sampler
  cannot serve a diagonal output line.
- **Fixed last cycle - level crossings keep the centre.** Zooming in or out
  across the four levels used to walk the picture sideways, one jump at each
  boundary, and the cause was alignment: `maps_pack.py` cut each level on its
  own tile grid, so the four origins were 128 to 192 pixels apart while
  `maps_nav` crosses a level by doubling or halving the coordinates -- correct
  only when every level puts pixel (0,0) on the same ground point. The fabric
  cannot detect the mismatch because the level table it is given carries no
  origin, so the fix went into the pack: `levels()` takes the finest level's
  corner as the shared origin and crops every mosaic to begin there, adding a
  ring of tiles where cropping would leave a coarse level under 640 px -- the
  width a step-0.5 screen shows, which is where a crossing lands. The offsets
  are whole pixels of each coarse grid, so nothing is resampled. `verify` fails
  a pack whose origins disagree and `load_pack.py` refuses to send one, so the
  guarantee sits in mechanism rather than in a comment. The pack is now 27.62
  MiB (L0 4608x4608, L1 2304x2432, L2 1152x1216, L3 832x864) all sharing origin
  3857 (-12486753, 3966165); the crossing arithmetic checks out to under 0.001
  pixel at every level, and the user reports zooming in and out staying put. No
  RTL logic changed and no bitstream was rebuilt; the board still runs
  `df0b0e056c49`. The levels do not cover identical ground -- L3 spans 32 km
  against L0's 22 -- so panning to a coarse level's outer margin and zooming
  back in clamps at the finer level's edge, which is unavoidable given a 640 px
  minimum and a 576 px common rectangle at z12.
- **Fixed in the cycle before this - the first lines of every frame.** The corruption was
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
- **Timing margin fixed this cycle.** The eight-seed spread of 66.63 to 75.65 MHz
  with seven failures was a real defect, and the critical path said why:
  `maps_render.sv`'s `S_PLAN` computed the row pair from `r0` (32-bit add,
  compare, mux) and then the `pf_row * level_w` multiply and the fetch base in
  the same clock -- 13.22 ns of 13.47. A new `S_ROWS` state registers the row
  pair one cycle earlier, splitting the two operations across two clocks and
  costing one clock in 1650 per line. The same eight seeds now give 82.02 to
  92.67 MHz with all eight passing, so the worst placement anywhere has 7.8 MHz
  of margin and the design is no longer hostage to a seed. `check_render` still
  matches on all five viewports, so no pixel moved. Built as
  `tinymaps.d9e7bf60b5fe.bin` at seed 2 (92.67 MHz) but **not deployed**: the
  board was off USB entirely at the end of the cycle, so this and the pointer
  work should ship in one deploy.
- **Timing, measured properly last cycle.**  An eight-seed sweep of the design
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
- **Tile streaming:** designed and half-built, all of it in simulation and none of
  it in the top.  `tools/maps_pack.py tiles` writes 256-pixel tiles at 4bpp,
  `maps_tiles.sv` is the direct-mapped page table over a 16 MiB pool of 64 KiB
  tiles, `maps_tile_addr.sv` is the chunk arithmetic and `maps_tile_fetch.sv`
  walks one window of a row in chunks that stay inside a tile.  `maps_render.sv`
  can now take its entries from that sequencer instead of a linear address
  (`TILED`), and the tiled path is pixel-exact against the linear one in
  `sim/tb_maps_render_tiled.sv`.  `TILED` is off in `tinymaps_top`, so the build
  and the board behave exactly as before.  What is missing is the half that talks
  to the card: a request protocol to the BL616, the tile server on the TinyTang
  side, prefetch and eviction, and the coarse-level fallback that a miss needs
  because a missed row is not retried.  The request has a shape now:
  `maps_tile_req.sv` turns a miss into a `0xAA 00 06 1C L TXH TXL TYH TYL`
  frame on the link, deduped within its queue and holding the transmitter for
  the whole frame so the loader's answers cannot interleave with it.  The answer
  exists too: command `0x1D` carries one block of one tile, the loader writes it
  to the slot the page table derives and tells the table the tile is resident
  only when the block that ends it has passed its CRC and the write port has
  drained.  Both halves are in the top now, and the pool has a home: the pack
  ends at 27.62 MiB, so the pool takes the four megabytes above 28 as 64 slots of
  64 KiB, ending at the top of the part.  `TILES` is on, `maps_tiles` is
  instantiated, and a tile the host sends lands there and is committed -- but
  nothing looks a tile up yet, because the renderer still fetches linearly.
  The whole loop is proven in `sim/tb_maps_stream.sv`, which wires the renderer in
  tile mode, the sequencer, the table and the request queue to a model of the host
  and shows a miss becoming a request, an answer becoming a resident tile, and the
  line drawing the level's own pixels afterwards.  Doing that found a permanent
  stall: a missed fetch left the blocking path waiting for an acknowledgement that
  a miss never gives, so the line engine stopped for good; a retry timer now reasks
  after `TILE_RETRY` clocks.  The coarse fallback exists now, which was the other
  thing tiling needed: a line whose own level cannot answer is drawn from the
  level below, two output pixels per coarse pixel, and it sharpens when the tile
  arrives, on a `TILE_RETRY` epoch.  `TILED` is still off in the top -- turning it
  on is a command away: the sequencer, the page table and the request queue are
  instantiated in the top and the video channel is muxed between the renderer's
  linear fetch and the sequencer's chunk read, waiting on command `0x1E` from a
  host that can serve tiles.  The pack remains the default, so the bitstream
  behaves as it did until something says otherwise.  What is missing is the tile
  server on the TinyTang side, and there is a host-side one now:
  `tools/serve_tiles.py` answers the requests from an eight-bit tile pack over the
  same BL616 pipe, so a streaming test needs no firmware on the other side.
  `tools/maps_pack.py tiles --bits=8` builds that pack: 28.44 MiB for the ground
  the resident pack covers in 27.62, against a 4 MiB pool.  It has been on the
  board: the palette and the source switch were accepted, the core asked for
  `L3 0,0` onwards, and each 64 KiB tile took 0.32 s -- but the picture never
  finished, and the cause was the pool's hash.  `tx + 31*ty + level` with 31 equal
  to -1 modulo 64 made each screen row move the slot backwards by one, so the rows
  evicted each other and the pool livelocked.  The hash is thirteen now, which is
  coprime with the slot count; that build is not deployed yet.  Two smaller faults
  the same run exposed -- the fetch window running past the level's edge, and the
  request queue asking two or three times for a tile already on its way -- are
  recorded there and unfixed.  **Streaming now works on the board**: the
  remaining fault was that the runtime source switch stole the video channel from
  a linear fetch already in flight, which left the renderer waiting for a
  completion that could never come -- it drew nothing and asked for nothing.  A
  source change abandons the fetch now, and a level-3 view asked for its tiles,
  took them at 0.32 s each and drew, which the user passed.  The deployed image
  is `tinymaps.46ea1fa2bbf5.bin`.  Note the console is not always on
  `/dev/ttyACM0`: the Tang came back as `ttyACM2` once other boards were plugged
  in, and every tool takes `--port`.  Since then the fetch window stops at the
  level's edge, so the pool is no longer asked for tiles that cannot exist, and
  the fallback's window base follows the rows it actually received -- a miss
  changes the scale, and the base used to be latched before that could happen, so
  every fallback pixel came from thirty-three entries away.  Both are
  simulation-only: `sim/tb_maps_stream.sv` models the level's bounds now and
  counts any request outside the grid.  Then the board reported scattered wrong
  pixels and a smear on the first pan, and it was the fill: a slot's tag stayed
  valid for the whole 0.32 s a 64 KiB tile takes to arrive, so lookups for the
  previous tenant still hit and the renderer read a slot half old and half new.
  `fill_inval` now clears the slot when a fill begins, so a slot being written is
  a miss and the line falls back instead of drawing a tear.  That fix is built,
  testbenches and sweep clean, **not deployed**.  The same run also showed the
  pool is too small for the finest level: a z15 screen plus its fallback wants
  fifty-two of the sixty-four slots, and it livelocked on two tiles colliding in
  one slot.  Half-size tiles are the answer -- 4bpp gives 128 slots in the same
  4 MiB -- so that is the next thing that matters.  See
  `docs/streaming-scope.md`.

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
