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

## 21 COMMIT Unreleased 2026-10-26T18:38:11-07:00

#### Coming From:

Unreleased a1a9be4

#### Purpose:

Stop the picture walking sideways at every level crossing when zooming, which the user saw as the map shifting three or four times on the way fully in or fully out.

#### Outcome:

The four levels of a pack are cut on their own 256-pixel tile grids, so their pixel (0,0) landed on four different ground points -- measured from the pack header, 128 pixels down for L1, 128 across and 64 down for L2, 192 across and 160 down for L3 -- while `maps_nav` crosses a level by doubling or halving the source coordinates, which is only correct when every level shares one origin. Each boundary therefore landed the centre off by that level's offset, and the level table the fabric is given carries no origin, so the fabric could neither detect nor correct it. The fix went into the pack rather than the fabric, on the grounds that seven of eight placement seeds fail at 74.25 MHz and adding arithmetic to `maps_nav` is the last thing the timing margin can afford: `levels()` now takes the finest level's tile corner as the shared origin and crops every level's mosaic to begin there, and where cropping would leave a coarse level narrower than 640 pixels -- the width a screen at step 0.5 shows, which is the step a crossing lands on -- it adds a ring of tiles on the right and bottom. The offsets are exact whole pixels of each coarse grid, because a level's pixels are a power-of-two subdivision of the same ground, so no pixel is resampled; the pack is now 27.62 MiB with L0 4608x4608, L1 2304x2432, L2 1152x1216 and L3 832x864, all recording origin 3857 (-12486753, 3966165), and seven more tiles were fetched to grow L3 from 3x3 to 4x4. `maps_pack.py verify` now fails a pack whose levels disagree about the origin and prints the shared one, and `tools/load_pack.py` refuses to send one, which was checked in both directions: it accepts the realigned pack and rejected a copy whose L1 origin had been patched back to the old value. `maps_nav.sv` changed in comments only, to state the invariant and where it is enforced; no RTL logic changed, and a rebuild at placement seed 7 reproduced `tinymaps.df0b0e056c49.bin` byte for byte at 75.65 MHz against 74.25, so the artefact on the board is exactly the committed source. The new pack was loaded over the link with all four levels and every CRC accepted, the level table sent, and the view put on L3 at step 0.65, which is the whole 832-pixel width in one screen; the crossing arithmetic was checked numerically before the test, doubling each level's coordinate for a common ground point and matching it against the finer level's own pixel to under 0.001 of a pixel. The user reports zooming fully out and back in with the centre held, so the alignment is now a property of the tool that builds the pack rather than an assumption noted in a comment. The levels still do not cover identical ground -- L3 spans about 32 km against L0's 22 -- so panning to a coarse level's outer margin and zooming back in clamps at the finer level's edge; that is unavoidable while a level must be 640 pixels wide and the common rectangle at z12 is 576. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The timing margin is now the only item carrying real risk: the eight-seed sweep gives `hclk` between 66.63 and 75.65 MHz with seed 7 the only pass, and the worst path runs through `maps_render.sv:173`'s `row_ok` into the fetch address, so registering that chain is the next piece of work and every subsequent logic change should be followed by a seed sweep. The two small defects are unchanged: the status readback's top byte reads wrong for bases above 16 MB, and the zoom ceiling still lets the finest level overshoot its own width.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_nav.sv
- tools/load_pack.py
- tools/maps_pack.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 22 COMMIT Unreleased 2026-10-26T18:52:40-07:00

#### Coming From:

Unreleased 1d82f2b

#### Purpose:

Recover the timing margin, after an eight-seed sweep showed seven placements failing at 74.25 MHz and the design shipping on the one lucky seed.

#### Outcome:

The critical path was read out of the placement report rather than guessed: 13.22 ns of a 13.47 ns period, thirty segments of it tracing to `maps_render.sv:173`, which is the row-pair clamp. `S_PLAN` computed `r0` into that 32-bit add, compare and mux, then fed the result into the `pf_row * level_w` multiply and the fetch base address, all inside one clock, with eighteen carry-chain steps and 2.57 ns of routing in the chain. A new `S_ROWS` state now registers the row pair one cycle before `S_PLAN` reads it, so each clock holds one arithmetic operation instead of two; it costs one clock in the 1650 a raster line has, and every use in the plan and the blocking fetch was moved to the registered pair. `check_render` still matches its reference on all five viewports and `tb_maps_line_store` still reports identical frames with no vstart during a live line, so the extra cycle changed nothing observable. The eight-seed sweep of the same eight seeds then returned 83.44, 92.67, 82.02, 86.37, 87.69, 89.89, 88.24 and 90.01 MHz with every seed passing, against 66.63 to 75.65 with one passing before, so the worst placement now has 7.8 MHz of margin and the design no longer depends on which seed is chosen. The build of record is `tinymaps.d9e7bf60b5fe.bin` at seed 2, the highest at 92.67 MHz. Deployment did not run and the user could not test: the Tang was off USB entirely at the end of the cycle, with no `/dev/ttyACM0` and no FT2232 present, so nothing was written to the card and no bitstream was programmed. The change will ship with the next cycle's deploy rather than on its own. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Ship this bitstream with the pointer and zoom-to-cursor work so one deploy covers both, and confirm on the board that the map still pans and draws as it did, since the timing fix moved one clock inside the renderer's line engine. That work, approved this cycle: forward the mouse button state that `maps_link_rx` already latches but drops, add a pointer register with the green frame and red crosshair indicators, make the left button a grab and release on the land, and make the wheel zoom about the cursor rather than the centre of the screen. Free rotation stays out of scope until a bandwidth model says it fits, because the row-based sampler cannot serve a diagonal output line.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_render.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 23 COMMIT Unreleased 2026-10-26T19:32:41-07:00

#### Coming From:

Unreleased 5220e8a

#### Purpose:

Give the map the mouse interaction the user asked for after watching TinyCreature: a cursor drawn on the picture, a left button that takes the land and lets it go, and a wheel that zooms wherever the cursor is rather than about the middle of the screen.

#### Outcome:

TinyCreature's own records fixed the shape of it: a sixteen-pixel marker that is a green frame with no button down and a red crosshair while one is held, changed on the button state rather than on movement, and a left press that takes the piece of land under the marker. `maps_link_rx` had been latching the mouse report's button byte and dropping it; it now forwards the buttons and one flag saying whether the event came from the mouse or the keyboard, because a keyboard pan has no marker to hold. `maps_nav` tracks the cursor in output pixels, starts it in the middle, clamps it to the screen, moves it on every report, and pans the land only while the left button is held -- motion with nothing held moves the marker alone. The wheel zooms about the cursor: the origin shift is the cursor's coordinates times the change in step, where it used to be a constant 640 and 360 that kept the middle of the screen fixed. `tinymaps_top` draws the marker over the picture rather than through the palette, so the pack's colours are untouched. Two multiplies came with this and each needed its own clock before timing would close: the step change is narrowed to seventeen bits and registered in a new `N_PIVOT` state, which took placement seed 1 from 65.79 to 73.51 MHz, and the next worst path turned out to be the renderer's fetch base, the other half of the chain entry 22 split, so `r_pf * level_w` is now registered in a new `S_RADDR` state. `tb_maps_nav` gained tests for the cursor clamping at both corners, for motion with no button leaving the land alone, for a held button panning it, and for a zoom holding the point under an off-centre cursor -- that last one fails if the pivot is still the screen centre. Every testbench and both checkers pass, `check_render` included. The eight-seed sweep gives six of eight passing, 74.58 to 81.81 MHz, against eight of eight at 82.02 to 92.67 for the timing-only build, so this feature costs about seven megahertz and the design is seed-sensitive again at the low end; the remaining worst path is 4.5 ns of routing between the row buffers and the SDRAM controller, which is placement rather than logic. Deployed as `tinymaps.f3aec678d40b.bin`, 4,450,176 bytes, at seed 7 and 81.81 MHz against 74.25, with the pack reloaded and the view set on L3, and the user reports the interaction right. This entry also records what entry 22 could not: its build `tinymaps.d9e7bf60b5fe.bin` was deployed once the board returned to USB and the user passed it, so the timing fix is confirmed on hardware and entry 22's `NOT RUN` stages are now satisfied rather than outstanding. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Two changes the user asked for next: the marker doubles to thirty-two pixels, and the drag direction inverts, because pulling the land currently sends it the opposite way from the hand -- panning from a mouse drag has to negate the report while the keyboard keeps its own direction. After that the margin wants attention again, since six of eight seeds pass: the path to look at is the row-buffer to SDRAM routing at 4.5 ns, not another seed sweep. Free rotation remains out of scope until a bandwidth model says the row-based sampler could serve a diagonal line at all.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/maps_nav.sv
- fpga/tinymaps/maps_render.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_nav.sv

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 24 COMMIT Unreleased 2026-10-26T19:57:06-07:00

#### Coming From:

Unreleased 3f7b081

#### Purpose:

Double the cursor marker and turn the hand round, after the user drove the first cursor build and reported that the drag pulled the land the opposite way to the cursor.

#### Outcome:

