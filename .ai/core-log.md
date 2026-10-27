## 1 COMMIT Unreleased 2026-10-26T01:47:30-07:00

#### Coming From:

Unreleased 79bd168

#### Purpose:

Establish a TinyMaps gateware skeleton that builds for the Tang Console 138K through the open flow, before any map data path exists.

#### Outcome:

Built `tinymaps_top`, a Phase 0 core carrying no map logic: the three TinyTang clocks (`sys_clk`, `clk` at 21.49 MHz, `hclk` at 74.25 MHz divided from `hclk5`), an HDMI 1280x720p60 output with silent audio, and a colour-bar test pattern registered off the HDMI pixel counters. The design tree is `fpga/tinymaps` with `hdmi/` and `pll/` taken from TinyTang's desktop core and the flow vendored to `tools/maps_open`, adapted from `tools/desktop_open` with only naming changes; the open flow synthesised, placed, routed, passed the setup-and-hold gate and packed `tinymaps.a3940692ccda.bin` (`tinymaps.88ce83e02fb0.fs`, 34,668,145 bytes) at placement seed 1, with `clk` at 341.53 MHz against 21.49 and `hclk` at 137.19 MHz against 74.25, and a clean rebuild from an empty `build/` reproduced both hashes bit for bit. Deployment and user test were deliberately deferred by the user's instruction, so neither ran and no bitstream has touched the board. Two findings matter for the next cycle. The inherited `tools/desktop_open/pnr_timing.py` cannot see a timing failure: nextpnr prints the final per-clock result as `Warning: Max frequency ... (FAIL ...)` and the tool's pattern was anchored on `Info:`, so it kept the earlier post-placement estimate and reported PASS while the post-routing route was violating; the copy in `tools/maps_open` matches both prefixes and takes the last report, which is the post-routing one, and it was confirmed to reject the 67.92 MHz route that the unfixed pattern had blessed. That also means TinyTang's own copy carries the same blind spot, latent there because its builds pass both analyses. Second, the first test pattern built a 24-bit colour from `cy[7:0]` across six `case` arms with a grid comparison on top, all out of the pixel counters into `rgb`'s register; that single stage took `hclk` to 67.92 MHz on seed 1 and 66.97 to 68.76 MHz across seeds 1 to 6, and replacing it with a constant colour moved the same netlist to 134.34 MHz, which isolated the pattern rather than the HDMI code as the cause. A bar-only pattern off `cx[9:7]` meets timing at 137.19 MHz. The renderer inherits that constraint: its output must arrive registered one shallow stage off `cx`/`cy`, not computed combinationally in a single cycle. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Phase 2 is the link loader: a fabric receiver speaking the `iosys_bl616` 0xAA frame protocol's bulk payload command (`0x07`) with TinyNES's load semantics, writing through the `sdram_nes` port, proven in testbench against a behavioural SDRAM model before any top-level wiring. Phase 0 remains unverified on hardware: nothing has been deployed, so the colour-bar pattern, the HDMI path and the clock topology are all still model-only claims.

#### Files Modified:

- .gitignore
- README.md
- fpga/tinymaps/build.tcl
- fpga/tinymaps/tinymaps.cst
- fpga/tinymaps/tinymaps.sdc
- fpga/tinymaps/tinymaps_top.sv
- fpga/tinymaps/hdmi/audio_clock_regeneration_packet.sv
- fpga/tinymaps/hdmi/audio_info_frame.sv
- fpga/tinymaps/hdmi/audio_sample_packet.sv
- fpga/tinymaps/hdmi/auxiliary_video_information_info_frame.sv
- fpga/tinymaps/hdmi/hdmi.sv
- fpga/tinymaps/hdmi/packet_assembler.sv
- fpga/tinymaps/hdmi/packet_picker.sv
- fpga/tinymaps/hdmi/serializer.sv
- fpga/tinymaps/hdmi/source_product_description_info_frame.sv
- fpga/tinymaps/hdmi/tmds_channel.sv
- fpga/tinymaps/pll/gowin_pll_27.v
- fpga/tinymaps/pll/gowin_pll_hdmi.v
- fpga/tinymaps/pll/gowin_pll_nes.v
- tools/build_maps_core_open.sh
- tools/maps_open/clock_constraints.py
- tools/maps_open/build.sh
- tools/maps_open/fs_to_bin.py
- tools/maps_open/pnr.sh
- tools/maps_open/pnr_timing.py
- tools/maps_open/synth.sh
- tools/maps_open/synth.ys

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 2 COMMIT Unreleased 2026-10-26T02:00:57-07:00

#### Coming From:

Unreleased 1e1de8f

#### Purpose:

Implement and prove the load receiver that will move a map pack over the BL616 link into the dock SDRAM, before any top-level wiring exists.

#### Outcome:

Added `fpga/tinymaps/maps_link_rx.sv`, a receiver for the `0xAA` frame protocol's command `0x07` payload that runs TinyNES's load semantics with the destination being an SDRAM byte address: a five-word little-endian header (magic `TML1`, address, length, image CRC-32, header CRC-32 over the first sixteen bytes) then 8 KiB blocks each with its own CRC-32, answered ACK `0x06` or NAK `0x15` plus a letter for header, block, image and timeout, with a NAKed block re-sent from its own start address. It writes through the `ahb_sdram` A25 write-port contract, assembling little-endian 64-bit words with all eight lanes asserted and a short tail with only its own lanes. `sim/tb_maps_link_rx.sv` drives the protocol at a realistic byte rate against a 4 MiB model that honours byte lanes and models the transmitter as busy per byte, and proves five things: a 20,000-byte image spanning three blocks lands byte for byte with every ACK accepted, a corrupted block CRC draws NAK `C` and the retry lands correctly, a corrupted header CRC draws NAK `H`, a corrupted image CRC draws NAK `I`, and no write-port overflows occur. `tools/run_sim.sh` builds and runs the testbenches under Verilator 5.032 and fails on anything but `RESULT: PASS`; the receiver is also added to `synth.ys` and `build.tcl` so the synthesis toolchain compiles it, and yosys drops it from the netlist while nothing instantiates it, leaving `tinymaps.88ce83e02fb0.fs` replaced by `tinymaps.015c224f8cfd.bin` (`tinymaps.305f5e3be61e.fs`) at seed 1, rebuilt from an empty `build/` to the same hash, with `clk` at 349.28 MHz against 21.49 and `hclk` at 149.28 against 74.25. The plan's assumption that `sdram_nes` would serve was wrong and is corrected here: that controller partitions its 32 MB into per-channel NES banks of 4 MB and cannot address a flat 28 MB pack, so `ahb_sdram` is the engine TinyMaps will vendor, and it is deferred to integration because the loader only needs to meet its write-port contract, which the testbench models directly. Four defects were found in the receiver by the testbench rather than by inspection: the address, length and image-CRC states folded the running header CRC once per clock instead of once per byte, the header CRC was not restarted per image so a second image inherited the first one's residue, a rejected block's re-sent bytes were folded into the image CRC twice, and the image CRC was compared against the complemented value the header carries. Deployment and user test did not apply: this cycle is simulation only and nothing was put on the board. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Phase 3 is the renderer: a per-level viewport with a rolling two-line buffer and a 256-entry palette, whose output must arrive registered one shallow stage off the HDMI pixel counters, since a combinational stage there was measured at 67.92 MHz against the 74.25 MHz the pixel clock needs. It needs the `ahb_sdram` engine vendored for the video read channel, which also settles how the loader and the renderer share the SDRAM.

#### Files Modified:

