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
