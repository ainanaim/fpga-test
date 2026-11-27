# The PS-generated DP video clock is not auto-constrained; define it so the
# video-domain logic (v_tc, v_axi4s_vid_out, CDC sync stages) has a timing clock.
create_clock -name dp_video_ref_clk -period 6.734 [get_pins -filter {REF_PIN_NAME =~ DPVIDEOREFCLK} -of_objects [get_cells -hierarchical -filter {REF_NAME == PS8}]]
