# Integration timing: the pixel clock closes

Status as of 2026-10-26. The integration closes timing, packs a bitstream and
nothing has been deployed. This file records what was measured, what the fix
was, and what the earlier attempts ruled out, so the next cycle starts from the
evidence.

## Result

```
PASS clk    428.08 MHz  (constraint 21.49 MHz)
PASS hclk    84.28 MHz  (constraint 74.25 MHz)
setup=0 hold=0
```

At placement seed 1, after routing: `hclk` reaches 84.28 MHz against the
74.25 MHz a 720p line needs, a margin of 13.5%. The post-placement estimate was
76.93 MHz, so routing improved on it rather than eroding it.

Artefacts in `build/tinymaps/open-s1/`, named after their own sha256 prefix:

- `tinymaps.46bc5de68231.bin` — 4,399,798 bytes, the file for the card
- `tinymaps.46f5c35cbda5.fs` — 35,221,304 bytes, for openFPGALoader

A rebuild from an empty `build/` reproduced both hashes exactly.

The critical path is no longer in the HDMI encoder. It is now 11.87 ns in the
renderer's line buffer (`lbuf` → `lb2` write path), which leaves 1.6 ns inside
the 13.47 ns period of 74.25 MHz. `clk` is unchanged at 428.08 MHz against 21.49.

## The fix: one register inside the encoder

`fpga/tinymaps/hdmi/tmds_channel.sv` gained a pipeline register between the
first half of section 5.4.4.1 and the disparity decision:

- the coded byte `q_m` is registered;
- `mode`, `control_data` and `data_island_data` are registered with it, so the
  guard bands, control periods and island symbols still apply to the pixel they
  were chosen for;
- the counts `N1q_m07`/`N0q_m07` and the accumulator branch are computed from
  the registered byte, and `acc` resets on the registered `mode`.

All five signals move together on purpose. Delaying video alone would have
shifted the picture one pixel against its own sync and guard bands, which is the
failure mode that looks correct on a display.

The cost is one pixel of latency on every mode. It is not paid back anywhere:
the whole TMDS stream is one pixel later relative to the pixel counters, and
because the counters feed both the video and the sync through the same register,
the emitted frame is unchanged.

### It was verified, not assumed

`sim/tb_hdmi_encode.sv` drives three instances (CN = 0, 1, 2) through every mode
— all 256 input bytes four times over, every control word, all sixteen TERC4
symbols, both guard bands, and 2000 cycles of interleaved pseudo-random mode,
pixel, island and control words — and dumps the 10-bit word per channel per
pixel clock. `tools/check_tmds.py` recomputes the stream and discovers the
output delay by alignment rather than assuming it.

- Before the change: 3132 rows match the model at a delay of 0.
- After the change: 3131 rows match at a delay of 1.
- The two captures are identical row for row once that one-pixel offset is
  compensated.

So the encoder emits the same words it did before, one clock later. The whole
simulation suite still passes: `tb_maps_link_rx`, `tb_maps_render` with
`check_render` matching all five viewports, and `check_tmds`.

## Why it was short, and why it was not a placement problem

TinyTang's desktop core, built on the same machine with the same toolchain
(oss-cad-suite yosys, nextpnr-himbaechel fork, apicula fork) and the same
`hdmi.sv`, routes its pixel clock at **110.67 MHz** — and the encoder is not
even its critical path. So the toolchain is sound and the encoder can close at
this clock on this part.

Comparing the two pre-place-and-route netlists, the serializer synthesised to
roughly twice the logic in the smaller design:

| | cells | serializer cluster | serializer LUT4 |
|---|---|---|---|
| TinyMaps | 6,511 | 545 | 208 |
| desktop  | 11,687 | 261 | 87 |

ABC's global restructuring merged the TMDS serialiser's multiplexers into the
encoder's disparity path, so the critical path ran `video_data -> serializer
muxes -> acc` where the desktop's runs `video_data -> acc`. The pipeline
register cuts that merged cone at a flop, which ABC cannot retime across.

The failure this fixed, in the committed state before the change:

```
FAIL hclk 66.16 MHz (constraint 74.25 MHz)     worst path 15.11 ns
  Source ...tmds_channel.q_m...
  Sink   ...tmds_channel.acc...
