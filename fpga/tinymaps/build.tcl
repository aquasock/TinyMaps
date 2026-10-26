# TinyMaps, GW5AST-138 revision C.  Gowin EDA comparison build; the open flow
# is tools/build_maps_core_open.sh.
# SPDX-License-Identifier: GPL-3.0-only
set_device GW5AST-LV138PG484AC1/I0 -device_version C
add_file -type cst src/tinymaps/tinymaps.cst
add_file -type sdc src/tinymaps/tinymaps.sdc
foreach source {
    src/tinymaps/pll/gowin_pll_27.v src/tinymaps/pll/gowin_pll_hdmi.v src/tinymaps/pll/gowin_pll_nes.v
    src/tinymaps/tinymaps_top.sv src/tinymaps/maps_link_rx.sv
    src/tinymaps/hdmi/audio_clock_regeneration_packet.sv src/tinymaps/hdmi/audio_info_frame.sv
    src/tinymaps/hdmi/audio_sample_packet.sv src/tinymaps/hdmi/auxiliary_video_information_info_frame.sv
    src/tinymaps/hdmi/hdmi.sv src/tinymaps/hdmi/packet_assembler.sv src/tinymaps/hdmi/packet_picker.sv
    src/tinymaps/hdmi/serializer.sv src/tinymaps/hdmi/source_product_description_info_frame.sv
    src/tinymaps/hdmi/tmds_channel.sv
} { add_file -type verilog $source }
set_option -synthesis_tool gowinsynthesis
set_option -top_module tinymaps_top
set_option -output_base_name tinymaps
set_option -verilog_std sysv2017
set_option -rw_check_on_ram 1
set_option -multi_boot 1
set_placement 2
if {$argc > 0} { set placement [lindex $argv 0] }
set_option -place_option $placement
run all
