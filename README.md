# TinyMaps

A map viewer core for TinyTang. Pan and zoom a pre-rendered OpenTopoMap-style
raster held in the dock SDRAM, at 1280x720.

Target: GW5AST-LV138PG484AC1/I0, revision C, open flow (yosys, nextpnr-himbaechel
and the apicula fork).

## State

Phases 0 to 3 are done and verified by simulation. The integration **closes
timing** -- `hclk` at 83.06 MHz against the 74.25 MHz a 720p line needs, at
placement seed 1 -- so the flow packs a bitstream, and that bitstream runs on
the Tang. The pack loader works on hardware too: an image sent over the BL616's
UART lands in the SDRAM and is drawn, which was checked on 2026-10-26 with a
known test image rather than by eye. An image appears in grey until a palette is
sent with it, and with the pack's palette the real map is on screen.

Panning and zooming work, and `tools/read_status.py` reports the viewport the
renderer is being given -- which is how the level-table defects that froze the
picture into one repeated row were found. The top few lines of a frame were
corrupt for a while; the cause was a refetch that landed after the line needing
it, and the fix is in, though it has not been confirmed on hardware separately
from panning. The first hardware capture also showed the levels
lifted and clipped at the top -- the sink reading full-range RGB as limited
range -- so the AVI InfoFrame now declares full range, and that build is on the
board. The declaration does not change what a capture of the output shows: the
levels still arrive lifted, because the capture path applies its own
limited-range expansion whatever the source declares. The display is the
authority for how the picture looks, not the capture, and a capture is only a
reliable measure of geometry and relative brightness. `docs/HANDOFF.md` holds the state, the decisions
and the next action; `docs/integration-blocker.md` holds the timing
measurements, the fix and the levers that were ruled out.

## Building

    tools/build_maps_core_open.sh

Needs oss-cad-suite, the nextpnr-himbaechel fork built against a regenerated
GW5AST-138C database, and the apicula fork. The defaults are this machine's:

- `NEXTPNR_BUILD=/home/vash/tools/nextpnr-mathieufro`
- `APICULA_FORK=/run/media/vash/GIT/apicula-mathieufro`

The flow refuses to pack a netlist with setup or hold violations. Artefacts
land in `build/tinymaps/open-s<seed>/`, named after their own sha256 prefix.