```

An earlier build in the same investigation, before `rgb` was registered, failed
at 69.08 MHz with a 14.48 ns path. Both are failures; 66.16 MHz is the number
the committed state carried.

## Ruled out, with the measurement

- **Toolchain** — desktop core builds and routes here at 110.67 MHz.
- **Synthesis flow** — `diff` of `tools/maps_open/synth.ys` against
  `tools/desktop_open/synth.ys` shows only the source list differs.
- **Serialiser placement** — both put `gwSer0` at `X181Y102/IOLOGICAO`.
- **Planning sites** — the three `INS_LOC` PLL constraints are copied from the
  desktop cst.
- **Placement seed** — 1, 2, 3 give 69.12 / 68.86 / 65.05 MHz.
- **`div5` placement** — its absence was a hard routing failure
  (`hclk5 has no route to the FCLK of u_hdmi.serializer.gwSer0`); adding
  `INS_LOC "div5" RIGHTSIDE[4]` fixed routing but not timing.
- **Live vs constant `hdmi.reset`** — constant made no difference.
- **Clock domains** — moving `sdram_ctrl` and the renderer to `fclk` gave
  66.31 MHz; reverted, since it bought nothing.
- **Distributed-RAM line store** — the store had become 320 `RAM16SDP4` blocks
  with an asynchronous read (a 20k:1 mux on `hclk`, written on one clock and
  read on another, which is also the Apicula cross-clock hazard). Replaced with a
  synchronous block-RAM read; no timing change, but the structure is now correct.
- **Hierarchy boundary** — `setattr -mod -set keep_hierarchy 1` on `hdmi`,
  `serializer` and `tmds_channel` produced byte-identical timing;
  `synth_gowin` flattens regardless.
- **ABC9 flag** — `synth_gowin -abc9` produced identical timing (the pass chain
  already runs `abc9 -maxlut 8 -W 500` in `map_luts`, so the flag was a no-op).
- **Staged ABC at lower effort** — `synth_gowin -run begin:map_luts`, then
  `abc9 -maxlut 8 -W 100`, then `-run map_cells:`, gave **63.65 MHz**, worse.
- **`-noflatten`** — ABC can no longer merge across the boundary, but nextpnr
  then rejects the netlist with `Unconstrained IO: u_sdram.write_IBUF_I`, since
  IOBs are emitted inside modules. Would need `-noiopads`, which leaves the top
  ports without pad cells.
- **Registering `rgb`** — the HDMI input was a combinational `cy < OUT_H` mux
  where the desktop's is a flop output. Making it a register gave 66.16 MHz.

## Open question: the encoder's balanced-disparity branch

While building the harness, the encoder's section 5.4.4.1 coding was compared
against a transcription of Figure 5-7 and the two disagree in one branch — the
one taken when the accumulator is zero or the two counts are equal. The module
sends `q_m` uncomplemented when `q_m[8]` is set and complemented when it is
clear; a Figure 5-7 transcription pairs those the other way round. Both pairings
keep the accumulator tracking the true disparity of the emitted stream, and both
produce words a TMDS sink can decode, so this is a DC-balance convention rather
than a visible defect.

`fpga/tinymaps/hdmi/tmds_channel.sv` is byte-identical to upstream
`hdl-util/hdmi` (`src/tmds_channel.sv`, master), so this is upstream's
convention and not a change made here. It was **not** changed: settling which
pairing the standard mandates needs the specification text, `core-reference.md`
does not carry it, and the encoder is not the subject of this cycle.
`tools/check_tmds.py` therefore reproduces the module's convention and gates the
stream against it; it is a regression check, not a conformance claim.

The popcount that feeds that decision is written as a sum of single bits inside
a `case` selector, which Verilator's lint flags as one bit wide where four are
expected. Yosys elaborates it as the full four-bit count: `equiv_simple` proves
the file as written equivalent to a variant whose sum is explicitly widened to
four bits, and Verilator and iverilog simulate the same stream. The lint warning
is cosmetic here, and the stream the harness gates is the stream the bitstream
emits.

## Also outstanding

- `tinymaps.sdc` declares `fclk` at 64.476 MHz. Nothing uses `fclk` while the
  design is single-domain, so that constraint is inert.
- The pack loader is not wired: `sdram_ctrl`'s A25 write port is idle and the
  viewport registers are constants, so the SDRAM holds nothing. `maps_link_rx`
  is finished and verified but needs a UART receiver and the `0xAA` frame parser
  in front of it.
- Nothing has been deployed. The bitstream exists and the user has not asked for
  it to be put on the Tang.