- README.md
- fpga/tinymaps/build.tcl
- fpga/tinymaps/maps_link_rx.sv
- sim/tb_maps_link_rx.sv
- tools/maps_open/synth.ys
- tools/run_sim.sh

#### Status:

- Build: PASS
- Deployment: N/A
- User Test: N/A

---

## 3 COMMIT Unreleased 2026-10-26T02:23:46-07:00

#### Coming From:

Unreleased 2e8ea8e

#### Purpose:

Add the renderer that draws a pack level into a 720p raster, verified pixel for pixel against an independent reference, and vendor the SDRAM engine it and the loader both need.

#### Outcome:

Added `fpga/tinymaps/maps_render.sv`, a nearest-neighbour renderer that draws one output line from one source row with the viewport expressed in the level's own Q16.16 pixel space; a row window is fetched into block RAM as 16-bit entries of two adjacent 8-bit pixels, and each output pixel costs one block RAM read and one 256-entry palette lookup. Vendored `ahb_sdram` from TinyNES as `fpga/tinymaps/sdram_ctrl.sv`, renamed only, which is the engine both the loader's write port and this renderer's source port are written against. `sim/tb_maps_render.sv` builds a 256x192 synthetic level in a 4 MiB source model, runs a shortened raster, and dumps every emitted pixel; `tools/check_render.py` recomputes the same cases from the parameters the testbench wrote out and compares them, and all three cases match exactly -- an integer pan at 1.000, magnification at 1.500, and magnification at 1.990, 3,072 pixels each across a 64x48 window. `tools/run_sim.sh` now runs that checker after the testbenches, and both testbenches pass together. The core builds at seed 1 to `tinymaps.4c7c8af281af.bin` with `clk` at 291.80 MHz against 21.49 and `hclk` at 140.94 against 74.25; the renderer and the SDRAM engine are in `synth.ys` and `build.tcl` so the synthesis toolchain compiles them, and yosys drops all three unwired modules from the netlist. The module is deliberately nearest-only and deliberately not real time, and both limits are stated in its header and in `README.md`: bilinear needs both source rows live with a previous-entry register on each, and real time needs the next line's fetch to overlap the current line's emit with source rows reused between output lines, since fetching a 1280-pixel window serially costs 1282 cycles against the 1650 pixel clocks a 720p line has. Three defects were found by the testbench: the vertical accumulator never reloaded from the viewport at a frame start, so every frame drew from row zero; the fetch engine re-issued its address while a read was still in flight, so data came back for a later entry than the one it was stored at; and the pixel latch sat one cycle behind the block RAM read, needing a delayed valid to line the two up. Deployment and user test did not apply: this cycle is simulation only and nothing was put on the board. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Bilinear resampling, then overlapping the next line's fetch with the current line's emit and reusing a source row across the output lines that map to it, which together are what make the renderer real time at 1280x720. After that the three finished modules need wiring into `tinymaps_top` against `sdram_ctrl`, which is the integration cycle and the first point at which anything here can be put on the board.

#### Files Modified:

- README.md
- fpga/tinymaps/build.tcl
- fpga/tinymaps/maps_render.sv
- fpga/tinymaps/sdram_ctrl.sv
- sim/tb_maps_render.sv
- tools/check_render.py
- tools/maps_open/synth.ys
- tools/run_sim.sh

#### Status:

- Build: PASS
- Deployment: N/A
- User Test: N/A

---

## 4 COMMIT Unreleased 2026-10-26T02:38:03-07:00

#### Coming From:

Unreleased dbcf8e1

#### Purpose:

Finish the renderer: add bilinear resampling and the prefetch-and-reuse machinery that real-time drawing at 1280x720 needs.

#### Outcome:

`maps_render` now resamples bilinear as well as nearest and keeps three row buffers so the row the next line needs is fetched while the current line is drawn; `ahb_sdram`'s handshake read port was replaced with a streaming one, since a per-entry handshake costs two cycles an entry and cannot fit a 1284-entry row into a 1650-clock line. `sim/tb_maps_render.sv` grew to five cases over the same 256x192 synthetic level -- nearest at 1.000 and 1.990, bilinear at 1.500, 1.750 and 0.750 -- and `tools/check_render.py` reproduces the renderer's rounding lerp exactly, so a match means the datapath agrees rather than that two implementations share a formula nobody checked; all five cases match pixel for pixel. A `fetch_count` output was added so the test reports whether row reuse actually engages: at `step_y` 1.000 it shows 50 fetches for 48 lines against 49 ideal, which means the rotation and the overlapped prefetch work, but at the other four steps it shows two fetches per line, which is correct output drawn through the blocking path with no overlap. Real-time operation is therefore NOT established, and the reason is specific: the rotation assumes the source row advances by at most one per output line, which holds only for `step_y` at or below 1, and above that a row can advance by two. The core builds at seed 1 to `tinymaps.3a6ab3805b75.bin` with `clk` at 413.22 MHz against 21.49 and `hclk` at 148.48 against 74.25. Five defects were found by the testbench. The blend function's intermediate product was evaluated at the eight-bit width of its return value, so every blend truncated to zero. The entry index was computed as `col>>1` while the byte-selection logic assumed the entry holding `col+1`. The window started at the first needed entry, leaving the first pixel of every line without a previous entry, which broke exactly eight pixels per line at one step. The previous-entry registers were reloaded every cycle rather than only when the entry index advanced, so they went stale whenever it stalled, which is every magnified pixel. And the blocking fetch never primed a third buffer, so the reuse could never start and every line re-fetched. Deployment and user test did not apply: this cycle is simulation only. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Make row reuse hold across the whole `step_y` range by handling a two-row advance at a line boundary, which is the one thing between the current renderer and real time at 1280x720; `fetch_count` is the instrument for it. Then integration: wire `maps_link_rx`, `maps_render` and `sdram_ctrl` into `tinymaps_top`, add the adapter between the renderer's streaming port and `ahb_sdram`'s video channel, and align the renderer's output with the HDMI pixel counters.

#### Files Modified:

- README.md
- fpga/tinymaps/maps_render.sv
- sim/tb_maps_render.sv
- tools/check_render.py

#### Status:

- Build: PASS
- Deployment: N/A
- User Test: N/A

---

## 5 COMMIT Unreleased 2026-10-26T02:48:17-07:00

#### Coming From:

Unreleased ad099df

#### Purpose:

Make row reuse engage across the renderer's whole magnifying range rather than only at one step.

#### Outcome:

One defect was behind the reuse failing outside a single step. The prefetch issued from the blocking path wrote its column tag as `(src_x0 >>> 17) - 1` where every other path wrote `k0_pf`; the two values coincide only when the viewport's first source column is odd, which happened to be true at the one step that reused, and elsewhere the tag never matched and every line fell back to fetching both rows. With that corrected, `fetch_count` reports 38 row fetches for 48 lines at `step_y` 0.750, fewer than one per line because a magnified line sometimes does not advance the source row at all, and 50 for 48 lines against 49 ideal at `step_y` 1.000. All five testbench cases still match the independent reference pixel for pixel, both testbenches pass, and the core still builds to `tinymaps.3a6ab3805b75.bin` at seed 1 with `clk` at 413.22 MHz against 21.49 and `hclk` at 148.48 against 74.25, the bitstream unchanged because nothing instantiates the renderer yet. The step range was also recorded wrongly in the previous entry and in `README.md` and is corrected here: `step` is source pixels per output pixel, so magnifying is a step below 1 and the level selector must hold it in `(0.5, 1]`. Above 1 a source row can advance by two per output line, consecutive line pairs share no row and no rotation is possible, which is why the 1.500, 1.750 and 1.990 cases fetch two rows per line; they draw correctly and are outside the operating range rather than broken. In range a line costs at most one SPAN fetch of 1284 entries at one entry per cycle, overlapped with the 1280 emits inside the 1650 clocks a 720p line has, so the real-time budget is met by construction; whether the SDRAM actually delivers a row inside those 1284 cycles is integration's question and is not measured. Deployment and user test did not apply: this cycle is simulation only. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Integration: wire `maps_link_rx`, `maps_render` and `sdram_ctrl` into `tinymaps_top`, write the adapter between the renderer's streaming row port and `ahb_sdram`'s video channel, align the renderer's output with the HDMI pixel counters so `out_rgb` is presented in the cycle `cx` names, and add the level-select rule that keeps `step` inside `(0.5, 1]`. That is the first cycle whose result can be put on the board.

