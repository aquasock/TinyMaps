# Integration blocker: the pixel clock does not close

Status as of 2026-10-26. The integration is written but does not produce a
bitstream. This file records what was measured, so the next attempt starts from
the evidence rather than from the start.

## Symptom

```
FAIL hclk 69.08 MHz (constraint 74.25 MHz)
  critical path: 14.48 ns = 9.97 logic + 4.51 routing
  Source u_hdmi.u_hdmi.tmds_gen[0].tmds_channel.video_data_DFFRE_Q_4.Q
  Sink   u_hdmi.u_hdmi.tmds_gen[0].tmds_channel.acc_DFFRE_Q.D
```

Place and route completes; the gate refuses to pack.

## Why this is not a placement problem

TinyTang's desktop core, built on the same machine with the same toolchain
(oss-cad-suite yosys, nextpnr-himbaechel fork, apicula fork) and the same
`hdmi.sv`, routes its pixel clock at **110.67 MHz** — and the encoder is not
even its critical path:

```
desktop pixel_clk critical path: 9.04 ns, terminal-panel logic
```

So the toolchain is sound and the encoder can close at this clock on this part.

## What differs

Comparing the two pre-place-and-route netlists:

| | cells | serializer cluster | serializer LUT4 |
|---|---|---|---|
| TinyMaps | 6,511 | 545 | 208 |
| desktop  | 11,687 | 261 | 87 |

The serializer synthesises to roughly twice the logic in the smaller design,
and the critical path runs `video_data -> serializer muxes -> acc` where the
desktop's runs `video_data -> acc`. ABC's global restructuring merged the TMDS
serialiser's multiplexers into the encoder's disparity path. Both netlists infer
`OSER10` x 4, so the primitive itself is not the difference.

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
- **ABC9** — `synth_gowin -abc9` produced identical timing.

## What is left

1. **Get ABC to stop merging across the serialiser boundary.** `synth_gowin`
   gives no reachable lever for this: attributes are flattened away and `-abc9`
   changes nothing. It needs either a staged `synth_gowin -run` sequence with a
   custom `abc` script between, or synthesising the HDMI stage separately and
   stitching the netlists.
2. **Pipeline the encoder.** A register between `q_m` and the disparity
   accumulator shortens the path regardless of ABC. It costs one clock of
   latency, and HDMI pixel alignment is load-bearing here, so it must be
   compensated downstream and verified in simulation against the current
   behaviour — an encoder change that shifts one pixel looks right and is not.

Option 1 is the one to try first: it changes no logic and needs no new
simulation harness.

## Also outstanding

- `tinymaps.sdc` now declares `fclk` at 64.476 MHz. Nothing uses `fclk` while
  the design is single-domain, so that constraint is currently inert.
- The pack loader is not wired: `sdram_ctrl`'s A25 write port is idle and the
  viewport registers are constants, so the SDRAM holds nothing. `maps_link_rx`
  is finished and verified but needs a UART receiver and the `0xAA` frame parser
  in front of it.