Both changes are small and neither touched the sampling. The marker went from sixteen pixels to thirty-two with the proportions kept -- a four-pixel frame and a four-pixel crosshair, still centred on the pixel it marks -- and the drag now subtracts the mouse report instead of adding it, so dragging right sends the picture right, which is what a hand on the land does. The inversion is deliberately confined to the drag: a keyboard pan still adds its report, because the arrows move the view toward the arrow and a key press is not a hand, and a new test pins that direction so the two mappings cannot drift together later. Two of the existing pan tests had to move their starting origin out to mid-level, because a rightward drag now walks the viewport origin down and a test that began at zero was clamping rather than panning; that was the test's setup and not the logic, and the failures it produced before the fix are what identified it. Every testbench and both checkers pass, `check_render` included. The eight-seed sweep gives seven of eight passing at 78.44 to 82.41 MHz, one more than the previous build and with a higher ceiling, so whatever the marker geometry costs it is under what the routing between the row buffers and the SDRAM controller varies by seed to seed. Deployed as `tinymaps.e8242e81daf7.bin`, 4,431,542 bytes, at seed 1 and 82.41 MHz against 74.25, with the palette, the level table and the viewport re-sent; the pack was not reloaded because the board had stayed powered and the SDRAM still held it, and the map came up. The user reports both changes right, which is also the first hardware acceptance of the cursor work committed as entry 23. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The margin is the outstanding engineering item: seven of eight seeds pass but the worst is 71.37 and the spread is eleven megahertz, and the path that decides it is 4.5 ns of routing between the renderer's row buffers and the SDRAM controller rather than any one expression, so it needs looking at directly instead of being swept away by seed choice. Free rotation stays out of scope until a bandwidth model says the row-based sampler could serve a diagonal output line, and the board's dead power input is still a rework with the machine running from J5 at 4.2 V.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_nav.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_nav.sv

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 25 COMMIT Unreleased 2026-10-26T21:41:07-07:00

#### Coming From:

Unreleased ba03570

#### Purpose:

Find out what the BL616 link can actually deliver, after the streaming question made its 2 Mbaud rate the limit on everything the project wants to do next.

#### Outcome:

The link was measured before it was changed: 4 MiB loaded through the existing loader takes 22.0 s at 2 Mbaud, which is 190 kB/s and 95% of that UART's 200 kB/s wire rate, so the framing costs about 5% and the wire rate is the only lever. Raising the rate then needed the oversampling to change, because sixteen samples a bit needs sixteen clocks a bit and the 74.25 MHz pixel clock therefore cannot pass 4.64 Mbaud; eight samples a bit puts 5 Mbaud at 14.85 clocks, which is comfortable, and the same 4 MiB then takes 9.7 s -- **431 kB/s**, 2.27 times the 2 Mbaud figure. `LINK_BAUD` and `LINK_OVERSAMPLE` are parameters on the top and `OVERSAMPLE` is a parameter on both PHY modules, with the repository default left at 2 Mbaud and sixteen samples so the shipped design is unchanged. The attempt at 12 Mbaud failed and is recorded so nobody repeats it: the PHY was moved to the 371.25 MHz clock the TMDS serialiser owns, with a clock crossing built for it, and that domain closed at 154 MHz against the 371 it demands; narrowing the baud accumulator from twenty bits to twelve -- it only has to place its ticks, and twelve bits is 0.1% -- took it to 189 MHz, still half the required rate. Sharpening that number was the useful part: an accumulator is a feedback loop, so its logic depth cannot be pipelined across cycles however it is written, and 12 Mbaud needs a ~200 MHz clock this design does not have. The crossing module, its testbench and its entry in the synthesis source list were removed rather than left in the tree, and the PHY returned to the pixel clock with the oversampling parameterised. A new testbench pins the configuration that ships at speed: 256 bytes each way at 5 Mbaud with eight samples a bit, 8% jitter on every bit edge and a framing error dropped, and the older 12 Mbaud PHY testbench was kept because it is the evidence that the PHY itself is not the obstacle. Every testbench and both checkers pass. On the other side the rate only moves when asked, so TinyTang gained `fpgabaud <rate>`, which calls `tang_fpga_set_baud` directly instead of negotiating with the core; built with the xpack RISC-V compiler against the SDK at its pinned commit, flashed over USB, and verified on the board: the command answered and refused an unoffered rate, and a switch to 12 Mbaud silenced a 2 Mbaud core and a switch back restored it, so a mis-set rate is one command from recovery rather than a power cycle. The 5 Mbaud build is **deployed and measured but marginal**: one of eight placement seeds passed, seed 7 at 74.97 MHz against 74.25, where the previous build swept 78.44 to 82.41 with seven of eight passing. That regression is not yet understood; the next cycle measures the same tree at 2 Mbaud and sixteen samples to separate the constants from the design's existing margin. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Build the same tree at 2 Mbaud and sixteen samples, at the two seeds whose 5 Mbaud numbers are known, to decide whether the link constants cost about six megahertz of timing or whether this design has always been this close to the wall; either answer leads to the renderer's row-buffer to SDRAM routing, which is 4.5 ns of placement rather than an expression to split. Then the streaming architecture the bandwidth numbers were gathered for: a tile pool with a page table, a fetch engine that can follow a tile map across a 256-pixel boundary, and a miss falling back to the next coarser level. The TinyTang `fpgabaud` patch is committed in its own repository. The two small defects and the board's shorted power input are unchanged.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_uart_rx.sv
- fpga/tinymaps/maps_uart_tx.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_uart_5m.sv
- sim/tb_maps_uart_fast.sv

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 26 COMMIT Unreleased 2026-10-26T22:13:35-07:00

#### Coming From:

Unreleased e87d122

#### Purpose:

Find out why the 5 Mbaud build passed only one placement seed of eight, and fix the cause rather than sweep for a lucky one.

#### Outcome:

The controlled comparison came first, because the previous cycle had changed two things at once. The same tree built at 2 Mbaud and sixteen samples gave 82.41 MHz at seed 1 and 78.79 at seed 7, where 5 Mbaud and eight samples gave 74.21 and 74.97 at those same seeds, so the link constants were innocent and the 5 Mbaud netlist had simply been placed worse. The placement report then said what had moved: with the renderer's row pair and fetch base address already given their own cycles in earlier cycles, the critical path was in `maps_nav`, where `N_PAN` computed four clamped candidates -- each a 32-bit add, a compare and a mux -- straight into the same register's enable. It measured 13.48 ns against a 13.47 ns period and 1.27 ns of it was a route from a site to itself, which is a placement pathology rather than a logic one, but the shape of the chain was the reason the placer had nowhere good to put it. A new `N_PRE` state registers the four candidates one clock before `N_PAN` chooses between them, so `N_PAN` is now a three-way mux and an accumulator decrement; it costs one clock in the sixteen a nudge takes, and `tb_maps_nav` passes every case including the pan distance, both clamps, the cursor, the grab and the pivot zoom. The same two seeds at 5 Mbaud then returned **82.21** and **84.35 MHz** -- up 8.0 and 9.4 -- and both beat what the 2 Mbaud build manages at those seeds, so the three chains now hoisted out (the row pair, the fetch base and the pan candidates) have taken the design from one seed of eight to at least two of two placed with margin. The wider eight-seed sweep did not complete: the background launches for it died repeatedly before any build started, and the honest state is two placements measured at 82.21 and 84.35 rather than a full spread. Deployed as `tinymaps.ac916e42ed71.bin`, the 5 Mbaud parameterisation at seed 7 and 84.35 MHz, with the ballast pack reloaded at the faster link in 70 s rather than 155 and the view returned to L3; the user reports it behaving exactly like the previous build, which is the pass this change needs because the risk in it was the pan arithmetic rather than the picture. The committed default stays at 2 Mbaud and sixteen samples, and the 5 Mbaud default used for the measurement was reverted before committing: a core that defaults to 5 Mbaud is deaf after `tangload` until `fpgabaud 5000000` is typed, which is the wrong default for a viewer, so the faster link is a build parameter plus one command and the entry for it is entry 25. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The eight-seed sweep of this build still owes a number, and the background launches need to be replaced with something that survives before it is trusted again. With margin at 82 to 84 MHz and the panel of recurring wide chains now hoisted, the streaming architecture is unblocked: a tile pool with a page table in fabric, a fetch engine that follows a tile map across a 256-pixel boundary instead of one linear base address, prefetch and eviction driven by the viewport, and a miss falling back to the next coarser level rather than drawing garbage. The bandwidth it can expect is measured -- 431 kB/s at 5 Mbaud -- so a 64 KB tile is 0.15 s and a z15 screenful about 2 s, and 4-bit tiles would halve both.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- fpga/tinymaps/maps_nav.sv

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 27 COMMIT Unreleased 2026-10-26T22:39:58-07:00

#### Coming From:

Unreleased f0d3775

#### Purpose:

Give the design a build sweep that cannot be lost, and use it to settle the eight-seed spread the previous entry owed.

#### Outcome:

Every cycle that needed a spread so far had it driven from ad-hoc shell scripts written into `/tmp`, and those died often enough that one sweep silently never ran while looking alive -- `ps` was matching the searching command's own arguments. `tools/build_seeds.sh` replaces them: it takes seeds or a `--range`, builds them `-j` at a time in parallel, gives each its own `MAPS_BUILD_DIR` because the flow re-stages and deletes its tree on every invocation, records the seed list and the start time in `build/seeds.txt` before the first build begins, and appends one line per seed with the verdict, the frequency and the artefact name whether or not the run survives. Its exit status is 0 if any seed passed, 1 if none did, and 2 for bad arguments, because a seed that misses timing is the measurement rather than an error. It was proved on two seeds whose answers were already known -- 80.85 and 83.37 at the committed 2 Mbaud default, against 82.41 and 78.79 before the pan fix -- and then run over seeds 1 to 8, which is the spread entry 26 could not quote: **all eight pass**, from 76.44 at seed 5 to 84.05 at seed 3, with seed 8 at 82.09, seed 4 at 83.25, seed 7 at 83.37, seed 1 at 80.85, seed 6 at 80.50 and seed 2 at 78.91. The design therefore closes on every placement tried rather than on a lucky one, and the worst of the eight still has 2.2 MHz of margin, which is the first time that has been true since the integration first closed. No deployment ran in this cycle: the user asked for the tooling and the sweep without a board test, so nothing was programmed and the board stays on `tinymaps.ac916e42ed71` from entry 26. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The streaming architecture is unblocked and is the next real piece: a tile pool with a page table in fabric, a fetch engine that follows a tile map across a 256-pixel boundary rather than one linear base address, prefetch and eviction driven by the viewport, and a miss falling back to the next coarser level instead of drawing garbage. The budget is measured -- 431 kB/s at 5 Mbaud, so a 64 KB tile is 0.15 s and a z15 screenful about 2 s, halved by 4-bit tiles -- and the margin is now known: 76.44 to 84.05 across eight seeds, so new logic has about two megahertz to spend before it needs its own hoisting. The two small defects remain, the readback's top byte above 16 MB and the zoom ceiling on the finest level, as does the board's shorted power input.