#### Files Modified:

- README.md
- fpga/tinymaps/maps_render.sv

#### Status:

- Build: PASS
- Deployment: N/A
- User Test: N/A

---

## 6 COMMIT Unreleased 2026-10-26T03:56:50-07:00

#### Coming From:

Unreleased 2a32611

#### Purpose:

Integrate the three verified modules into `tinymaps_top` and commit the result with a handoff, so a later session can continue from the evidence rather than from scratch.

#### Outcome:

The integration is written: `maps_video_rd.sv` adapts the renderer's streaming row read to `sdram_ctrl`'s video channel, `maps_hdmi.sv` wraps the HDMI stage, the top carries all three modules with the SDRAM pin constraints and the four PLL and divider placement constraints taken from TinyTang's desktop core, `tinymaps.sdc` declares `fclk`, and `maps_render` exposes the palette index it resolves so the line store can be eight bits wide. It synthesises and it routes, and it does not close timing: `hclk` reaches 66.16 MHz against the 74.25 MHz a 720p line needs, so the gate refuses to pack and no bitstream exists. The failing path is the HDMI encoder's disparity accumulator at 14.48 ns, and comparison against TinyTang's desktop core built here on the same toolchain, at 110.67 MHz with the same `hdmi.sv`, localises the cause to synthesis rather than to the board or the toolchain: the TMDS serialiser cluster is 545 cells in this design against 261 there, and the critical path runs `video_data -> serialiser multiplexers -> acc` where the desktop's runs `video_data -> acc`. Nine levers were measured and rejected, recorded with their numbers in `docs/integration-blocker.md`: placement seeds 1 to 3, the PLL and divider sites, a live versus constant `hdmi` reset, single versus two clock domains, a distributed-RAM line store replaced by a synchronous block-RAM read, a registered rather than combinational `rgb`, `synth_gowin -abc9`, staged ABC at `-W 100`, and `-noflatten`. The commit is deliberately made with a bitstream gate that fails, against this project's usual rule that `main` builds, because the integration exists only in the working tree otherwise and the user asked for it committed for handoff; `docs/HANDOFF.md` records the state, the decisions that must not be re-litigated, and the single next action. Both existing testbenches still pass unchanged: `tb_maps_link_rx` on all five cases and `tb_maps_render` with `check_render` matching all five viewports pixel for pixel, so the failure is confined to the integrated top and not to the modules it joins. Nothing was deployed and no user test applies. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Put a register between `q_m` and the disparity accumulator in `fpga/tinymaps/hdmi/tmds_channel.sv`, which shortens the encoder's path regardless of how ABC factors the netlist, and build a simulation harness that compares the encoder's output before and after that change, since it costs one clock of latency and HDMI pixel alignment is load-bearing here. Separately, the pack loader is still unwired: `sdram_ctrl`'s write port is idle and the viewport registers are constants.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- docs/integration-blocker.md
- fpga/tinymaps/build.tcl
- fpga/tinymaps/maps_hdmi.sv
- fpga/tinymaps/maps_render.sv
- fpga/tinymaps/maps_video_rd.sv
- fpga/tinymaps/tinymaps.cst
- fpga/tinymaps/tinymaps.sdc
- fpga/tinymaps/tinymaps_top.sv
- tools/maps_open/synth.ys

#### Status:

- Build: FAIL
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 7 COMMIT Unreleased 2026-10-26T09:37:00-07:00

#### Coming From:

Unreleased 32a8219

#### Purpose:

Close the pixel clock by pipelining the HDMI encoder, and prove the pipelining does not change a single coded word.

#### Outcome:

`fpga/tinymaps/hdmi/tmds_channel.sv` gained one pipeline register between the first half of HDMI 1.4a section 5.4.4.1 and the disparity decision: the coded byte `q_m` is registered together with `mode`, `control_data` and `data_island_data`, and `N1q_m07`/`N0q_m07`, the accumulator branch and the accumulator reset are all taken from the registered values. All five signals are delayed together on purpose, because the guard bands and control periods are keyed off the same mode the data was coded under and delaying the video alone would shift the picture one pixel against its own sync. A new `sim/tb_hdmi_encode.sv` drives the three channels through every coding mode -- all 256 input bytes four times over, every control word, all sixteen TERC4 symbols, both guard bands and 2000 cycles of interleaved pseudo-random mode, pixel, island and control words -- and dumps the 10-bit word per channel per pixel clock, and `tools/check_tmds.py` recomputes that stream from the coding tables and discovers the output delay by alignment instead of assuming it. The capture taken before the change matches the model over all 3132 rows at a delay of zero; the capture taken after matches over 3131 rows at a delay of one; and the two captures are identical row for row once the one-pixel offset is compensated, so the encoder emits exactly the words it emitted before, one clock later. The core builds at placement seed 1 to `tinymaps.46bc5de68231.bin` (`tinymaps.46f5c35cbda5.fs`, 4,399,798 and 35,221,304 bytes) with `hclk` at 84.28 MHz against 74.25 and `clk` at 428.08 against 21.49, setup=0 and hold=0, and a rebuild from an empty `build/` reproduced both hashes. The critical path left the encoder entirely: it is now 11.87 ns in the renderer's line buffer, leaving 1.6 ns inside a 74.25 MHz period, and the post-placement `hclk` estimate of 76.93 MHz was improved on by routing rather than eroded. The pipelining was the route the blocker record had already reduced to, after nine levers failed to make ABC stop merging the serialiser's multiplexers into the disparity path; a register between `q_m` and the accumulator cuts that merged cone at a flop, which ABC cannot retime across. One thing was found and deliberately not changed: comparing the encoder against a transcription of Figure 5-7 showed the balanced-disparity branch pairs `q_m[8]` with the uncomplemented byte where the transcription pairs it with the complemented one, and both pairings keep the accumulator tracking the true disparity and produce decodable words, so it is a DC-balance convention rather than a visible defect. The vendored file is byte-identical to upstream `hdl-util/hdmi` at `src/tmds_channel.sv` on master, so the convention is upstream's, and settling which pairing the standard mandates needs the specification text that `core-reference.md` does not carry; it is recorded as an open question in `docs/integration-blocker.md` and the checker reproduces the module's convention rather than asserting conformance. All three testbenches pass: `tb_maps_link_rx`, `tb_maps_render` with `check_render` matching all five viewports pixel for pixel, and `tb_hdmi_encode` with `check_tmds`. Deployment and user test did not run because this cycle was scoped to the build with deployment deferred by the user's instruction, so no bitstream has touched the board and the integrated design remains unverified on hardware. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Wire the pack loader: `sdram_ctrl`'s A25 write port is idle and the viewport registers in `tinymaps_top.sv` are constants, so the SDRAM holds nothing and the picture is the default palette over empty memory. That needs a UART receiver and the `0xAA` frame parser in front of the finished `maps_link_rx`, the loader writing through the idle write port, and an arbitration rule for how the loader and the renderer share the SDRAM. Then a level selector that keeps `step` inside `(0.5, 1]`, and a decision from the user on whether the packed bitstream should be deployed.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- docs/integration-blocker.md
- fpga/tinymaps/hdmi/tmds_channel.sv
- sim/tb_hdmi_encode.sv
- tools/check_tmds.py
- tools/run_sim.sh

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 8 COMMIT Unreleased 2026-10-26T09:47:51-07:00

