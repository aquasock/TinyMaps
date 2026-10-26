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