#### Files Modified:

- README.md
- tools/build_seeds.sh

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 28 COMMIT Unreleased 2026-10-26T22:47:00-07:00

#### Coming From:

Unreleased 3e3f115

#### Purpose:

Scope the tile-streaming architecture and its risks on paper, before any of the renderer that currently works is touched, at the user's request.

#### Outcome:

`docs/streaming-scope.md` sets out what virtual texturing would give this core -- the reachable area becoming as large as the storage behind it rather than one 18.4 km pack, at max zoom anywhere -- and states plainly that the honest description of the result is web-map behaviour on a slow connection, sharp where the viewer settles and soft while they move. It is built from the numbers this project has measured rather than from estimates: 431 kB/s over the link at 5 Mbaud, 190 at the board's 2 Mbaud default, `hclk` between 76.44 and 84.05 MHz across eight placement seeds, and 32 MiB of SDRAM of which 27.62 is the current pack. From those it derives the working figures -- a 256-pixel tile is 64 KiB at 8 bits per pixel and 32 KiB at 4, a z15 screen covers 15 to 24 tiles, a screen takes 2.4 to 3.5 seconds to fill at 8bpp against the two seconds a user takes to drag one screen width, so the link cannot keep up with a fast pan and the design has to degrade rather than wait -- and notes that a coarse overview is cheap enough to hold permanently, a handful of z10 tiles covering the whole metro, which is what makes a fallback affordable. It then gives the shape of the design in five parts, four decisions the user has to make -- where tiles come from among the host link, the BL616's card, the FPGA's own flash with 15 MB free, or an SD card on a header; 4 bits per pixel; pool size and eviction; and whether the fabric or the far end computes the tile list -- and a work breakdown with the fetch engine marked as the whole risk. That risk is stated precisely: today a line fetch is one linear burst of 644 entries covering 1288 source pixels, and with 256-pixel tiles a line becomes up to six bursts in different slots, so the question is whether six SDRAM row activations fit the 1650 clocks a raster line gives where one does today. The document proposes proving that in a testbench before the renderer is touched, and lists what streaming does not solve: the link remains the ceiling, the fallback is soft, and the two small defects are untouched. No code changed, no build or deployment applies, and the three open questions at the end are for the user. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Wait for the user's answers to the three questions -- tile source, whether 4 bits per pixel is acceptable, and whether soft-while-moving is acceptable -- then build the fetch-engine testbench that answers whether six bursts per line fit the per-line budget, since that answer decides the shape of everything after it.

#### Files Modified:

- docs/streaming-scope.md

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 29 COMMIT Unreleased 2026-10-26T23:15:27-07:00

#### Coming From:

Unreleased 6665c7a

#### Purpose:

Record the user's streaming decisions, correct the scope's risk assessment against the code, and build the 4bpp tile pack format the rest of the architecture reads.

#### Outcome:

The user settled the three questions the scope left open: tiles come from the SD card served by the BL616 and no configuration flash is used, four bits per pixel is acceptable, and sharp-where-you-stop with soft-while-you-move is the wanted trade. The flash was dropped because it is *smaller* than the area streaming exists to reach -- eleven to fifteen megabytes is about 280 square kilometres at z15 in 8bpp, barely more than the 22 km pack that already fits, so streaming from it would defeat the purpose -- and because the BL616 already reads the card for every other core, which makes the card the pattern rather than a compromise. The scope now records all of that and its open questions become answered ones. Its risk assessment was also corrected against the code, and this was the useful part: the video channel reads 128 halfwords, 256 bytes per request, and a 256-pixel tile row at one byte per pixel is exactly 256 bytes, so **a tile row is one SDRAM line read**. A line fetch spans 644 entries, which is 5.03 line reads, so a tile-mapped row crossing five boundaries is 5 or 6 -- the same order of magnitude rather than six times the work. What tiles cost is page misses rather than reads, a few clocks each, on the order of a dozen clocks out of the 1650 a line has. The fetch engine was described as the whole risk in the previous entry and that was wrong. The first piece of the implementation is in: `tools/maps_pack.py tiles` writes a `TMTL` pack of 256-pixel tiles at 4bpp with a 16-colour palette of each tile's own, 455 tiles in 14.24 MiB against the 8bpp pack's 27.62 for the same ground, every level keeping the shared origin so a level crossing stays a doubling. Levels are padded up to whole tiles because their rasters are not multiples of 256 -- L3 is 832 by 864 -- which keeps every record 256 by 256 and puts the filler outside the level where the clamp never looks. `maps_pack.py verify-tiles` decodes every tile with its own palette and compares it against the source it claims to be, which is the check that catches a transposed or shifted tile that a structural check would pass, and reports the worst tile at 8.7 to 10.3 of 255 against its source, roughly four times the shared-palette pack's error and the accepted cost of sixteen colours. Nothing was built or deployed: the change is host-side plus documentation, so no bitstream applies and the board is untouched on `tinymaps.ac916e42ed71` from entry 26. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The page table and tile pool in fabric come next, then the chunked fetch in the renderer with a testbench that walks a source row across five slot boundaries and checks the entries land in order and the line still completes in its budget -- which the 256-byte arithmetic now says should cost about a dozen clocks, so the testbench is confirming a prediction rather than discovering a cost. After that the request protocol and a TinyTang tile server, then prefetch, eviction and the coarse fallback, and last the 4bpp path in the pixel pipeline with per-tile palettes.

#### Files Modified:

- docs/streaming-scope.md
- tools/maps_pack.py

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 30 COMMIT Unreleased 2026-10-26T23:29:09-07:00

#### Coming From:

Unreleased d6a0cea

#### Purpose:

Build and prove the two pieces the tile fetch stands on -- the page table that says which slot holds which tile, and the arithmetic that locates one entry of a source row inside a tile -- without touching the renderer that currently works.

#### Outcome:

`fpga/tinymaps/maps_tiles.sv` is a **direct-mapped cache** of 512 slots: the slot is a hash of the tile's level and coordinates, one 32-bit tag per slot says what it holds, and a lookup is one comparator and one block RAM read instead of a search across 512 tags. It is a cache and says so, so a tile whose slot has since been reused is a miss rather than an error. Two things the design forced are worth recording. The valid bits are flip-flops, not part of the tag, because a block RAM's power-up contents are not to be depended on and a garbage tag with its valid bit set would be a **false hit** -- the renderer drawing another part of the map, which looks like a rendering fault rather than an addressing one -- so reset clears the flops and stale tags are then harmless. And `fill_addr` came out as an output rather than an input: the first version let the loader choose a slot and the testbench caught it, because in a direct-mapped cache the hash decides the slot, so the loader has to be told where the bytes belong. `fpga/tinymaps/maps_tile_addr.sv` is the fetch arithmetic: given a source row and an absolute entry it returns the tile, the byte offset inside it and how many entries run to the tile boundary. Its testbench found three real mistakes in my own first version -- the entry offset within a tile row is seven bits because a row is 128 entries and not eight bits, the chunk index had to go because chunks break on the *tile grid* rather than at a fixed stride from the window start, and `{e0[12:1], 1'b0}` shifted back without doubling so every tile index came out half. The testbench that caught the last two recomposes each chunk back into a level coordinate, which is the check a shape test would miss. Both testbenches pass and the full suite is fifteen of fifteen. One design correction came out of the work: **the first streaming path uses 8bpp tiles, not 4bpp.** A 16-bit entry carries two 8-bit indices today and the pixel pipeline extracts the low and high byte by parity; at 4bpp an entry would carry four pixels and the pipeline would need nibble extraction, so 4bpp would have forced a pixel-path change before the fetch could work at all. At 8bpp a tile row is 256 bytes, exactly one SDRAM line and 128 entries -- the geometry the video channel already has -- so the fetch change stays inside the fetch engine and 4bpp becomes a packing and pixel-path change afterwards, which is where the scope's implementation order already had it. Nothing was built or deployed: these are two modules and their testbenches, not yet instantiated in the top, so the board is untouched on `tinymaps.ac916e42ed71`. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The chunked fetch in `maps_render`: `f_base` and `f_cnt` become per-chunk quantities computed from `maps_tile_addr` and looked up in `maps_tiles`, with the entry counter continuous across chunks and a wait state for the lookup's cycle, in both the rotating path and the blocking one. That is the first change to the renderer that works, so it needs its own testbench walking a row across five slot boundaries -- and the 8bpp geometry says it will cost about a dozen clocks of page misses, not a redesign.

#### Files Modified:

- docs/streaming-scope.md
- fpga/tinymaps/maps_tile_addr.sv
- fpga/tinymaps/maps_tiles.sv
- sim/tb_maps_tile_addr.sv
- sim/tb_maps_tiles.sv

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 31 COMMIT Unreleased 2026-10-26T23:35:18-07:00

#### Coming From:

Unreleased 5a7861d

#### Purpose:

Build the chunk sequencer that turns one window of a source row into per-tile reads, and correct the tile geometry it exposed, still without editing the renderer that works.

#### Outcome:

`fpga/tinymaps/maps_tile_fetch.sv` takes a request -- one source row, a starting entry and a span -- and walks it in chunks that each stay inside one tile: it asks the page table where the entry lives, reads that chunk from the pool through the same `rd_start`/`rd_addr`/`rd_count` protocol the renderer already speaks, and writes each entry to the caller's row buffer in window order. A tile that is not resident raises `miss` and stops the sequence rather than papering over it, because this module owns the sequence and not the policy of what to do about a miss. Two details came out of building it. The page table's answer is two cycles behind its question -- it registers the lookup and then registers the verdict -- so the sequence needs a lookup state and a wait state between chunks, and the first version's single-state wait read a stale hit. And the expensive part of the change turned out to be a mistake of mine rather than of the design: **a tile is 64 KiB, not 32**. A 256-pixel row is 256 bytes and there are 256 rows, so at 8bpp a tile is 65536 bytes and a 16 MiB pool is 256 slots, not 512. Both the page table and the fetch testbench had been written as 32 KiB, and the testbench caught it by decoding a tile offset as out of range and reading the wrong slot. The fetch testbench models the pool so that every entry reads back as {tile x ^ row inside the tile, tile y ^ entry inside the tile}, using the slot-to-tile mapping the table handed out at lookup, and compares the whole 644-entry window against values computed the same way from the level coordinate -- so a chunk that starts at the right tile but the wrong row, or advances by the wrong amount, reads back as a number that names which of those is wrong instead of looking plausible. It caught three of my own errors: the model's tile stride was 4 KiB so it truncated the offset, the state constant for the wait state was written `2'd4` in a two-bit register and would have aliased to idle, and the expected-value function concatenated two 32-bit integers into sixteen bits, which keeps the wrong half. Both new testbenches pass, the page table's own test still passes at the corrected geometry, and the full suite is sixteen of sixteen. Nothing was built or deployed: these are modules and testbenches, not yet instantiated in the top, so the board is untouched on `tinymaps.ac916e42ed71`. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Wire the sequencer into `maps_render`, which is the first change to the module that works: the fetch engine's `f_base` and `f_cnt` become the sequencer's request, its `f_ack` becomes the sequencer's `done`, and a `miss` needs a decision -- ask for the tile and retry the line, or draw that line from the coarser level. The renderer testbench and `check_render` are the gate: a tile-mapped run must produce the same pixels as the linear one when every tile is resident, which is a test that can be written before the wiring is trusted.

#### Files Modified:

- docs/streaming-scope.md
- fpga/tinymaps/maps_tile_fetch.sv
- fpga/tinymaps/maps_tiles.sv
- sim/tb_maps_tile_fetch.sv
- sim/tb_maps_tiles.sv

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 32 COMMIT Unreleased 2026-10-26T23:59:15-07:00

#### Coming From:

Unreleased a83bc9e

#### Purpose:

Give `maps_render` a fetch path that takes its entries from the tile sequencer instead of a linear level address, and prove that path draws the same pixels as the linear one.

#### Outcome:

`fpga/tinymaps/maps_render.sv` gained a `TILED` parameter and the sequencer's ports: when it is set the fetch engine stops computing `f_base` and `f_cnt` and starts a `maps_tile_fetch` window instead, the sequencer's `we`/`widx`/`wdata` write the row buffers in place of `rd_valid` and `f_j`, its `done` raises `f_ack`, and its `miss` leaves the row unmarked and increments `tile_misses` rather than pretending the line landed. The linear path is untouched and remains the default, so one module builds both ways. `sim/tb_maps_render_tiled.sv` runs the renderer, the sequencer and the real page table together against a pool model whose entries are `{row, entry index}`; all three lines are pixel-exact, all five fetches hit, and nothing is missed. Three faults surfaced, and only one of them was in the design. The design's was the sequencer sampling the page table a cycle early: the table registers the lookup and then the verdict, so its answer is two cycles behind the question, and the single wait state read the stale zero as a miss. It had gone unnoticed because `sim/tb_maps_tile_fetch.sv` modelled the table combinationally, so that model now carries the real two-cycle latency and the sequencer gained the second wait state. The other two were in the new testbench: it filled the pool after loading the palette, by which time the free-running renderer had already asked for a row and missed it, and its expected-value check inverted the halves of `{a, b}`, which is invisible on row 0 and wrong on every other. The full suite is sixteen of sixteen plus `check_render` and `check_tmds`, and the eight-seed sweep closes timing at seed 1 82.22, 2 82.40, 3 82.42, 4 83.77, 5 82.67, 6 78.62, 7 81.41 and 8 84.52 MHz against 74.25, so the tile multiplexers cost less than a megahertz. Nothing was deployed, on the user's instruction to hold the board; `TILED` is off in `tinymaps_top`, so the bitstream behaves exactly as the one on the Tang. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The half that talks to the card: a request protocol over the BL616 link for "give me tile (level, tx, ty)", the tile server on the TinyTang side that answers it from the SD card with the file reads it already performs for other cores, then prefetch and eviction in the page table, and the coarse-level fallback for a miss -- which is what makes the renderer's not-retrying a missed row harmless, since a settled view will need a frame drawn from the coarser level until the tile arrives. The first hardware test that matters is a pan across ground that is not resident, which needs the protocol, the server and the fallback together.

#### Files Modified:

- docs/HANDOFF.md
- docs/streaming-scope.md
- fpga/tinymaps/maps_render.sv
- fpga/tinymaps/maps_tile_fetch.sv
- fpga/tinymaps/maps_tiles.sv
- sim/tb_maps_render_tiled.sv
- sim/tb_maps_tile_fetch.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 33 COMMIT Unreleased 2026-10-27T00:18:09-07:00

#### Coming From:

Unreleased d3eb558

#### Purpose:

Give the fabric a way to ask the host for a tile, which is the first half of the request-and-reply pair the streaming design needs.

#### Outcome:

`fpga/tinymaps/maps_tile_fetch.sv` now reports the tile a miss was about -- `miss_level`, `miss_tx` and `miss_ty`, registered in the same cycle as `miss` -- because a caller that has to ask for the tile cannot ask for "the one that missed": by the time it acts the sequence has moved on and the lookup port belongs to somebody else. The new `fpga/tinymaps/maps_tile_req.sv` queues those misses and sends each as a frame on the link: `AA 00 06 1C L TXH TXL TYH TYL`, the same `0xAA`/length/command shape the host sends, so one parser serves both directions, with a five-byte payload of level and the tile's coordinates as fifteen bits in a sixteen-bit big-endian pair. Two requests for the same tile already in the queue fold into one, since a line misses in chunks and would otherwise ask eight times; the same tile asked for again after its request has gone is a second request, deliberately, because that is a tile that did not arrive in time and asking again is the only retry this design has. The transmitter is shared with the loader's answers, so a frame is offered only while the arbiter grants it and keeps the grant until the last byte is taken, and a byte is re-offered until the arbiter acknowledges it -- lost arbitration is a retry, not a hole in the middle of a frame. The queue holds eight, drops on overflow and says so with a sticky flag, and reports its depth so the status command can show a stalled queue later. `sim/tb_maps_tile_req.sv` models the transmitter and the arbiter -- busy for a few cycles after each byte, a higher-priority loader that can hold the line, and a mid-frame request from it that must not be granted -- and decodes every captured byte back into a frame: one miss is one frame byte for byte, a duplicate is folded, a repeat after the frame has gone is a new frame, nothing starts while the loader holds the line and the frame is intact once it lets go, a full queue drops and reports, and everything that was queued comes out in order. Reading the module back before it left the bench found one real defect: a push landing on the same edge as a frame's last byte assigned the depth twice in one cycle, the retire won, and the pushed request sat in the queue uncounted -- a request that is in the queue and not counted is a request that never goes out. The depth is now computed from both events at once, and the testbench sweeps a second push across every offset inside a frame's lifetime, so one of them necessarily lands on the retire edge; with the defect put back deliberately the sweep fails at offset 48, which is that edge. `sim/tb_maps_tile_fetch.sv` gained a selective miss so the reported coordinates can be checked rather than only the fact of a miss -- entry 600 of row 300 runs to the tile boundary at entry 640, so the fetch must name tile (5, 1) of level 2, and it does. The full suite is seventeen of seventeen, including `check_render` and `check_tmds`. Nothing was built or deployed: `maps_tile_req` is not instantiated in `tinymaps_top`, which still has no sequencer to miss, so the netlist and the board are untouched. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The reply, which is the other half of the cycle: a command that carries a tile's bytes, with the core writing them to the slot the page table chose and telling the table the tile has landed only when its last block has arrived, since the receiver's frame limit is 2047 bytes and a 32 KiB tile cannot be one frame. The slot address must stay the core's business -- the host should send coordinates, not a destination. After that, prefetch and eviction in the page table and the coarse-level fallback, which is what the renderer's not-retrying a missed row needs to be harmless.

#### Files Modified:

- docs/HANDOFF.md
- docs/streaming-scope.md
- fpga/tinymaps/maps_tile_fetch.sv
- fpga/tinymaps/maps_tile_req.sv
- sim/tb_maps_tile_fetch.sv
- sim/tb_maps_tile_req.sv

#### Status:

- Build: N/A
- Deployment: N/A
- User Test: N/A

---

## 34 COMMIT Unreleased 2026-10-27T01:03:44-07:00

#### Coming From:

Unreleased 6f612ad

#### Purpose:

Write the other half of the tile protocol -- the host's answer arriving as blocks that land in the pool and make a tile resident only when it is whole.

#### Outcome:

`fpga/tinymaps/maps_link_rx.sv` gained command `0x1D`, one block of one tile: nine header bytes of level, coordinates, offset and count, then the block, then a CRC-32, all little-endian, answered ACK or NAK `'D'`. The header is judged before a byte is written -- a zero or misaligned count, a misaligned offset, or a block that would run past the end of the tile is refused while its payload is still arriving -- and the write goes to the address the page table derives from the coordinates plus the offset, so the host never names a destination and the cache's replacement policy stays in the cache. `fpga/tinymaps/maps_tiles.sv` changed shape for it: filling was one event and is now two, because the loader needs the address before the bytes exist and must not make the tile resident until they are all in. `fill_addr` is a function of the coordinates and needs no state; `fill_commit` is the event that sets the tag and the valid bit. Marking a tile resident when the address was handed out would make a half-written tile a hit, which is the same failure as a garbage tag: a hit on somebody else's picture. A block is acknowledged, and a tile committed, only after the last write it caused has been taken by the port, and a block that lost a word to a busy port is refused rather than committed with a hole in it. Two bugs were found by the testbench rather than by reading. The finish state was written inside the per-byte guard, so it needed a byte to advance and the last byte of the block had already gone by -- nothing was ever acknowledged or committed, which is exactly the shape of "it wrote the data but said nothing". And the test that checks a refused block writes nothing was looking at a slot an earlier corrupt block had already written, which is the documented behaviour for a bad CRC: the bytes land and the tile is not made resident. `sim/tb_maps_link_rx.sv` now sends real blocks through the real frame parser and checks where they landed, that a middle block does not commit, that the block which ends the tile commits once with its own coordinates, that a corrupt block commits nothing, and that a misaligned block writes nothing. The request frame from the previous cycle was corrected to little-endian while the format had no implementation to break, and its testbench now decodes the corrected order. Seventeen of seventeen testbenches pass including `check_render` and `check_tmds`, and the eight-seed sweep closes timing from 82.28 to 87.86 MHz against 74.25, with seed 1 at 86.89. The tile command is behind a `TILES` parameter that `tinymaps_top` leaves off, because the pack occupies 27.62 MiB of the dock's 32 and the pool's base is inside it: a tile written today would land on the picture. So the bitstream behaves exactly as the one on the board and nothing was deployed. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Give the pool a home and put the page table in the top: reserve the part of the SDRAM the pack will give up, or shrink the pack, so `POOL_BASE` is not inside it, then instantiate `maps_tiles` with the loader's fill ports and turn `TILES` on -- at that point a tile the host sends is resident and the sequencer can hit it. After that the renderer's miss has to reach `maps_tile_req` and the coarse-level fallback has to draw something while the tile is on its way, which is what makes the renderer's not retrying a missed row harmless.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- docs/streaming-scope.md
- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/maps_tile_req.sv
- fpga/tinymaps/maps_tiles.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_link_rx.sv
- sim/tb_maps_render_tiled.sv
- sim/tb_maps_tile_req.sv
- sim/tb_maps_tiles.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 35 COMMIT Unreleased 2026-10-27T07:45:54-07:00

#### Coming From:

Unreleased 585727a

#### Purpose:

Give the tile pool a home in the SDRAM that nothing else writes, put the page table in the top, and turn the tile command on so the protocol is live on the board rather than only in a testbench.

#### Outcome:

The pack's last level ends at `0x01B9DBD8`, 27.62 MiB into a 32 MiB part, so the pool takes the four megabytes above 28: `POOL_BASE = 0x01C0_0000`, 64 slots of 64 KiB, ending exactly at the top. That is sixteen slots more than a 1280x720 screen at z15 needs counting partials, which leaves room for a prefetch to be ahead of the picture, and it is a region nothing else writes -- which is what makes accepting tiles safe. `tinymaps_top` now instantiates `maps_tiles` with the loader's fill ports and passes `TILES` as 1, so a tile the host sends lands in that region and is committed to the table. Nothing looks a tile up yet because the renderer still fetches linearly, so the table answers the loader and remembers. Three things came out of building it. `sim/tb_maps_link_rx.sv` had been answering the loader's `fill_addr` with a formula of its own instead of using the page table, which is the mistake this project has now made twice -- a model that behaves better than the module hides the module's bug -- so the bench instantiates the real table and now checks that a committed tile is a hit at the address its blocks went to. That change exposed a latent defect in the bench itself: `send_byte` drove `rx_valid` with blocking assignments in the clock edge's own time step, so roughly one byte in a thousand was lost, and a lost byte turns the next frame into a resync through the payload; it was invisible until the extra instance changed the order Verilator ran its processes in. The wire is driven between edges now, and the response guard, which was 20,000 clocks against a frame that takes 104,000 to send, was letting the bench compare the next test's reply. The third was real: `slot_of` computed `ty * 31` as a multiply, which cost nothing while `fill_addr` was a register, but the loader takes the address before the bytes arrive, so the multiply became combinational into the SDRAM controller's address mux. It took the design from 84.35 MHz at seed 1 to 70.15 and failed seven of eight seeds; as a shift and a subtract it is the same hash and the same slots, and the sweep is 75.46 to 88.40 with all eight packing. Seventeen of seventeen testbenches pass with `check_render` and `check_tmds`. Nothing was deployed. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The renderer's miss has to reach `maps_tile_req` and the coarse-level fallback has to draw something while a tile is on its way, which is what makes the renderer's not retrying a missed row harmless; that means turning `TILED` on in the top and instantiating the sequencer beside the table. Then prefetch and eviction in the page table, which needs the pool to say when it is full, and 4bpp in the pixel path, which changes the tile packing and the pixel extractor rather than the fetch. The pool is also provisional: 4 MiB of a 32 MiB part is enough for a screen and a prefetch, not for the reach the streaming design is for, and getting that reach means the pack gives up its finest level to the card.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- docs/streaming-scope.md
- fpga/tinymaps/maps_tiles.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_link_rx.sv
- tools/maps_open/synth.ys

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 36 COMMIT Unreleased 2026-10-27T08:11:33-07:00

#### Coming From:

Unreleased 303e281

#### Purpose:

Close the streaming loop -- a miss becomes a request, an answer becomes a resident tile, and the line draws from it -- and fix the stall that made the loop impossible.

#### Outcome:

`sim/tb_maps_stream.sv` wires the renderer in tile mode, the chunk sequencer, the real page table and the request queue the way the top will, and models the one piece that does not exist yet: the host, answering a request with a tile written where the table says and committed when whole. A line over an empty pool misses, the request goes out naming the tile the line's first pixel lives in, and after the answer the same line draws all sixty-four of its pixels, each the level's own byte at that source position. Tiles three columns away and one row away are covered, and so is a pan, with the picture converging as answers arrive because a single fetch stops at the first tile it does not have. Building it found that a miss was a permanent stall: the blocking fetch waits for `f_ack`, a miss never raises it, and the line engine waited for ever -- no pixels, no second request, nothing. `maps_render` now sets a flag on a miss that the blocking path sees, waits `TILE_RETRY` clocks (2^21, about 28 ms at 74.25 MHz, roughly a fifth of the time a 64 KiB tile takes over the link) and issues the same fetch again; without a timer a miss would re-ask once per line and fill the request queue with duplicates, and without any retry a tile that arrived late would leave the picture waiting on nothing. Three of the failures along the way were in the testbench rather than the design: it instantiated the sequencer twice instead of wiring one instance to both the table and the queue, it computed each expected pixel from the output column instead of the viewport origin, and it drove `cy` to a source row -- `cy` is an output row and the renderer only draws below `OUT_H`, so the "row 256" test ran no line at all. The bench also learned to hunt for `0xAA` when decoding request frames, because a frame cut short by a phase boundary shifted every later one. Seventeen of seventeen testbenches pass with `check_render` and `check_tmds`, and eight of eight seeds pack from 77.97 to 86.53 MHz, so the retry logic costs nothing in the built design -- where it is also unreachable, because `TILED` is still off. Nothing was deployed. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The coarse fallback, which is the last thing between this and tiling on the board: a line whose fine tile is missing has to be drawn from the coarser level, which stays resident, so an empty pool at boot shows a soft map instead of stalling every line on its retry timer. That is also what turns `TILED` on in the top, where the sequencer and the request queue get instantiated beside the table and the retry stops being unreachable code. After that, prefetch and eviction, which need the pool to report when it is full, and 4bpp in the pixel path.

#### Files Modified:

- docs/HANDOFF.md
- docs/streaming-scope.md
- fpga/tinymaps/maps_render.sv
- sim/tb_maps_stream.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 37 COMMIT Unreleased 2026-10-27T08:32:11-07:00

#### Coming From:

Unreleased eeb08d9

#### Purpose:

Draw a line whose tile has not arrived from the level below instead of stalling on it, which is the last piece tiling needs before it can be turned on in the top.

#### Outcome:

`maps_render` now has a coarse fallback, and the way it is done is deliberately dull: the coarse pass takes the row, the window's first entry and the pixel's own position as the fine ones halved, so two output pixels share one coarse pixel and the pixel pipeline is untouched -- it already magnifies by any step. `seq_level` became an output so the sequencer is asked about the level the line is actually being drawn from. Each row buffer remembers which level it came from, a line only mixes rows that agree, and a buffer only satisfies a row if the level matches. That last condition was the one that had to be found by experiment: without it a coarse row satisfied a fine line for ever, because the epoch would end, the picture would ask for its own level, and every buffer would answer that it already had that row, so the picture stayed soft with no misses and no requests. A miss at the view's own level now sets the fallback and starts the retry epoch; when the epoch ends at a line boundary the next line tries the view's own level again and the picture sharpens when that fetch lands, which is "sharp where you stay, soft while you move" falling out of the same machinery rather than a second mode. `sim/tb_maps_stream.sv` now judges a line as legitimate in exactly two forms -- the view's own level, or the level below with each pixel covering two by two -- and adds two scenarios: a view whose fine tiles were never sent must draw coarse and exact, and fine tiles that arrive late must sharpen the picture within an epoch. Both pass, and so does the earlier loop. Two bugs in the testbench were found on the way: it tied the page table's lookup level to a constant, so a coarse tile could never be found once the sequencer asked for one, and its settle loop treated only the fine level as success. Seventeen of seventeen testbenches pass with `check_render` and `check_tmds`, and eight of eight seeds pack from 80.01 to 84.83 MHz. `TILED` is still off in the top, so none of this is in the bitstream and nothing was deployed. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Turn `TILED` on in the top: instantiate the sequencer, the page table and the request queue beside the renderer, wire the sequencer's level from `seq_level` and its miss to the request queue, give the queue the link's transmitter with the loader's answers ahead of it, and give the loader the pool's address. That is the cycle where the retry and the fallback stop being unreachable code and the board streams, and it needs a hardware test on a view whose tiles are not resident. After that, prefetch and eviction, which need the pool to report when it is full, and 4bpp in the pixel path.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- docs/streaming-scope.md
- fpga/tinymaps/maps_render.sv
- sim/tb_maps_render_tiled.sv
- sim/tb_maps_stream.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 38 COMMIT Unreleased 2026-10-27T09:05:56-07:00