#### Coming From:

Unreleased 1342a0e

#### Purpose:

Deploy the packed bitstream to the Tang and have it tested on hardware, which entry 7 left undone.

#### Outcome:

The bitstream from entry 7 was put on the Tang's SD card with TinyTang's `tangput` at `/root/cores/console138k/tinymaps.bin`, 4,399,798 bytes, the same `sha256 46bc5de68231` that names it, and the size was read back from the card before programming. `tangload /root/cores/console138k/tinymaps.bin` from the board's shell reported `ID=0001081b`, an erase poll that came back OK, `Load SRAM` and `tangload: core loaded`; after the user power cycled the board the image survived on the card and a second `tangload` produced the same sequence, so the deployment is repeatable and the load is volatile, a power cycle returning the console core without anything on the card having been overwritten. The shell's `fpga` command reports no answer on UART1 at 2000000 baud, which is expected rather than a fault: `maps_link_rx` is not instantiated and the top has no UART responder, so the link cannot answer yet. The user reports a locked, synced, still image of noise static and judges it working, and that is exactly what this design draws with no pack loaded, a palette lookup over SDRAM that holds nothing, so the frame being stable rather than flickering is the meaningful part of the result. HDMI locking 1280x720p60, the PLL and divider topology, and `hclk` closing at 74.25 MHz on silicon are now hardware-confirmed rather than model claims. What is not confirmed is anything past the palette: no known image has been sent through the renderer's line buffers, so the noise proves the path runs and stays stable, not that it indexes correctly. No build ran in this cycle; the image deployed is the artefact entry 7 built and verified, uploaded hash for hash, so the build stage belongs to that entry and passed there. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Wire the pack loader, which is now also the only way to prove the picture path: a UART receiver and the `0xAA` frame parser in front of the finished `maps_link_rx`, the loader writing through `sdram_ctrl`'s idle A25 write port, and an arbitration rule for how the loader and the renderer share the SDRAM. Send a known pack through it and compare the screen against the pack's own preview, then add the level selector that keeps `step` inside `(0.5, 1]` and measure whether the SDRAM delivers a 1284-entry row inside a 1650-clock line with real data.

#### Files Modified:

- README.md
- docs/HANDOFF.md

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 9 COMMIT Unreleased 2026-10-26T10:17:01-07:00

#### Coming From:

Unreleased 1595480

#### Purpose:

Wire the pack loader so a known image can be sent over the BL616 link and the renderer's output checked against it.

#### Outcome:

Added `fpga/tinymaps/maps_uart_rx.sv` and `fpga/tinymaps/maps_uart_tx.sv`, an 8N1 pair for the link's 2 Mbaud at `hclk`, sampled from a 16x fractional baud tick so the two frequencies divide exactly; `tinymaps_top.sv` now instantiates both with `maps_link_rx` behind them, taking the receiver's bytes and returning the loader's ACK or NAK, and `maps_link_rx`'s write port drives `sdram_ctrl`'s A25 port, which the renderer never touches because the controller arbitrates between that port and the video line and gives the video priority. The receiver parses the link's `0xAA len_hi len_lo 0x07 payload` frames itself, so no separate frame parser exists to fall out of step with it. The UART pins are V14 and U15, the same ones TinyTang's desktop core uses. `sim/tb_maps_uart.sv` drives the receiver's pin with a bit-level sender whose every edge is placed at its ideal time plus up to 40 ns of bounded jitter, recovers 256 bytes exactly, proves a byte with a low stop bit is dropped and the line recovers for the byte after it, and then sends the same 256 bytes out through the transmitter and back in through the receiver, so the transmitter is judged by a receiver whose reading of the wire was established against an independent sender; it passes under Verilator and iverilog. Two host tools were added: `tools/maps_test_image.py` writes a 768x768 eight-bit raster that is a 12 by 12 grid of flat cells stepping from 255 at the top left to 0 at the bottom right inside a four-pixel white border, and `tools/load_image.py` asks the board whether its console is at a shell prompt, opens `fpgapipe`, and sends the `TML1` header and 8192-byte blocks with their CRC-32s, framing every payload byte and waiting for each answer exactly as the module's protocol defines; its framing was checked byte for byte against the sequence `tb_maps_link_rx` drives, which the RTL already accepts. The viewport constants were pointed at that image: a 768x768 level at SDRAM byte 0 with a step of 39322, 0.600006 source pixels per output pixel, which is inside the (0.5, 1] the renderer needs and fills the 1280-pixel line exactly. The core builds at placement seed 1 to `tinymaps.8fe42ba24d8d.bin` (`tinymaps.ea8a7368d345.fs`, 4,381,164 and 35,071,973 bytes) with `hclk` at 83.06 MHz against 74.25 and `clk` at 426.26 against 21.49, setup=0 and hold=0, and a rebuild from an empty `build/` reproduced both hashes; the post-placement `hclk` estimate of 61.79 MHz failed and routing brought it to 83.06, which is why the gate reads the post-route report. Every testbench passes: `tb_maps_link_rx`, `tb_maps_render` with `check_render` matching all five viewports, `tb_hdmi_encode` with `check_tmds`, and the new `tb_maps_uart`. Two things are knowingly incomplete and recorded in `README.md` and `docs/HANDOFF.md`: the loader has no idle timeout, its `TIMEOUT` parameter being unused, and the palette is still the fabric grey ramp, so a loaded image would appear in grey rather than in the pack's own colours. Deployment and user test did not run because the user asked for the bitstream to be built and verified but held back from the board, so this build has never run on hardware and the loader remains unproven there. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Put `tinymaps.8fe42ba24d8d.bin` on the card with TinyTang's `tangput`, `tangload` it, and run `tools/load_image.py work/test/test-image.bin`: the screen should become the 12 by 12 staircase in grey, which would be the first known image through the renderer and the first exercise of the loader and its UART pins on hardware. If that arrives, replace the fabric grey ramp with the pack's own 256-entry palette, which means deciding how the loader supplies it, and then add the level selector that holds `step` inside `(0.5, 1]` across the pack's four levels.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/build.tcl
- fpga/tinymaps/maps_uart_rx.sv
- fpga/tinymaps/maps_uart_tx.sv
- fpga/tinymaps/tinymaps.cst
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_uart.sv
- tools/load_image.py
- tools/maps_open/synth.ys
- tools/maps_test_image.py

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 10 COMMIT Unreleased 2026-10-26T10:31:50-07:00

#### Coming From:

Unreleased 876ade7

#### Purpose:

Put the loader build on the Tang and load a known image, which is the only way to establish that the renderer draws what the loader wrote.

#### Outcome:

`tinymaps.8fe42ba24d8d.bin` was uploaded to `/root/cores/console138k/tinymaps.bin` with TinyTang's `tangput` and programmed with `tangload`, which reported `ID=0001081b` and `Load SRAM`. `tools/load_image.py` then took the console through its prompt probe and `fpgapipe`, was answered ACK for the header, and sent 589,824 bytes in 3.1 s at 190 kB/s with every one of the 72 blocks answered on its first attempt; the loader checks the whole image against the header's CRC-32 and NAKs `'I'` on a mismatch, and did not, so the SDRAM held exactly the bytes that were sent. The user reports the screen shows the staircase with a white strip at the left and right edges and that the rest looks right, and the strips are not a fault: they are the test image's own four-pixel border, which is meant to mark the level's extent and is magnified to about seven pixels at 0.6 source pixels per output pixel. Measuring the capture confirms the picture quantitatively: twelve columns at a 106.7-pixel pitch, seven cell rows visible before the level is cropped at the bottom (720 output rows at 0.6 reach source row 432 of 768), a four-pixel strip at the left edge and six at the right, and values stepping monotonically from 255 at the top left to 111 at the bottom of the frame, so the loader, both UARTs, the frame parser, the block and image CRCs, the A25 write port and the renderer's addressing all agree on the one thing they were for. One finding is recorded for the next cycle rather than fixed here: the capture shows the indices lifted and clipped, with 236 arriving as 255 and 107 as 111, which is the shape of a limited-range RGB interpretation downstream, and the AVI info packet leaves `RGB_QUANTIZATION_RANGE` at its default of `2'b00`. That matters more for the pack's palette than for a grey ramp, because it compresses the top of the range and would wash out the brightest map colours. Deployment and user test therefore both ran and both passed, and no build ran in this cycle because the image deployed is the artefact entry 9 built and reproduced from an empty tree. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Two decisions stand between this and a real map. First, declare `RGB_QUANTIZATION_RANGE = 2'b01` in the AVI info frame so the sink stops reading full-range RGB as limited range, which is an edit to the vendored `hdmi.sv` and so needs its departure from upstream recorded; verify it by reloading the test image and measuring the capture again, where index 236 should arrive as 236. Second, replace the fabric grey ramp with the pack's own 256 entries, which needs a decision on how the loader supplies them — a palette command on the link, a second loader pass over the pack's palette section, or a region of SDRAM the renderer reads. Then a level selector that holds `step` inside `(0.5, 1]` across the pack's four levels, and a load of the full 28 MB pack, which at 190 kB/s is about two and a half minutes and has never been tried.

#### Files Modified:

- README.md
- docs/HANDOFF.md

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 11 COMMIT Unreleased 2026-10-26T10:37:15-07:00

#### Coming From:

Unreleased 2f29ebd

#### Purpose:

Declare full-range RGB in the AVI InfoFrame, which is the cause the first hardware capture pointed at, and land it on its own before any palette work.

#### Outcome:

`RGB_QUANTIZATION_RANGE` is now `2'b01` in the AVI InfoFrame the core emits. The field is carried as a parameter through `packet_picker.sv` and `hdmi.sv`, both of which keep their upstream default of `2'b00`, and set to full range in `maps_hdmi.sv`, which is this project's wrapper and the right place for the decision; the new `sim/tb_avi_range.sv` instantiates the packet module both ways and checks it by byte, which caught nothing in the RTL but did catch two mistakes in the test itself, a checksum read at time zero and a comparison that expected the checksum byte to stay put while the packet changed. Byte 3 now reads `1000_0100`: IT content set, extended colorimetry clear, quantization range `01`, non-uniform scaling clear, and both packets sum to zero over their fourteen payload bytes and three header bytes. The core builds at placement seed 1 to `tinymaps.a54a650eae81.bin` (`tinymaps.b6617c41c4a9.fs`, 35,326,437 bytes for the `.fs`) with `hclk` at 89.45 MHz against 74.25 and `clk` at 470.15 against 21.49, setup=0 and hold=0. Every testbench passes: `tb_avi_range`, `tb_maps_uart`, `tb_maps_link_rx`, `tb_maps_render` with `check_render` matching all five viewports, and `tb_hdmi_encode` with `check_tmds`. Deployment did not run: the Tang is not connected to this machine, `/dev/ttyACM0` is absent, so `tangput` could not open the port and nothing was sent to the board. That leaves the change unverified on hardware, and until it is measured the lift and clip remain the last observed behaviour of the picture: the prediction is that index 236 arrives as 236 rather than 255, and the way to test it is to reload `work/test/test-image.bin` after programming this build and measure a capture the way the previous one was measured. The vendored HDMI tree now carries two deliberate departures from upstream, the `tmds_channel` pipeline and this parameter, and both are recorded in `README.md`, the second with its default left alone so the modules still behave upstream's way for anyone else. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Deploy `tinymaps.a54a650eae81.bin` when the board is connected, reload `work/test/test-image.bin`, and measure a capture: index 236 should read 236 and the staircase should show its full range instead of saturating to white above about 235. If that holds, the pack's palette is the last piece before a real map, and it needs a decision on how the loader supplies 256 entries, since the fabric ramp is initialised by the top and has no second writer today. After that, a level selector that holds `step` inside `(0.5, 1]` across the pack's four levels, and the first load of the full 28 MB pack.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/hdmi/hdmi.sv
- fpga/tinymaps/hdmi/packet_picker.sv
- fpga/tinymaps/maps_hdmi.sv
- sim/tb_avi_range.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 12 COMMIT Unreleased 2026-10-26T10:40:57-07:00

#### Coming From:

Unreleased 2c88e61

#### Purpose:

Put the full-range AVI build on the board and measure whether the picture's lifted levels changed.

#### Outcome:

`tinymaps.a54a650eae81.bin` was uploaded with `tangput` at 4,412,908 bytes and programmed with `tangload`, which reported `ID=0001081b` and `Load SRAM`, and `tools/load_image.py` then wrote the 589,824-byte test image in 3.1 s at 190 kB/s with every block accepted on its first attempt and the image CRC good. The user reports the picture looks good and passes it. The measurement does not corroborate the change, and that is the finding worth recording: a capture of this build is pixel-identical to a capture of the previous one apart from 48 pixels in an eight-by-eight patch at the top of the frame, which is a cursor, so the levels still arrive lifted, with index 236 reading 255 and everything above about 235 clipped exactly as before. The declaration is therefore in the packet and correct -- `tb_avi_range` shows byte 3 as `1000_0100` -- but it does not change what this capture path produces, which means either the sink ignores the quantization field or the capture device applies its own limited-to-full expansion whatever the source declares. The second is more likely: the data islands are unconditional in `hdmi.sv`, whose `num_packets_alongside` comes from the blanking budget rather than from the picker, so the AVI frame is being sent. What follows is that a capture of this board is a reliable measure of geometry and of relative brightness but not of absolute levels, and that the palette should be designed against the display rather than against a capture; the user's own judgement of the display is the only evidence available for the top of the range. Deployment and user test both ran and both passed; no build ran in this cycle because the image deployed is the artefact entry 11 built. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The pack's palette, which is the last thing between this and a real map: the renderer's palette is initialised by the top and has no second writer, so supplying 256 entries needs a decision -- a palette command on the link that `maps_link_rx` does not parse today, a second pass over the pack's palette section, or a region of SDRAM the renderer reads instead of a fabric table. Then a level selector that holds `step` inside `(0.5, 1]` across the pack's four levels, and the first load of the full 28 MB pack, which at 190 kB/s is about two and a half minutes and has never been attempted.

#### Files Modified:

- README.md
- docs/HANDOFF.md

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 13 COMMIT Unreleased 2026-10-26T11:01:16-07:00

#### Coming From:

Unreleased 43a0f4d

#### Purpose:

Give the pixel path the pack's own palette over the link, so the core can draw a real map instead of a grey ramp.

#### Outcome:

`maps_link_rx` now parses command `0x08` alongside the image load: a payload of `u16 start`, `u16 count`, `count` triples of RGB and a CRC-32 over the bytes before it, answered ACK or NAK `'P'`, with entries written into the palette as their third byte arrives. `tinymaps_top.sv` gives the fabric's power-on grey ramp and the link one write port to that table, the ramp having finished inside 512 clocks long before a host could send anything. `sim/tb_maps_palette.sv` covers a four-entry palette at a non-zero start, a full 256-entry table and a corrupted CRC refused with NAK `'P'`, with the CRCs computed by zlib rather than by the module's own function so the polynomial is checked rather than agreed with, and the synthesised netlist was simulated against the RTL for the same frame to rule out a synthesis difference. The host side is `tools/load_palette.py`, and `tools/maps_pack.py extract <pack> <level>` pulls a level's raster out for `tools/load_image.py`, so a real map is three commands. Bringing it up found a host defect rather than a hardware one: `load_image.py`'s `frame()` hardcoded command `0x07`, so `load_palette.py` was handing the palette to the image loader, which sat hunting for a `TML1` magic that never came and answered nothing, while the testbench passed because it sends the command byte itself; `frame()` now takes the command. On the Tang the palette was accepted for all 256 entries and the screen shows the Phoenix z12 level in its own colours, which the user reports looks good. That also exposed a new defect: measuring the capture against the level rendered with the renderer's own arithmetic, rows 0 to 4 of the frame are wrong, with 30 to 49 percent of their pixels off by more than 60 counts, while row 5 and below match their expected rows at correlation 0.70 to 0.91, and row 1 carries what row 0 should show, so the first lines are drawn from stale or half-updated row buffers at the frame wrap and the picture settles by the fifth line. The render testbench never crosses a frame boundary, running 48 lines from line 0, which is why this could not be caught before hardware. Build passes at placement seed 1 to `tinymaps.6fb7d4f7a2cc.bin` with `hclk` at 84.84 MHz against 74.25 and `clk` at 356.00 against 21.49, setup=0 and hold=0, and every testbench passes. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Fix the frame-start artifact: add a case to `sim/tb_maps_render.sv` that runs a full 750-line frame and wraps to line 0, which will fail today, then make the renderer flush its row rotation when the source row goes backwards instead of trusting the buffer tags. Then a level selector that holds `step` inside `(0.5, 1]` across the pack's four levels, and the first load of the full 28 MB pack, which at 190 kB/s is about two and a half minutes.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_palette.sv
- tools/load_image.py
- tools/load_palette.py
- tools/maps_pack.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 14 COMMIT Unreleased 2026-10-26T11:19:41-07:00

#### Coming From:

Unreleased ed8ebb3

#### Purpose:

Fix the top rows of each frame, which the previous cycle's capture showed were being read before the renderer had written them.

#### Outcome:

Measuring the capture against the level rendered with the renderer's own arithmetic localised the fault: raster line 0 carried the previous frame's last line (correlation 0.809 with the expected line 718), line 1 carried line 0, and lines 2 to 4 matched no line of the frame at all, while line 5 and below matched their own lines at correlation 0.70 to 0.91. The renderer was being asked for line 0 only on the last raster line of the frame, which left it one line period of 1650 clocks for a line it cannot draw from the rows it holds, because the source row jumps from the bottom of the level back to zero: two row fetches at roughly 700 clocks each plus 1280 emits is about 2680. It now receives `rc_cy` of 0 for the whole vertical blanking, in `tinymaps_top.sv`, which is 30 lines and covers the one discontinuity a frame has. Measured on the next capture, line 0 became correct: correlation 0.936 with the expected line and 5.2 percent of pixels off, against 41.9 percent before. Lines 1 to 4 did not improve, at 37 to 52 percent off and matching no line, and a second build that also asked for line 1 during the blanking made line 0 wrong again (correlation 0.809 with line 718), so one line of head start is all the two-slot line store allows; that build was reverted and the revert reproduced the previous bitstream hash exactly. A frame-start testbench was written, `sim/tb_maps_frame.sv`, with the line store and pixel read from the top and a video-channel fetch model, and it was abandoned rather than committed: it reproduces a frame-start failure, but its comparison of one frame against the next cannot catch a fault that repeats identically every frame, which is what this one does, and building a correct reference for it is more work than the issue has earned so far. A wrap case was added to `sim/tb_maps_render.sv` and does pass, but with 64-pixel lines it has no timing pressure and cannot see this. The build is `tinymaps.e0c154b34546.bin` at placement seed 1 with `hclk` at 93.65 MHz against 74.25, setup=0 and hold=0, deployed with the L3 level and the pack palette, and the user reports the picture still glitches at the top and asks for it to be logged and left for now. The issue is written into `README.md` and `docs/HANDOFF.md` with the measurements and with what is ruled out: the head start, the store's depth, and one abandoned model. Every testbench passes. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The frame-start issue needs an instrument rather than more simulation: a per-line counter of how late the renderer is, read back over the link the way the palette command reads, would show whether lines 1 to 4 are drawn late, drawn from the wrong rows, or drawn and then overwritten. Otherwise the level selector that holds `step` inside `(0.5, 1]` across the pack's four levels, and the first load of the full 28 MB pack, which at 190 kB/s is about two and a half minutes.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_render.sv

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 15 COMMIT Unreleased 2026-10-26T11:45:50-07:00

#### Coming From:

Unreleased 8aab508

#### Purpose:

Give the core a level selector, so the pack's four levels can be shown and switched between with the step the renderer needs.

#### Outcome:

`maps_link_rx` parses command `0x0A`, a whole viewport: the level's SDRAM byte address, its width and height, the Q16.16 step, and the Q16.16 origin, with a CRC-32 over the twenty bytes before it. The range guard is in the fabric: `0.5 < step <= 1`, a level that is not empty, and a level that fits in the SDRAM, with nothing latched on a refusal and NAK `'V'` as the answer, or NAK `'C'` for a bad CRC. That range is the renderer's real operating limit -- above 1 a source row can advance by two per line and the row rotation cannot engage -- so it is enforced where it cannot be bypassed rather than trusted from the host. `tinymaps_top.sv`'s viewport constants became registers driven by the command. Written first as one combinational expression, the guard's 16x16 multiply and 32-bit add took `hclk` from 93.65 MHz to 56.92 MHz and the flow refused to pack; registering the product and the verdict in two stages brought it to 96.27 MHz, and the guard still decides correctly because the payload's bytes settle four clocks before the CRC does. `sim/tb_maps_view.sv` sends four viewports and checks one acceptance and three refusals, including that nothing latches when a command is refused; the CRCs there are computed by zlib, and it caught two mistakes of mine in the test data rather than in the RTL -- a level at `0x01f00000` that actually does fit in 32 MiB, and word assembly that was one byte short. The host side is `tools/load_pack.py`, which sends the palette and any subset of levels, and `tools/set_view.py`, which computes the viewport from the pack's level table, choosing a step of 1.0 or, for a level narrower than the screen, enough magnification to fill it. On the Tang the whole 28 MiB pack loaded in two minutes thirty-three seconds with every block ACKed and every level's image CRC accepted, and selecting level 3 moved the picture to the centred view in one command with no reload, which the user reports as perfect on the HDMI monitor. Two things came out of that session. A `tangload` that printed `core loaded` left the core answering nothing on either command until it was programmed again, so the message is not proof that the design is running and the link should be probed after a load. And the user switched from the capture card to the HDMI monitor and saw the same corruption at the top of the frame, which settles that the frame-start issue is in the core rather than in the capture path; it is recorded as the next thing to fix, with a per-line lateness counter read back over the link as the instrument. Every testbench passes and the user passes this cycle. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The frame-start issue: an HDMI monitor shows it with no capture in the path, so it is the core. Add a per-line counter of how late the renderer is, read back over the link the way the palette and viewport commands read, which will separate a line drawn late from a line drawn from the wrong rows from a line drawn and then overwritten. After that, pan and zoom as controls the core reads itself rather than the host re-sending a viewport, and the renderer's real-time behaviour under pan, which has never been exercised.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_view.sv
- tools/load_pack.py
- tools/set_view.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 16 COMMIT Unreleased 2026-10-26T11:55:13-07:00