`fpga/tinymaps/tinymaps_top.sv` carries the renderer `maps_render.sv`, its row
adapter `maps_video_rd.sv`, the SDRAM engine `sdram_ctrl.sv` (vended from
TinyNES's `ahb_sdram.sv`, renamed only), the HDMI stage `maps_hdmi.sv` and the
load path: `maps_uart_rx.sv` and `maps_uart_tx.sv` on the BL616's link and
`maps_link_rx.sv` behind them. The viewport registers are constants and the
palette is still a grey ramp in fabric, so a loaded image is shown through that
ramp rather than in its own colours.

## Simulation

    tools/run_sim.sh                 # every sim/tb_*.sv
    tools/run_sim.sh tb_maps_link_rx

Verilator `--binary --timing`; each testbench prints `RESULT: PASS` or
`RESULT: FAIL` and the script's exit code follows it. `tb_maps_uart` carries
bytes both ways over the link's wire format, with jitter on every bit edge and a
framing error, and then sends the same bytes out through the transmitter and
back in through the receiver. Two testbenches only capture data, and their
captures are judged afterwards by a separate checker: `tools/check_render.py`
for the emitted pixels and `tools/check_tmds.py` for the coded TMDS stream.

## HDMI encoder

`fpga/tinymaps/hdmi/tmds_channel.sv` pipelines section 5.4.4.1: the coded byte
`q_m` is registered together with `mode`, `control_data` and `data_island_data`,
and the disparity decision is taken from the registered byte. The register is
what lets `hclk` close -- ABC had merged the serialiser's multiplexers into the
encoder's disparity path -- and it costs one pixel of latency, shared by every
mode so the picture does not shift against its own sync and guard bands.

The AVI InfoFrame declares full-range RGB (`RGB_QUANTIZATION_RANGE = 2'b01`,
set in `maps_hdmi.sv` and carried through `hdmi.sv` and `packet_picker.sv`,
whose defaults are unchanged). The first hardware capture is why: the sink read
the RGB as limited range, so index 236 arrived as 255 and everything above it
clipped to white. `sim/tb_avi_range.sv` builds the packet both ways and checks
the field by byte, since a field in the wrong bit position still looks set in
the source.

`sim/tb_hdmi_encode.sv` drives the three channels through every coding mode and
`tools/check_tmds.py` recomputes the stream, discovering the output delay by
alignment rather than assuming it. It reproduces the module's own coding
conventions and gates the stream as a regression check; it is not a conformance
claim, and the one known difference from a Figure 5-7 transcription is recorded
in `docs/integration-blocker.md`.

## Load receiver

`maps_link_rx` takes the BL616's command `0x07` payload stream after
`iosys_bl616`'s `0xAA` frame parser and runs TinyNES's load semantics with the
destination being an SDRAM byte address:

    header, 5 words little-endian
      0 magic 'TML1' (0x314c4d54)   1 SDRAM byte address (8-byte aligned)
      2 length                      3 image CRC-32 (complemented)
      4 header CRC-32 over the first 16 bytes (complemented)
    then ceil(length / 8192) blocks, each up to 8192 bytes + its CRC-32

Answered ACK 0x06 or NAK 0x15 then a letter: 'H' header CRC, 'C' block CRC,
'I' image CRC, 'T' timeout. A NAKed block is re-sent from its own address.

The receiver parses the link's frames itself -- `0xAA len_hi len_lo cmd
payload`, the length big-endian counting the command byte and below 2048 -- and
takes the payload of command `0x07`. `maps_uart_rx` and `maps_uart_tx` carry the
2 Mbaud wire at 74.25 MHz, and the loader writes through `sdram_ctrl`'s A25
port, which the renderer never touches: the controller arbitrates and gives the
video line priority.

Loading an image from the host:

    tools/maps_test_image.py                 # work/test/test-image.bin
    tools/load_image.py work/test/test-image.bin

`load_image.py` asks the board whether its console is at a shell prompt, runs
`fpgapipe` to hand the console to the core, then sends the header and blocks,
framing everything and waiting for each answer. The test image is a 12 by 12
grid of flat cells stepping from white at the top left to black at the bottom
right, which the shipped viewport constants (768x768 level, 0.6 source pixels
per output pixel) draw as a staircase filling the line.

The palette arrives on command `0x08`, parsed by the same receiver:

    u16 start    first entry, 0-255        u16 count   entries that follow
    count * 3    R, G, B each              u32 crc     over the bytes above

Answered ACK, or NAK 'P' for a bad CRC. Entries are written as they arrive, so a
refused palette has already been applied and the sender re-sends it. The fabric
fills a grey ramp at power-on and the link owns the table afterwards.

    tools/load_palette.py                     # the pack's own 256 entries
    tools/maps_pack.py extract work/pack/phoenix-18km.tmpk 3
    tools/load_image.py work/test/level3.bin

The viewport -- which level, and where in it -- arrives on command `0x0A`:

    u32 level_base    u16 level_w, level_h    u32 step (Q16.16)
    u32 src_x0, src_y0 (Q16.16)               u32 crc

Answered ACK, or NAK `'V'` unless `0.25 < step <= 1` and the level fits in the
SDRAM; nothing is latched on a refusal. The range is the renderer's operating
limit and is enforced in the fabric, not trusted from the host.

    tools/load_pack.py                          # palette and all four levels
    tools/set_levels.py                         # the table the zoom crosses with
    tools/set_view.py --level 3                 # show one, at its own scale

`load_pack.py` puts 28 MiB in the SDRAM in about two and a half minutes and
`set_view.py` switches between the loaded levels with no reload, choosing a step
of 1.0 or, for a level narrower than the screen, enough magnification to fill
it -- 768 columns across 1280 is 0.6.

## Pan and zoom

The board's Bluetooth mouse and keyboard drive the view, over the same link:

- command `0x16` is the mouse -- `ff ff buttons dx dy wheel` -- and moves the
  view by whole 8-pixel nudges, the remainder kept for the next report; the
  wheel zooms.
- command `0x17` is the keyboard, the HID boot report.  Arrows pan 64 pixels,
  `=` and `-` zoom.  A boot keyboard reports state rather than events, so a held
  key is one report: the keys do not repeat.
- command `0x0B` loads the level table, `u8 count` then per level
  `{u32 base, u16 w, u16 h}` and a CRC.

`tools/read_status.py` asks the core what the renderer is being told: command
`0x0C` returns twenty-one raw bytes, the level address, size, step, origin and
the line engine's state.  A picture that freezes into one repeated row means a
zero level width, and a readback is the only way to see that from outside.

`maps_nav.sv` does the arithmetic.  Zooming is multiplicative: a turn multiplies
the step by about 1/1.078, nine steps to the octave, keeping the centre of the
screen on the same ground point.  When the step reaches 0.5 it crosses to the
next finer level and normalises to exactly 1.0, so the rounding never
accumulates; the coarsest level tops out at 1.0.  Because the pack's levels are
a factor of two apart in metres per pixel, a crossing is a doubling or halving
of the source coordinates and nothing else.

Below 0.5 the step is magnification rather than a finer level, and only the
finest level has no finer neighbour -- so that is where it is allowed, down to
0.25, four output pixels per source pixel.  The whole range is 32x: 16x across
the four levels and 2x more at the close end.  Nothing in it multiplies two
variables: the zoom factors are shifts and adds of the step.

A host viewport command replaces the view and clears any unapplied pan.  Both
writers go to a shadow, and the shadow is swapped in at the top of the vertical
blanking: a viewport change costs the renderer a blocking refetch of two rows,
about 2680 clocks against the 1650 a line has, so applying one mid-frame tore the
picture.

Not implemented yet: the loader has no idle timeout (the `TIMEOUT` parameter is
unused).

## Map packs

`tools/maps_pack.py` builds a pack from OpenTopoMap tiles.

    tools/maps_pack.py plan      # level table and SDRAM budget, no network
    tools/maps_pack.py fetch     # populate ~/.cache/tinymaps/tiles
    tools/maps_pack.py pack      # build work/pack/phoenix-18km.tmpk
    tools/maps_pack.py verify <pack>
    tools/maps_pack.py preview <pack>

A pack holds four tile-aligned levels of one 18.4 km square, finest first, as
8-bit indices into one shared 256-entry palette:

| level | zoom | merc m/px | raster | size |
|---|---|---|---|---|
| L0 | z15 | 4.777 | 4608x4608 | 20.25 MiB |
| L1 | z14 | 9.555 | 2304x2560 | 5.62 MiB |
| L2 | z13 | 19.109 | 1280x1280 | 1.56 MiB |
| L3 | z12 | 38.219 | 768x768 | 0.56 MiB |

28.00 MiB total, 87.5% of the dock's 32 MiB SDRAM.

Pack layout, little-endian:

    0    u32  magic 'TMPK'
    4    u16  version = 1
    6    u16  level count
    8    u32  palette offset
    12   u32  palette length
    16   u32  total bytes
    20   u32  header CRC-32 (over the header with this field zeroed,
                             plus the level table and the palette)
    24   u8   name[32]
    56   level table, 40 bytes each:
           u32 data offset, u32 width, u32 height, u32 m/px Q16.16,
           u32 zoom, i32 origin 3857 x, i32 origin 3857 y,
           u32 tiles x, u32 tiles y, u32 raster CRC-32
    then the palette, then the rasters back to back.

Origins are the EPSG:3857 metres of the level's pixel (0,0) centre. Coarser
levels are tile-aligned supersets of L0's ground rectangle, so each carries its
own origin.

## Renderer

`maps_render` draws one output line from one source row, with the viewport in
the level's own pixel space (`src_x0`, `src_y0`, `step_x`, `step_y`, Q16.16).
A row window is fetched into block RAM as 16-bit entries of two adjacent 8-bit
pixels and each output pixel costs one block RAM read plus a 256-entry palette
lookup. `tools/check_render.py` recomputes what the testbench ran from the
parameters it wrote out and compares every pixel.

Resampling is bilinear, with a nearest path for comparison. Three row buffers
are kept: two are read for the current line and the third is prefetched during
it. The testbench checks `fetch_count`, which exposes whether row reuse and the
overlapped prefetch are actually happening rather than silently falling back.

`step_x` and `step_y` are source pixels per output pixel, so **magnifying means
step below 1**. The level selector must keep them in `(0.5, 1]`: above 1 a source
row can advance by two per output line, consecutive line pairs share no row, and
no rotation is possible. That is a level-selection rule, not a renderer bug.

What the fetch counter says:

- `step_y = 0.750` (bilinear): 38 fetches for 48 lines. Fewer than one per line,
  because at magnification the row sometimes does not advance at all.
- `step_y = 1.000` (nearest): 50 fetches for 48 lines against 49 ideal.
- `step_y` 1.500, 1.750 and 1.990: 96, 120 and 144. Correct output, but two per
  line, so the rotation never engages. Those steps are outside the operating
  range; a level selector that kept them there would be misconfigured, and the
  renderer degrades to correct-but-slow rather than wrong.

In range, a line costs at most one row fetch of SPAN = 1284 entries, one entry
per cycle, overlapped with the 1280 emits, inside the 1650 clocks a 720p line
has. That is the real-time budget and it is met by construction; what is not yet
measured is whether the SDRAM delivers a row in 1284 cycles, which is
integration's question.

## Attribution

The pack is built from OpenTopoMap tiles. A shipped core or pack must carry:
"(c) OpenStreetMap contributors, SRTM | Map style (c) OpenTopoMap (CC-BY-SA)".
OpenTopoMap tiles are CC-BY-SA 4.0 and the underlying data is ODbL 1.0. The tile
cache is not part of this repository and the served tiles are not redistributed
here.

## Licence

GPL-3.0-only. `fpga/tinymaps/hdmi/` and `pll/` derive from nestang by
nand2mario (GPL-3.0), and the open-flow scripts derive from TinyTang's
`tools/desktop_open`. The pack builder `tools/maps_pack.py` is MIT.