#### Coming From:

Unreleased 68a85ea

#### Purpose:

Put the streaming path in the top and give the host the switch that turns it on, so the fabric can stream without the bitstream deciding to.

#### Outcome:

`tinymaps_top` now carries the sequencer, the page table and the request queue beside the renderer, muxes the video channel between the renderer's own linear fetch and the sequencer's chunk read, and shares the link's transmitter between the loader's answers and the tile requests. The switch is command `0x1E`, one byte, and it defaults to the pack, because the pool cannot answer itself: until the host serves tiles, streaming mode is an empty pool and a blank picture, so the mode belongs to the host and not to the bitstream. `maps_render`'s `TILED` parameter became a `stream` port for that reason, and both fetch paths are built with one of them running. The level number the sequencer needs is recovered from the pack's base against the level table, because the streaming path asks for the level *below* the view and the table is the only thing that knows the addresses; the numbering is the pack's, finest first, so the fallback asks for one higher and level 3 falls back to nothing. Two changes were needed before the transmitter could be shared. A request keeps the line from the first byte the arbiter actually takes rather than from the offer, so losing arbitration does not stall the answer that won it; and `maps_link_rx`'s sender now waits for the line before offering a reply byte, which is what stops an ACK starting inside a request frame -- without that an interrupted request frame and an interleaved NAK would both be misparsed. `sim/tb_maps_link_rx.sv` gained a test for `0x1E`: off before it is asked, on when it is, and back again, each answered. Three of the failures along the way were the testbench being out of step with the design rather than the design being wrong: its settle loop stopped on a good line while a request from that same line was still outstanding, its expected coarse level followed the old numbering, and `tb_maps_line_store` and `tb_maps_render` needed the new port tied low. Seventeen of seventeen testbenches pass with `check_render` and `check_tmds`, and eight of eight seeds pack from 77.97 to 83.51 MHz with the whole streaming path in the netlist, so the sequencer, the table and the queue cost about four megahertz of the margin. Nothing was deployed. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The tile server on the TinyTang side: something has to decode the `0x1C` request frames and answer with `0x1D` blocks read from the card, and until it exists command `0x1E` switches the picture to an empty pool. The first hardware test after that is the one this whole line of work is for -- pan onto ground that is not resident and watch it arrive soft and sharpen -- and it needs the pack's coarse level resident in the pool first, since the fallback draws from it. After that, prefetch and eviction, which need the pool to report when it is full, and 4bpp in the pixel path.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- docs/streaming-scope.md
- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/maps_render.sv
- fpga/tinymaps/maps_tile_req.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_line_store.sv
- sim/tb_maps_link_rx.sv
- sim/tb_maps_render.sv
- sim/tb_maps_render_tiled.sv
- sim/tb_maps_stream.sv
- tools/maps_open/synth.ys

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 39 COMMIT Unreleased 2026-10-27T09:33:29-07:00

#### Coming From:

Unreleased 0173f5f

#### Purpose:

Build a tile pack the fabric can actually read and a host that answers its requests, so the streaming path can be tested on the board without firmware on the other side.

#### Outcome:

`tools/maps_pack.py tiles --bits=8` writes the pack the streaming path needs: one 256-entry palette for the whole pack, which is the table the fabric's pixel path already reads, and 64 KiB records carrying nothing but the tile's own bytes. The four-bit pack stays, and still verifies, because it is smaller and waits for the pixel path to learn nibbles; a palette count of 256 does not fit the header's one byte, so it is written as zero and read back as 256. The eight-bit pack is 455 tiles over four levels in 28.44 MiB, and `verify-tiles` decodes every one against its source: worst tile 4.0/255, against nine to ten for the four-bit pack, which is what 256 colours buy. `tools/serve_tiles.py` is the host half: it opens the BL616 pipe the way the loader tools do, loads the pack's palette with command 0x08, switches the picture source with 0x1E, then answers 0x1C requests with 0x1D blocks of a kilobyte, waiting for each ACK and re-sending a block that is refused, and it refuses a four-bit pack outright rather than serving one the pixel path would paint with the wrong twelve colours and no error. Its `--selftest` checks the framing, the tile lookup and the block CRC without a board, and given a pack it also reassembles a real 64 KiB tile from its 64 blocks at the finest level's last tile and the coarsest level's first, checking every header field and every CRC on the way -- both reassemble byte for byte. Two of the failures were the selftest being wrong rather than the tool: it expected a frame length that forgot the command byte, and it read a tile index as a byte value. Nothing in the fabric changed this cycle, so no build was run and the bitstream is the one from the last sweep at 77.97 to 83.51 MHz; nothing was deployed. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The hardware test this was built for: load the eight-bit pack's palette and coarse level, send `0x1E` to switch the picture to the pool, and pan onto ground that is not resident -- the pack is 28.44 MiB against a 4 MiB pool, so the first pan goes there. What to watch is a soft picture arriving and then sharpening, and what to instrument first if it does not is the request queue's depth, which is a wire in the top that nothing reports yet. After that, prefetch and eviction, which need the pool to say when it is full, and 4bpp in the pixel path.

#### Files Modified:

- README.md
- docs/HANDOFF.md
- docs/streaming-scope.md
- tools/maps_pack.py
- tools/serve_tiles.py

#### Status:

- Build: N/A
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 40 COMMIT Unreleased 2026-10-27T10:47:49-07:00

#### Coming From:

Unreleased b91ab4c

#### Purpose:

Deploy the streaming path to the Tang, find out why the pooled picture never finished, and fix it.

#### Outcome:

The streaming build went on the board -- `tinymaps.fa2cdc8d61c0.bin`, seed 1 at 81.57 MHz, uploaded under that name so the previous image stayed for rollback -- and it ran: `tangload` reported the core loaded and the status command answered with the expected viewport. `tools/serve_tiles.py` then loaded the eight-bit pack's palette, switched the source with `0x1E`, and the core, with an empty pool, asked for `L3 0,0` and onwards. Each 64 KiB tile took 0.32 s in 64 blocks. The picture never finished, and the cause was the pool's hash: `tx + 31 * ty + level` truncated to the slot count, with 31 equal to minus one modulo 64, so each screen row moved the slot backwards by one -- row 0 used slots 3 to 8, row 1 used 2 to 7, row 2 used 1 to 6. The rows of one screen overlapped almost completely, every delivered tile evicted one the next row needed, the renderer asked again, and the pool livelocked: serving more tiles could never have cured it. Thirteen is coprime with 64, so a row moves the slot on by thirteen and a screen's eighteen tiles get eighteen slots, and it costs three adds rather than a shift and a subtract. Simulation had passed with the old hash because the testbench's own pool used the same arithmetic and its window was small enough to fit. Two smaller faults the same run exposed are recorded and not fixed: the fetch window is a fixed 644 entries where a level can be 832 pixels wide, so the tail of a line asks for tiles past the level's right edge which cannot exist; and the request queue dedupes only against entries still queued, so one blocking fetch asks two or three times for the same tile. An attempt at the window clamp was written and withdrawn: it exposes that the fallback subtracts the fine window start from a coarse-scale index, which wants a testbench that models level bounds before it can be judged, and the board test never exercises the fallback because the coarsest level has none. `tools/serve_tiles.py` answered out-of-level requests with a blank tile so lines could complete, and gained `--once` so a tile already delivered is not sent twice in a run. Seventeen of seventeen testbenches pass with `check_render` and `check_tmds`, and eight of eight seeds pack from 83.88 to 90.51 MHz. The hash fix is built but not deployed, because the board went back to other work; nothing since the previous image is on the Tang. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Deploy `tinymaps.e6b43ef04d53.bin` and repeat the same view: with the hash fixed the pool should stop evicting itself and the picture should complete and stay. Then the window clamp and the fallback's `k0` together, with a testbench that models the level's bounds, and the request queue's pending set so one fetch does not ask for one tile three times.

#### Files Modified:

- docs/HANDOFF.md
- docs/streaming-scope.md
- fpga/tinymaps/maps_tiles.sv
- sim/tb_maps_stream.sv
- sim/tb_maps_tiles.sv
- tools/serve_tiles.py

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 41 COMMIT Unreleased 2026-10-27T12:26:58-07:00

#### Coming From:

Unreleased 71e9056

#### Purpose:

Get streaming working on the board, after the hash fix left it asking for nothing at all.

#### Outcome:

The hash-fixed image went on and the picture still asked for nothing. The status command gained the two bytes that answer the question it could not: byte 21 says whether the picture is coming from the pool and byte 22 says how many tile requests are waiting, and the base readout was fixed at the same time, since it took its top byte from out of range and reported `0xafaee3d8` for `0x01aee3d8` once a pool address passed sixteen megabytes. One read settled it -- `source = tile pool`, `renderer = blocking fetch`, `requests = 0`, and nine seconds of silence on the wire -- so the miss was never reaching the request queue and the renderer was wedged, not the transmitter. The cause was the runtime source switch: the video channel is muxed on the same signal the renderer watches, so switching while a linear fetch was in flight sent that fetch's completion to the sequencer instead, `f_busy` never cleared, the fetch engine never issued again and no miss was ever raised. It was timing-dependent, which is why switching while idle worked this morning and the later attempts did not. `maps_render` now abandons whatever was in flight when the source changes: both request lines drop, the miss flag and the retry timer clear, the row buffers are invalidated and the line engine returns to idle. With that, the same view, pack and server that had produced silence asked for `L3 0,0` onwards, took each 64 KiB tile in 0.32 s in 64 blocks, and drew; the user passed it. Two tooling faults cost time on the way and are recorded rather than fixed: the Tang came back as `/dev/ttyACM2` because a Pico2 and an ESP32 took the lower numbers while every tool defaults to `/dev/ttyACM0`, so two attempts went to the wrong device, and the switch-mid-fetch repair is not covered by simulation -- the bench passes with the guard and without it, and driving `stream` from a register failed the whole bench for reasons not chased, so hardware was the only judge. Seventeen of seventeen testbenches pass with `check_render` and `check_tmds`, and eight of eight seeds pack from 84.37 to 92.28 MHz, seed 1 at 92.28 being the image deployed as `tinymaps.46ea1fa2bbf5.bin`. The board went back to the user holding that bitstream in SRAM with the source on the pool; nothing else on the card was touched. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

The fetch window still runs past the level's right edge, which the host now answers with blank tiles rather than a refusal -- honest, but it asks for tiles that cannot exist every line. That, and the fallback's `k0` being the fine window start where the coarse scale needs `k0_e`, want one cycle with a testbench that models the level's bounds; then the request queue's pending set, so one blocking fetch does not ask three times for one tile; then a fine level, where the pool cannot hold the view and the fallback and the re-requests are what the picture depends on.

#### Files Modified:

- docs/HANDOFF.md
- docs/streaming-scope.md
- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/maps_render.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_stream.sv
- tools/read_status.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 42 COMMIT Unreleased 2026-10-27T13:29:35-07:00

#### Coming From:

Unreleased 80cd004

#### Purpose:

Stop the fetch window at the level's edge, and while doing it find why the coarse fallback drew nonsense.

#### Outcome:

The fetch count is now the window or the part of it inside the level, whichever is smaller, in entries and with no straddle slack at the edge -- one entry of slack asks for the first tile of the level next door, which does not exist either -- and the coarse pass halves the limit again because its level is half as wide. The testbench had to learn the level's bounds first: it models both levels' tile grids and counts any request outside them, and before the fix it reproduced the board exactly, asking for `L1 3,0` where the grid is three wide. After it, a view hard against the level's right edge draws all sixty-four of its pixels with nothing asked for outside the grid. Underneath was a better find. `k0`, the window base the emit stage subtracts from the pixel's own entry index, was latched one state before the blocking fetch; a miss there flips the picture to the coarser level, so the fetch landed coarse rows under a fine base, `rd_idx` underflowed, and every pixel of a fallback line came from thirty-three entries away -- which is exactly the `0x37` measured against the `0xce` expected. `k0` now follows the window the rows actually arrived from, which is right for both paths and both scales, and the fallback line is pixel-exact in simulation for the first time since it was written. Two smaller things came out of the build. The critical path had moved to the request queue's `taken` bit running through `req_hold` into the loader's busy input and the transmitter's data mux and so into the UART's shift register, and it refused to pack at first: `req_hold` is registered now, one cycle of latency the loader cannot notice because it cannot offer a byte in the cycle it is told to wait. And the clamp's own arithmetic was cut from thirty-two bits to sixteen, since a level is at most 65535 pixels wide. The fallback's test also had two assertions that were simply wrong about the system: it demanded a line that never asks for another tile, which is a property of a fully resident view and not of streaming at all. Seventeen of seventeen testbenches pass with `check_render` and `check_tmds`, and eight of eight seeds pack from 80.84 to 92.28 MHz, seed 5 at 92.28. Nothing was deployed, on the user's instruction, so the board still runs `tinymaps.46ea1fa2bbf5.bin`. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

On hardware next: the same level-3 view, which should now stop asking for the tiles past the map's right edge -- the server no longer has to answer anything blank -- and a fine level, z15, where the pool cannot hold the view and the fallback, the re-requests and the epoch all do real work. That is also the first test where `k0`'s repair is exercised on the board. After that the request queue's pending set, prefetch and eviction, and 4bpp. The `TILE_RETRY` epoch is still 28 ms, chosen when a request was assumed to take a fifth of a tile's flight; a fine level will say whether that is the right number.

#### Files Modified:

- docs/HANDOFF.md
- docs/streaming-scope.md
- fpga/tinymaps/maps_render.sv
- fpga/tinymaps/maps_tile_req.sv
- sim/tb_maps_stream.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 43 COMMIT Unreleased 2026-10-27T14:30:08-07:00

#### Coming From:

Unreleased 23a5b9f

#### Purpose:

Fix the torn tiles the board showed under streaming, where the whole picture carried scattered wrong pixels and a pan turned it into a smear.

#### Outcome:

The user's report was scattered wrong pixels everywhere and, on the first mouse-driven pan, a vertical smear. The cause was in the fill, not the fetch: a slot's tag stayed valid for the whole 0.32 s a 64 KiB tile takes to arrive, so a lookup for the tile that was there *before* still hit and the renderer read a slot half old and half new. The commit ordering added two cycles ago protected the new tile and never protected the old one from being read while it was being overwritten. `maps_tiles` gained `fill_inval`, which clears the slot's valid bit, and `maps_link_rx` pulses it on a tile's first block -- the only point that knows the fill has begun -- so a slot being written is a miss and the renderer falls back to the level below for that line instead of drawing a tear. `sim/tb_maps_link_rx.sv` gained the test that states the guarantee: a tile is resident, its refill starts, a lookup must miss, and after the last block it must hit again. Writing that test also found the bench had never connected the loader's new output at all, which is how a check that looks like it exercises something can exercise nothing. One stale expectation fell out too: test 7 asserted exactly one commit, which a legitimate refill in the new test had made two, so it now compares against a mark. The same hardware run also bounded the pool: at z15 with a fallback behind it a screen wants about forty fine tiles and a dozen coarse ones, fifty-two of the pool's sixty-four slots, and on the board it livelocked on two tiles whose slots collided -- level 1 at `5,0` and level 0 at `6,0` both hash to slot 6. Sixty-four 64 KiB slots cannot hold that working set whatever the hash, so half-size tiles become the next thing that matters: at 4bpp the same 4 MiB holds 128 slots. Seventeen of seventeen testbenches pass with `check_render` and `check_tmds`, and eight of eight seeds pack from 76.18 to 87.27 MHz. Nothing was deployed; the board still runs `tinymaps.46884191295c.bin`, which is the build without this fix. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Deploy this and repeat the two hardware tests: level 3 should still be clean, and a level-1 view should now sharpen without the scattered wrong pixels and survive a mouse pan. The finest level will still thrash, because it is a pool-size problem rather than a tearing one -- so 4bpp is next: 32 KiB tiles, 128 slots, a nibble extractor in the pixel path and per-tile palettes in the pack. After that, the request queue's pending set and then prefetch and eviction, which need the pool to say when it is full.

#### Files Modified:

- docs/streaming-scope.md
- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/maps_tiles.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_link_rx.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 44 COMMIT Unreleased 2026-10-27T15:34:22-07:00

#### Coming From:

Unreleased 331dbfb

#### Purpose:

Fit a screen's working set into the tile pool, which is what the hardware showed was actually wrong.

#### Outcome:

Four bits a pixel was the obvious way to halve the tiles and it was the wrong lever, so it was not built: a four-bit index reaches sixteen colours, which means either one sixteen-colour palette for the whole map -- visibly worse than what is on the screen now -- or a palette per tile, and then the fabric needs a palette per tile and the pixel path has to blend across an entry boundary, because a sixteen-bit entry would hold four pixels instead of two. A 128-pixel tile at eight bits gets four times the slots with none of that cost: 16 KiB a tile, 256 slots in the same four megabytes, the same 256-entry palette, and the pixel path's arithmetic untouched -- an entry still holds two pixels and only the row stride changed, which was already a parameter of `maps_tile_addr`. `tools/maps_pack.py tiles --bits=8 --tile=128` writes the pack, since the tile size had been a constant of the tool rather than a property of a run: 1777 tiles over four levels in 27.77 MiB, verified tile by tile against its source, worst 6.4/255. `serve_tiles.py` takes the tile size from the pack's header, so a 128-pixel pack is served the same way as a 256-pixel one, 16 blocks a tile instead of 64. The top builds `TILE_PX=128` with 64 entries a row, fourteen bits of pool address and 256 slots. `sim/tb_maps_stream.sv` follows the same geometry, and its out-of-grid counter had to learn the tile size too -- it was still dividing by 256 and called five legitimate requests illegal. A z15 screen now wants about sixty fine tiles and fifteen coarse ones, seventy-five of two hundred and fifty-six slots, where before it wanted fifty-two of sixty-four: the difference between a pool that recycles slots the line is about to read and one that does not. Seventeen of seventeen testbenches pass with `check_render` and `check_tmds`, and eight of eight seeds pack from 77.35 to 86.26 MHz. Nothing was deployed; the user asked to wait for a go-ahead, and the board still runs `tinymaps.d09f77f17dd5.bin`. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Deploy on the user's word and repeat the level-3, level-1 and level-0 tests, then pan: the finest level should now hold its working set, which is the first time that is true. If the picture is clean, the remaining work is the request queue's pending set -- it still asks two or three times for a tile already on its way -- and then prefetch and eviction, which need the pool to say when it is full. Four bits a pixel stays available as a later saving, but only with a palette per tile and a pixel path that can blend across entries.

#### Files Modified:

- docs/streaming-scope.md
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_stream.sv
- tools/maps_pack.py
- tools/serve_tiles.py

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 45 COMMIT Unreleased 2026-10-27T16:44:12-07:00

#### Coming From:

Unreleased fcc6882

#### Purpose:

Record and fix the one-line top-level omission that stopped a 16 KiB tile from ever being committed.

#### Outcome:

The 128-pixel build went on the board and the picture asked for one tile for ever: `L1 6,9`, delivered, acknowledged and asked for again, 214 times in twenty-five seconds. The tile was landing and never becoming resident, and the cause was in `tinymaps_top` rather than in any module: `maps_link_rx` decides a tile is whole by comparing the block's end against its `TBYTES` parameter, and the instance was still taking the default 65536 while the pool was built for 16384, so the last block of a 16 KiB tile was never the last and the commit never happened. The instance now passes `TBYTES(TILE_PX * TILE_PX)`, the same expression the page table is given, so the two cannot disagree about how big a tile is. It is a wiring omission of exactly the kind nothing in the test suite can see: no testbench instantiates the top, and the loader's own test drives 64 KiB tiles, which is its default. Where a parameter has to mean the same thing in two instances, the honest fix is to derive both from one localparam rather than rely on a reader noticing. The build passes at 84.45 MHz at seed 1. Nothing was deployed: the Tang left USB between the build finishing and the upload starting, and only an unrelated ESP32 board is enumerated. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Deploy `tinymaps.aae022f453bf.bin` when the board is back and repeat the finest-level test with the 128-pixel pack: the level-0 view should now commit its tiles and hold them, which is the first time its working set fits. Then level 3 and level 1 as regressions, then a pan. After that, the request queue's pending set, then prefetch and eviction.

#### Files Modified:

- fpga/tinymaps/tinymaps_top.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 46 COMMIT Unreleased 2026-10-27T17:56:22-07:00

#### Coming From:

Unreleased 54455c9

#### Purpose:

Build the instrument the last several hardware runs needed: a way to see, from the host, which level and which tile the core is actually drawing from and where it read it.

#### Outcome:

The status command now answers four things it never did -- whether the picture is being drawn from the level below or the view's own level, and for the last successful lookup the level, the tile's coordinates and the pool address, all latched together so the pair is one fact rather than two live wires sampled at the same moment. The renderer exports its fallback flag, the sequencer latches the hit's coordinates with its address, and `tools/read_status.py` prints the slot the address implies beside the slot the table's hash would give for those coordinates -- which is the check that matters, because if the two disagree the core is reading a different tile from the one the host delivered and that is the glitched, stretched picture explained. Writing it found a bug in the instrument itself, and it is the third of its kind in this project: the new latch was cleared in the per-cycle default block instead of in reset, so it was wiped every cycle and reported that no lookup had ever hit, on hardware and in simulation both. One board run was spent reading a lie before the simulation caught it, which is the right order and the opposite of how the rest of the day went. With the clear moved to reset the simulation reports a self-consistent pair, level 1 tile 5,0 at 0x00118000, which is slot 6, and the table's hash for that tile is six. Also added: `tools/check_capture.py`, which renders what the pack says the viewport should show and compares a capture against it in standardised brightness -- that is how the user's settled frame was shown to match no region of the map at any level, which is what turned the search from rendering faults towards addressing. Seventeen of seventeen testbenches pass with `check_render` and `check_tmds`, and seed 1 packs at 84.68 MHz. Nothing was deployed, on the user's instruction, so the board still runs the previous build. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Deploy `tinymaps.f043c71f8be2.bin` when the user says so, serve a level-0 view until it settles, and read the status: the printed slot and the table's slot for the same tile either agree, which sends the search into the pixels within a tile -- the row stride or the window base -- or disagree, which names the addressing. The capture tool is there to confirm either answer against a screenshot with the same viewport.

#### Files Modified:

- fpga/tinymaps/maps_link_rx.sv
- fpga/tinymaps/maps_render.sv
- fpga/tinymaps/maps_tile_fetch.sv
- fpga/tinymaps/tinymaps_top.sv
- sim/tb_maps_stream.sv
- sim/tb_maps_tile_fetch.sv
- tools/check_capture.py
- tools/read_status.py

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 47 COMMIT Unreleased 2026-10-27T18:01:43-07:00

#### Coming From:

Unreleased ca999e1

#### Purpose:

Make the screen itself the measurement, since the picture is the only ground truth left that has not misled.

#### Outcome:

`tools/maps_pattern_pack.py` writes a tile pack whose tiles name themselves: each is a flat colour keyed to its own coordinates, with a white border on its top and left edges, and a binary code in its top-left corner giving its own `tx` and `ty`. The container is the same one `maps_pack.py tiles` writes and the level grids are the real pack's, so `serve_tiles.py` serves it and the same viewport applies without either tool knowing the difference -- the server's own selftest reassembles a 16 KiB tile from this pack and checks its CRCs. The palette is 256 distinct entries on three different odd steps, so an index is recoverable from a captured colour, and a tile decoded back from the file gives its own coordinates: tile (5,3) reads as tx 5, ty 3, flat index 26, borders white. That is what makes the picture readable rather than interpretable: a tile drawn in the wrong place is a wrong colour in the wrong square, a row stride that shears shows as a broken border running diagonally, and a window base that is off by an entry shows as a tile's worth of columns displaced by one. The reason for building it is the run before this one, where the status command's new fields could not answer whether the addressing was wrong: the coordinate and the address in that readout come from different stages of the pipeline -- `lk_addr` is the table's answer for the coordinates presented two cycles earlier while `lk_tx`/`lk_ty` are live wires -- so during retry churn they drift, and for one tile the same address appeared twice with different values. That reading is therefore recorded as unusable rather than as evidence. What that run did establish is that the picture is drawn from level 0 and not the fallback, that no tile outside the level's grid was asked for, and that 105 tiles committed and the requests stopped, so the 16 KiB fill path works. Nothing was deployed, on the user's instruction. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Deploy, serve a level-0 view from the pattern pack, and read the screen: the colour of each 128-pixel square names the tile that landed there and the corner code confirms it, so a misplaced tile, a shear or a displaced window becomes a specific, named fault rather than a description. That is the experiment that should have come before the last three fixes.

#### Files Modified:

- tools/maps_pattern_pack.py

#### Status:

- Build: N/A
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 48 COMMIT Unreleased 2026-10-27T19:34:24-07:00

#### Coming From:

Unreleased fb698de

#### Purpose:

Find out, by measurement rather than by another guess, why the picture on the Tang is stretched and smears on the first move, and fix what the measurement names.

#### Outcome:

The picture was not the loader, the pack, the palette or the addressing: it was the renderer failing to draw most of the lines the video stage offered, and the line store repeating the rows it had. `sim/tb_maps_line_budget.sv` is what made that a measurement rather than an argument -- the real renderer, the real chunk sequencer and the real page table at the top's own geometry, 1280 pixels and a 644-entry window in 128-pixel tiles, with the pool pre-filled so every fetch hits because what is under test is time and not data, and `cy` paced one line per 1650 clocks. With a pool answering every clock the engine kept up, which is why the other seventeen testbenches had never caught this: they all model a channel about twice as fast as the real one. At two clocks an entry -- the rate a 644-entry row at about 1340 clocks implies -- it completed 26 of 48 lines. The instrumented bench named the mechanism: a row fetch takes 1486 clocks against an emit of 1285, so the prefetch started at a line's `S_PLAN` landed about 200 clocks after the next line had begun, that line took the blocking path for three refetches and 4461 clocks, and emits went on starting alternately 1285 and 5963 clocks apart -- four row fetches per two lines where one would do, a 7248-clock period against a 1650-clock raster. The fix in `maps_render.sv` is a fourth row buffer, with a row's buffer now its own row number modulo four rather than a `cur`/`nxt`/`fre` rotation, so a line the raster skips is answered out of the buffers it should be answered from; each line fetches the row three on from its own first row, which gives that fetch two line times instead of one; and the prefetch is issued from `S_EMIT` as soon as the channel is free rather than only at the plan, because the request used to be dropped whenever the channel was still busy with the row started a line ago, and one dropped prefetch became a blocking path two lines later. A bounded `S_HOLD` state waits for a row already in flight when the line's own measured period has the slack for it, instead of refetching three rows the line cannot afford. The bench goes from 26/48 to 42/48 with zero blocking fetches after the cold start, and reports 26/48 with three of them when run against the pre-fix renderer at the same channel rate, so it measures the fault and not a coincidence; both versions pass at one clock an entry, which is why nothing had caught it. What is left is throughput rather than deadline -- one row per line needs better than 2.5 clocks an entry, which at 1340 clocks a row is 310 clocks of headroom a line and 1960 clocks of jitter absorbed in any single fetch -- and a 32-bit pool read is the change that doubles it if the channel is slower than measured. Eight seeds pack, 75.62 to 85.48 MHz, best at seed 3 at 85.48 MHz in `build/seed-3/open/tinymaps.a8ba28a06bf9.bin`, the same band this design sat in before the change, so the fourth buffer and the second row-address multiply cost nothing measurable; twenty of twenty simulations pass, `check_render` and `check_tmds` included, and `verilator --lint-only -Wall` reports no latches on the renderer. Nothing was deployed, on the user's instruction, so the board still runs the previous build. A core-syntax audit was performed over the `.ai` diff; `core.md` is unchanged and this entry follows the template, ordering, prose and status rules.

#### Next Steps:

Deploy `build/seed-3/open/tinymaps.a8ba28a06bf9.bin` when the user says so, serve the level-0 view from the real pack until it settles, then pan and zoom: the picture should be stable, sharp and unstretched while still, with no smear while moving. If lines are still short, the deciding measurement is `tb_maps_line_budget` at a slower `CHAN_CLOCKS`; the throughput headroom is 310 clocks a line, and a 32-bit pool read is the change that doubles it.

#### Files Modified:

- fpga/tinymaps/maps_render.sv
- sim/tb_maps_line_budget.sv
- docs/HANDOFF.md

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---