#### Coming From:

Unreleased ad2974a

#### Purpose:

Let the board's Bluetooth mouse and keyboard pan and zoom the map, which is the first input the core has ever taken from them.

#### Outcome:

The link now carries three more commands. `0x16` is the board's mouse, six bytes as its own desk task sends them -- two of frame number, the buttons, then dx, dy and wheel -- and each report is turned into an output-pixel pan and a zoom direction. `0x17` is the keyboard in the HID boot layout, arrows panning 64 pixels and `=` and `-` zooming; a boot keyboard reports state rather than events, so a held key is one report and the keys do not repeat, which is honest rather than a defect. Neither is answered, because the desk task sends them at a poll rate and a reply per frame would be traffic nobody reads. `0x0B` carries the level table, a count and then each level's SDRAM address, width and height with a CRC, so the core can cross levels on its own. `maps_nav.sv` does the arithmetic: panning moves the origin by whole 8-pixel nudges and keeps the remainder for the next report, zooming walks five steps between 0.5 and 1.0 a quarter of an octave apart and keeps the centre of the screen on the same ground point, and running off either end of that table steps to the next level, where a factor of two in metres per pixel makes the crossing a doubling or halving of the source coordinates. Nothing in it multiplies two variables -- the step table is constant and half a line, a line, half a screen and a whole screen are shift-and-add of the step -- and the level and table position are recovered from the base and step by comparison, so a viewport the host set at any step zooms from where it is. Three defects were found by `sim/tb_maps_nav.sv` before any hardware: the bound on the origin went negative when the level was narrower than the screen, which let the origin go negative and read before the level; and the pan remainder survived a host viewport command, so an old remainder could move a freshly set view, which `maps_nav` now clears on the same pulse that latches a viewport. The testbench checks properties rather than restating the arithmetic -- a 32-pixel pan moving exactly 32 steps, both clamps, the centre held through one step, both crossings doubling or halving the origin and landing on the neighbouring level's base, and both end stops -- and it passes. `tools/set_levels.py` sends the table from the pack. The core builds at placement seed 1 to `tinymaps.eaea3e4132d1.bin` with `hclk` at 91.44 MHz against 74.25 and `clk` at 413.74 against 21.49, setup=0 and hold=0, and every testbench passes. Deployment did not run: the Tang was disconnected before the build finished, so nothing here has been on hardware and neither the mouse nor the keyboard path has ever carried a real report -- the frame layouts are taken from the BL616's own sender and nothing else. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Deploy `tinymaps.eaea3e4132d1.bin` when the Tang is back, load the pack, send the level table, and try the mouse and keyboard: the wheel should zoom through five steps and then cross a level, the mouse should pan with the remainder carried between reports, and the arrows and `+`/`-` should do the same from the keyboard. The frame-start issue is still open and will show while panning; the user's instruction is to look at it again after pan and zoom are real.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/build.tcl
- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/maps_nav.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_nav.sv
- tools/maps_open/synth.ys
- tools/set_levels.py

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---


## 17 COMMIT Unreleased 2026-10-26T14:06:39-07:00

#### Coming From:

Unreleased 40c02b2

#### Purpose:

Make pan and zoom usable, after the first hardware attempt turned the picture into a vertical smear.

#### Outcome:

The smear was diagnosed from a capture in which all 720 rows were identical, one distinct row and zero row-to-row difference: the renderer was drawing a single source row for every line, which is what a level width of zero does, because every row address becomes `base + row*0`. Two defects in the level table were behind it, and neither was in the navigation. The table's outputs were declared as registers and never assigned, so the core held zeros, and a pan was the first thing to read them; and once connected, the sixteen-bit width and height were being taken from a word that had only shifted twice, which put the width in the height. Both are fixed, the table's fields are now assembled from named byte registers, and the pan is exact by measurement rather than by eye: thirty-two mouse counts move the origin 19.2 source pixels at a step of 0.6. Two composition changes came with it and both are load-bearing. Viewport writes, from the host or from the navigation, now go to a shadow that is swapped in at the top of the vertical blanking, because a viewport change costs the renderer a blocking refetch of two rows, about 2680 clocks against the 1650 a line has, and applying one mid-frame tore the picture. And the renderer's blocking path now waits for its third row before it draws: the priming fetch was issued and left running while the line drew, and a row fetch of about 1340 clocks against a 1280-clock emit finished roughly sixty clocks too late, so the next line blocked too and the cascade ran for four lines, which is the corruption at the top of every frame. The instrument that found all of this is new: command `0x0C` answers with twenty-one raw bytes, the level address, size, step, origin and the line engine's state, and `tools/read_status.py` prints them. It is the first time a fault in this project was located by reading the core's own state rather than by inferring it from a picture, and it found both table defects in two reads. It has a known bug of its own, recorded: the top byte of a level base above 16 MB reads wrong, so level 3 reports `0xb7b703d8` where the truth is `0x01b703d8`, and the other fields are correct. Two host-side findings came from the same session: `fpgapipe` fails if it is opened within a few seconds of the previous session closing, and the BL616 suppresses the desk layer's input frames while a host owns the pipe, so a mouse test run during a pack load never reaches the core. The core builds at placement seed 1 to `tinymaps.949683069dfd.bin` with `hclk` at 86.20 MHz against 74.25, setup=0 and hold=0, every testbench passes, and after the final load the user reports that panning and zoom work. The top of the frame has not been confirmed separately, though the same fix addresses the mechanism that caused it. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Confirm the top of the frame on hardware now that the refetch no longer races, and fix the status command's top byte so the readback can be trusted for level 3. Then the natural next cycle is the feel of panning and zooming rather than its correctness: the view updates once per frame because a viewport change costs a refetch, so smoothing it means either fetching only the entries a pan newly needs or giving the renderer a wider line store.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/maps_render.sv
- fpga/tinymaps/tinymaps_top.sv
- tools/read_status.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---


## 18 COMMIT Unreleased 2026-10-26T14:30:00-07:00

#### Coming From:

Unreleased a86d4b8

#### Purpose:

Make the zoom go somewhere, after the hardware showed the arithmetic working but the range too small to feel like zooming.

#### Outcome:

Two wheel turns on the Tang settled the question with the readback rather than by eye: from a step of 39322 at level 3, one turn gave 32768 with the origin moving to (64, 204), exactly where holding the centre of the screen puts it, and the next turn crossed to level 2 at a step of 1.0 with the source coordinates doubled and the horizontal origin clamped to zero because that level is a screen wide at 1.0. So the navigation was correct and the problem was range: a factor of two per level in five steps of 19 percent, 16 times from end to end, which reads as detail changing rather than as zooming. The step table is gone. A turn now multiplies the step by about 1/1.078 -- nine steps to the octave instead of five at 19 percent -- using shifts and adds rather than a multiply, and a level crossing normalises the step to exactly 1.0 or 0.5 so the rounding never accumulates across a session. The other half of the change is that the finest level no longer stops at 0.5. That boundary exists because at or below it the next finer level is the right one to show, but the finest level has no finer neighbour, so the zoom stopped exactly where it was most wanted; it now continues to 0.25, four output pixels per source pixel, and the viewport guard's floor moved from 0.5 to 0.25 to match. The range is now 32 times. The new nine-turn test found a real defect while it was being written: the level crossing was judged against the step in force rather than the step about to be written, so a turn could leave the step below 0.5 on a level that did have a finer neighbour, which is the one state the renderer's rotation cannot serve. The test also caught two stale expectations of mine -- that all nine turns would reduce the step when the ninth is the crossing, and that a step of 0.4 would be refused when the guard had just been moved to admit it. The core builds at placement seed 1 to `tinymaps.109ea3a8822d.bin` with `hclk` at 91.27 MHz against 74.25, setup=0 and hold=0, and all ten testbench and checker results pass. Deployment did not run: the Tang came off USB again before the bitstream could be written, the same instability that has interrupted every long transfer since the capture card was introduced. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Deploy `tinymaps.109ea3a8822d.bin` when the link is stable and try the wheel: each detent should now move about eight percent rather than nineteen, nine turns should cover an octave and land exactly on the next level, and on the finest level the zoom should keep going past 0.5 down to 0.25 instead of stopping. The glitch pixels at the top of the frame remain open and are the older of the two outstanding faults; the readback's wrong top byte for bases above 16 MB is the third.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/maps_nav.sv
- sim/tb_maps_nav.sv
- sim/tb_maps_view.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 19 COMMIT Unreleased 2026-10-26T17:14:32-07:00

#### Coming From:

Unreleased e7e91e4

#### Purpose:

Find and fix the corrupt pixels at the top of every frame, which had survived four earlier attempts and were the oldest open defect in the picture.

#### Outcome:

The corruption was in `maps_video_rd`, not in the line store and not a matter of the renderer being late, and three instruments narrowed it in that order. A build that tagged each store slot with the line identity it held showed, from a capture, that the store always served the right line; a stale-read marker painted per row, defined as the writer writing the slot being read while at or behind the reader, never fired across 329 recorded frames; and `sim/tb_maps_line_store.sv`, new this cycle, runs the real `maps_render` behind the real store arithmetic with a static viewport and produced two frames identical to all 921,600 pixels, so the schedule does not race when memory latency is fixed. Two hypotheses were tested and rejected on the way: giving line 0 five blanking lines instead of one moved the worst row's frame-to-frame deviation from 44.60 to 44.10 and was reverted, and an eight-slot store with a four-line lead bought the right margin but took `hclk` to 67.49 MHz, so it was reverted too. The real fault is that the renderer's fetch engine drops `f_busy` on the last entry it accepts, which is not the end of the 256-byte SDRAM line, so a request arriving while a line was still open reloaded `base`, `skip` and `left` and fired `vstart` under it; `sdram_ctrl` only queues a `vstart` and services it when idle, so the stray pulse scheduled an extra line, and the old line's `vdone` then read as the new request's end-of-line and asked for one more, putting a row one SDRAM line out of place. Only the blocking refetch path issues fetches back to back, which is why the damage was the first lines of a frame and the lines after a pan and why which fetch it hit varied with SDRAM latency. The adapter is now an explicit four-state machine that holds a request until the channel is idle and leaves one clear cycle between lines, and the same testbench measures sixty vstarts during a live line before the change and none after, so it stays as a regression gate. An eight-seed placement sweep of the finished design gives `hclk` between 66.63 and 75.65 MHz against 74.25 and only seed 7 passes, which means the 83 to 96 MHz figures recorded in earlier entries were single placements rather than the design's margin; the shipped artefact is `tinymaps.df0b0e056c49.bin`, 4,428,780 bytes, at 75.65 MHz with `clk` at 429.18 MHz against 21.49 and setup=0 hold=0. It was put on the card with `tangput`, programmed with `tangload`, probed on the link before any test data was sent, and loaded with the diagnostic pattern, its palette and the viewport that reproduced the fault. The user reports the picture perfect with no shimmer, and a capture corroborates it quantitatively: rows 0 to 20 sample identical source rows at this viewport and are now pixel-identical to each other, where before rows 0 to 3 were 20 to 85 levels out and changed every frame. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The picture has no known defect left, so the next work is the timing margin: find the critical path behind `hclk` and shorten it rather than re-rolling placement seeds, because seven of eight seeds failing at 74.25 MHz means the design has no headroom and the next logic change can cost the build. Two recorded defects are still open: the status readback's top byte reads wrong for bases above 16 MB, and the zoom ceiling still lets the finest level overshoot past its own width.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_video_rd.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_line_store.sv
- tools/maps_test_pattern.py
- tools/set_view.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 20 COMMIT Unreleased 2026-10-26T18:23:31-07:00

#### Coming From:

Unreleased 6b73491

#### Purpose:

Get the real map pack back onto a board whose main power input had failed, so the shipped core could be exercised with the picture defect closed.

#### Outcome:

The board's main power input died during the previous cycle's pack load, and that failure, not the USB port, is what ended the session at the time: a bench supply on that port collapses to 1.4 V at 1.5 A, about 0.9 ohm, and a meter reads 1.0 ohm across its VBUS and ground with 0.1 ohm of lead resistance nulled, identical in both directions, while the OTG input reads 27 kOhm and drifts as its capacitor charges. A resistive short of that value points at a failed ceramic capacitor or ESD diode on that input's branch rather than a plain metal bridge, which would read near the lead resistance, and the board runs from the other input, so nothing downstream of the two input Schottkys is involved. Nothing was repaired; the user powered the board from the battery connector J5 instead, first at 4.7 V and then, after this project recorded that the schematic marks +BATT 4.2 V maximum, at 4.2 V, and the shell came back in two-wire on that supply. On the OTG cable alone the board comes up one-wire as SIPEED's FT2232 debugger with TinyTang not running, which is the documented BRD-006 behaviour and leaves no shell and no way to load a pack; the user's observation that a charge-only OTG supply does boot TinyTang, and that attaching the host afterwards is enough for two-wire, is evidence against the recorded guess that the power input's VBUS selects the mode, and belongs in TinyTang's own records rather than this one. `tangload` then programmed `tinymaps.df0b0e056c49.bin` -- the artefact entry 19 built, so no build ran in this cycle -- the link was probed with the palette command before any payload, and `tools/load_pack.py` wrote all 28.00 MiB of the pack with every block and image CRC accepted, which is the transfer that had died mid-way when the input failed. The level table was sent with all four entries and `tools/set_view.py --level 3` put the viewport on the 768x768 level at `0x1b703d8`, step 0.6000, origin (0, 168); `tools/read_status.py` confirms the step and origin, and its known top-byte defect still reports that base as `0xb7b703d8`. The user reports the map, the wheel and the pan all working, which is the first acceptance of the shipped core with real map data rather than a diagnostic pattern. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Repair the power input when convenient: lift one leg of that branch's input capacitor and re-measure, then its ESD diode, then suspect the receptacle, since a reading that survives both removals is a connector fault. The engineering work behind it is unchanged and now the only item with real risk in it -- the eight-seed sweep gives `hclk` between 66.63 and 75.65 MHz against 74.25 with only seed 7 passing, so the critical path behind `maps_render.sv:173`'s `row_ok` and the fetch address needs finding and shortening before another logic change is safe. The status readback's wrong top byte above 16 MB and the zoom ceiling that lets the finest level overshoot its own width are both still open and small.

#### Files Modified:

- docs/HANDOFF.md

#### Status:

- Build: N/A
- Deployment: PASS
- User Test: PASS

---
