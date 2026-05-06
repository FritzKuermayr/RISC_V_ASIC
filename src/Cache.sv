`default_nettype none

import const_pkg::*;

// 4 KB, 2-way set-associative, write-back cache.
// Data SRAM address layout: {way, set, beat}; four SRAMs hold the four words
// in each 128-bit memory beat. Metadata SRAM address layout: {way, set}.
// Because there is only one metadata SRAM port, way lookups are serialized.
// The register-side hot-line/beat buffers make the common repeated/sequential
// access path ready in the same cycle, which is especially important for I$.
module cache #(
  parameter int unsigned NUM_WAYS       = 2,
  parameter int unsigned LINES          = 64,
  parameter int unsigned CPU_WIDTH      = CPU_INST_BITS,
  parameter int unsigned WORD_ADDR_BITS = CPU_ADDR_BITS - $clog2(CPU_INST_BITS/8)
) (
  input  logic                         clk,
  input  logic                         reset,

  input  logic                         cpu_req_valid,
  output logic                         cpu_req_ready,
  input  logic [WORD_ADDR_BITS-1:0]    cpu_req_addr,
  input  logic [CPU_WIDTH-1:0]         cpu_req_data,
  input  logic [3:0]                   cpu_req_write,

  output logic                         cpu_resp_valid,
  output logic [CPU_WIDTH-1:0]         cpu_resp_data,

  output logic                         mem_req_valid,
  input  logic                         mem_req_ready,
  output logic [WORD_ADDR_BITS-1:$clog2(MEM_DATA_BITS/CPU_WIDTH)] mem_req_addr,
  output logic                         mem_req_rw,
  output logic                         mem_req_data_valid,
  input  logic                         mem_req_data_ready,
  output logic [MEM_DATA_BITS-1:0]     mem_req_data_bits,
  output logic [(MEM_DATA_BITS/8)-1:0] mem_req_data_mask,

  input  logic                         mem_resp_valid,
  input  logic [MEM_DATA_BITS-1:0]     mem_resp_data
);

  localparam int unsigned SETS           = LINES / NUM_WAYS;
  localparam int unsigned WAY_BITS       = $clog2(NUM_WAYS);
  localparam int unsigned WORDS_PER_LINE = 16;
  localparam int unsigned LINE_BITS      = WORDS_PER_LINE * CPU_WIDTH;
  localparam int unsigned BEATS_PER_LINE = LINE_BITS / MEM_DATA_BITS;
  localparam int unsigned WORDS_PER_BEAT = MEM_DATA_BITS / CPU_WIDTH;
  localparam int unsigned BEAT_BITS      = $clog2(BEATS_PER_LINE);
  localparam int unsigned WORD_IN_BEAT_B = $clog2(WORDS_PER_BEAT);
  localparam int unsigned OFFSET_BITS    = $clog2(WORDS_PER_LINE);
  localparam int unsigned INDEX_BITS     = $clog2(SETS);
  localparam int unsigned TAG_BITS       = WORD_ADDR_BITS - INDEX_BITS - OFFSET_BITS;
  localparam int unsigned MEM_ADDR_LSB   = $clog2(WORDS_PER_BEAT);
  localparam int unsigned INIT_BITS      = $clog2(LINES);
  localparam int unsigned META_PAD_BITS  = 32 - TAG_BITS - 2;

  typedef enum logic [3:0] {
    S_INIT      = 4'd0,
    S_IDLE      = 4'd1,
    S_LOOKUP    = 4'd2,
    S_WB_ADDR   = 4'd3,
    S_WB_DATA   = 4'd4,
    S_READ_ADDR = 4'd5,
    S_READ_DATA = 4'd6
  } state_t;

  state_t state, state_n;

  logic [OFFSET_BITS-1:0]    cpu_offset;
  logic [INDEX_BITS-1:0]     cpu_index;
  logic [TAG_BITS-1:0]       cpu_tag;
  logic [BEAT_BITS-1:0]      cpu_beat;
  logic [WORD_IN_BEAT_B-1:0] cpu_word_in_beat;

  assign cpu_offset       = cpu_req_addr[OFFSET_BITS-1:0];
  assign cpu_index        = cpu_req_addr[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
  assign cpu_tag          = cpu_req_addr[WORD_ADDR_BITS-1:OFFSET_BITS+INDEX_BITS];
  assign cpu_beat         = cpu_offset[OFFSET_BITS-1:WORD_IN_BEAT_B];
  assign cpu_word_in_beat = cpu_offset[WORD_IN_BEAT_B-1:0];

  logic [TAG_BITS-1:0]       req_tag_r;
  logic [INDEX_BITS-1:0]     req_index_r;
  logic [BEAT_BITS-1:0]      req_beat_r;
  logic [WORD_IN_BEAT_B-1:0] req_word_in_beat_r;
  logic [3:0]                req_write_r;
  logic [CPU_WIDTH-1:0]      req_data_r;

  logic [INIT_BITS-1:0] init_cnt_r, init_cnt_n;
  logic [BEAT_BITS-1:0] beat_cnt_r, beat_cnt_n;
  logic                 served_q, served_n;

  logic [WAY_BITS-1:0] lookup_way_r, lookup_way_n;
  logic [WAY_BITS-1:0] victim_way_r;
  logic [TAG_BITS-1:0] victim_tag_r;

  logic                way0_valid_r;
  logic                way0_dirty_r;
  logic [TAG_BITS-1:0] way0_tag_r;

  logic [WAY_BITS-1:0] repl_way [0:SETS-1];
  integer reset_i;

  logic                            tag_ce, tag_we;
  logic [3:0]                      tag_wmask;
  logic [WAY_BITS+INDEX_BITS-1:0]  tag_addr;
  logic [31:0]                     tag_din, tag_dout;

  logic                tag_dout_valid;
  logic                tag_dout_dirty;
  logic [TAG_BITS-1:0] tag_dout_tag;

  assign tag_dout_tag   = tag_dout[TAG_BITS-1:0];
  assign tag_dout_valid = tag_dout[TAG_BITS];
  assign tag_dout_dirty = tag_dout[TAG_BITS+1];

  logic                                  data_ce;
  logic [WAY_BITS+INDEX_BITS+BEAT_BITS-1:0] data_addr;
  logic        data_we    [0:WORDS_PER_BEAT-1];
  logic [3:0]  data_wmask [0:WORDS_PER_BEAT-1];
  logic [31:0] data_din   [0:WORDS_PER_BEAT-1];
  logic [31:0] data_dout  [0:WORDS_PER_BEAT-1];

  logic                  linebuf_valid;
  logic [WAY_BITS-1:0]   linebuf_way;
  logic [TAG_BITS-1:0]   linebuf_tag;
  logic [INDEX_BITS-1:0] linebuf_index;
  logic [LINE_BITS-1:0]  linebuf_line;

  logic [WAY_BITS-1:0]      beatbuf_way;
  logic                     beatbuf_valid;
  logic [TAG_BITS-1:0]      beatbuf_tag;
  logic [INDEX_BITS-1:0]    beatbuf_index;
  logic [BEAT_BITS-1:0]     beatbuf_beat;
  logic [MEM_DATA_BITS-1:0] beatbuf_data;

  logic [LINE_BITS-1:0] refill_line_r;

  function automatic logic [31:0] make_meta(
    input logic                 dirty,
    input logic                 valid,
    input logic [TAG_BITS-1:0]  tag
  );
    make_meta = {{META_PAD_BITS{1'b0}}, dirty, valid, tag};
  endfunction

  function automatic logic [CPU_WIDTH-1:0] get_word_from_line(
    input logic [LINE_BITS-1:0]   line,
    input logic [OFFSET_BITS-1:0] offset
  );
    get_word_from_line = line[offset * CPU_WIDTH +: CPU_WIDTH];
  endfunction

  function automatic logic [LINE_BITS-1:0] set_word_in_line(
    input logic [LINE_BITS-1:0]   line,
    input logic [OFFSET_BITS-1:0] offset,
    input logic [CPU_WIDTH-1:0]   word
  );
    logic [LINE_BITS-1:0] tmp;
    begin
      tmp = line;
      tmp[offset * CPU_WIDTH +: CPU_WIDTH] = word;
      set_word_in_line = tmp;
    end
  endfunction

  function automatic logic [CPU_WIDTH-1:0] get_word_from_beat(
    input logic [MEM_DATA_BITS-1:0]  beat,
    input logic [WORD_IN_BEAT_B-1:0] word_idx
  );
    get_word_from_beat = beat[word_idx * CPU_WIDTH +: CPU_WIDTH];
  endfunction

  function automatic logic [MEM_DATA_BITS-1:0] set_word_in_beat(
    input logic [MEM_DATA_BITS-1:0]  beat,
    input logic [WORD_IN_BEAT_B-1:0] word_idx,
    input logic [CPU_WIDTH-1:0]      word
  );
    logic [MEM_DATA_BITS-1:0] tmp;
    begin
      tmp = beat;
      tmp[word_idx * CPU_WIDTH +: CPU_WIDTH] = word;
      set_word_in_beat = tmp;
    end
  endfunction

  function automatic logic [LINE_BITS-1:0] set_beat_in_line(
    input logic [LINE_BITS-1:0]       line,
    input logic [BEAT_BITS-1:0]       beat_idx,
    input logic [MEM_DATA_BITS-1:0]   beat
  );
    logic [LINE_BITS-1:0] tmp;
    begin
      tmp = line;
      tmp[beat_idx * MEM_DATA_BITS +: MEM_DATA_BITS] = beat;
      set_beat_in_line = tmp;
    end
  endfunction

  function automatic logic [CPU_WIDTH-1:0] merge_word(
    input logic [CPU_WIDTH-1:0] old_word,
    input logic [CPU_WIDTH-1:0] new_word,
    input logic [3:0]           mask
  );
    logic [CPU_WIDTH-1:0] tmp;
    begin
      tmp = old_word;
      if (mask[0]) tmp[7:0]   = new_word[7:0];
      if (mask[1]) tmp[15:8]  = new_word[15:8];
      if (mask[2]) tmp[23:16] = new_word[23:16];
      if (mask[3]) tmp[31:24] = new_word[31:24];
      merge_word = tmp;
    end
  endfunction

  logic linebuf_hit;
  logic beatbuf_hit;
  logic hot_hit;
  logic [WAY_BITS-1:0] hot_way;
  logic [CPU_WIDTH-1:0] hot_word_old;
  logic [CPU_WIDTH-1:0] hot_word_new;
  logic [LINE_BITS-1:0] hot_line_new;
  logic [MEM_DATA_BITS-1:0] hot_beat_new;

  assign linebuf_hit =
      linebuf_valid && (linebuf_tag == cpu_tag) && (linebuf_index == cpu_index);

  assign beatbuf_hit =
      beatbuf_valid && (beatbuf_tag == cpu_tag) &&
      (beatbuf_index == cpu_index) && (beatbuf_beat == cpu_beat);

  assign hot_hit =
      linebuf_hit || (!linebuf_hit && beatbuf_hit);

  assign hot_way =
      linebuf_hit ? linebuf_way : beatbuf_way;

  assign hot_word_old =
      linebuf_hit ? get_word_from_line(linebuf_line, cpu_offset)
                  : get_word_from_beat(beatbuf_data, cpu_word_in_beat);

  assign hot_word_new =
      merge_word(hot_word_old, cpu_req_data, cpu_req_write);

  assign hot_line_new =
      set_word_in_line(linebuf_line, cpu_offset, hot_word_new);

  assign hot_beat_new =
      set_word_in_beat(beatbuf_data, cpu_word_in_beat, hot_word_new);

  logic sram_hit;
  logic [MEM_DATA_BITS-1:0] sram_beat;
  logic [CPU_WIDTH-1:0]     sram_word_old;
  logic [CPU_WIDTH-1:0]     sram_word_new;
  logic [MEM_DATA_BITS-1:0] sram_beat_new;

  assign sram_hit = tag_dout_valid && (tag_dout_tag == req_tag_r);
  assign sram_beat = {data_dout[3], data_dout[2], data_dout[1], data_dout[0]};
  assign sram_word_old = data_dout[req_word_in_beat_r];
  assign sram_word_new = merge_word(sram_word_old, req_data_r, req_write_r);
  assign sram_beat_new = set_word_in_beat(sram_beat, req_word_in_beat_r, sram_word_new);

  logic [WAY_BITS-1:0] victim_way_sel;
  logic                victim_dirty_sel;
  logic [TAG_BITS-1:0] victim_tag_sel;

  always_comb begin
    if (!way0_valid_r) begin
      victim_way_sel = WAY_BITS'(0);
    end else if (!tag_dout_valid) begin
      victim_way_sel = WAY_BITS'(1);
    end else begin
      victim_way_sel = repl_way[req_index_r];
    end

    victim_dirty_sel =
        (victim_way_sel == WAY_BITS'(0)) ? way0_dirty_r : tag_dout_dirty;
    victim_tag_sel =
        (victim_way_sel == WAY_BITS'(0)) ? way0_tag_r : tag_dout_tag;
  end

  logic [CPU_WIDTH-1:0] refill_word_old;
  logic [CPU_WIDTH-1:0] refill_word_new;
  logic [MEM_DATA_BITS-1:0] refill_beat_new;
  logic [LINE_BITS-1:0] refill_line_new;

  assign refill_word_old = get_word_from_beat(mem_resp_data, req_word_in_beat_r);
  assign refill_word_new = merge_word(refill_word_old, req_data_r, req_write_r);
  assign refill_beat_new =
      ((req_write_r != 4'b0000) && (beat_cnt_r == req_beat_r))
        ? set_word_in_beat(mem_resp_data, req_word_in_beat_r, refill_word_new)
        : mem_resp_data;
  assign refill_line_new = set_beat_in_line(refill_line_r, beat_cnt_r, refill_beat_new);

  logic [WORD_ADDR_BITS-1:MEM_ADDR_LSB] refill_mem_addr;
  logic [WORD_ADDR_BITS-1:MEM_ADDR_LSB] wb_mem_addr;

  assign refill_mem_addr = {req_tag_r, req_index_r, {BEAT_BITS{1'b0}}};
  assign wb_mem_addr     = {victim_tag_r, req_index_r, beat_cnt_r};

  always_comb begin
    cpu_req_ready      = 1'b0;
    cpu_resp_valid     = 1'b0;
    cpu_resp_data      = '0;

    mem_req_valid      = 1'b0;
    mem_req_addr       = '0;
    mem_req_rw         = 1'b0;
    mem_req_data_valid = 1'b0;
    mem_req_data_bits  = '0;
    mem_req_data_mask  = '0;

    tag_ce    = 1'b0;
    tag_we    = 1'b0;
    tag_wmask = 4'h0;
    tag_addr  = '0;
    tag_din   = '0;

    data_ce   = 1'b0;
    data_addr = '0;
    data_we    = '{default: 1'b0};
    data_wmask = '{default: 4'h0};
    data_din   = '{default: '0};

    state_n      = state;
    init_cnt_n   = init_cnt_r;
    beat_cnt_n   = beat_cnt_r;
    lookup_way_n = lookup_way_r;
    served_n     = served_q;

    unique case (state)
      S_INIT: begin
        tag_ce    = 1'b1;
        tag_we    = 1'b1;
        tag_wmask = 4'hF;
        tag_addr  = init_cnt_r;
        tag_din   = '0;

        if (&init_cnt_r) begin
          init_cnt_n = '0;
          state_n    = S_IDLE;
        end else begin
          init_cnt_n = init_cnt_r + 1'b1;
        end
      end

      S_IDLE: begin
        cpu_req_ready = !cpu_req_valid || hot_hit;
        served_n      = 1'b0;

        if (cpu_req_valid && hot_hit) begin
          if (cpu_req_write == 4'b0000) begin
            cpu_resp_valid = 1'b1;
            cpu_resp_data  = hot_word_old;
          end else begin
            data_ce                          = 1'b1;
            data_addr                        = {hot_way, cpu_index, cpu_beat};
            data_we   [cpu_word_in_beat]     = 1'b1;
            data_wmask[cpu_word_in_beat]     = cpu_req_write;
            data_din  [cpu_word_in_beat]     = cpu_req_data;

            tag_ce    = 1'b1;
            tag_we    = 1'b1;
            tag_wmask = 4'hF;
            tag_addr  = {hot_way, cpu_index};
            tag_din   = make_meta(1'b1, 1'b1, cpu_tag);
          end
        end else if (cpu_req_valid) begin
          tag_ce       = 1'b1;
          tag_addr     = {WAY_BITS'(0), cpu_index};
          data_ce      = 1'b1;
          data_addr    = {WAY_BITS'(0), cpu_index, cpu_beat};
          lookup_way_n = WAY_BITS'(0);
          state_n      = S_LOOKUP;
        end
      end

      S_LOOKUP: begin
        if (sram_hit) begin
          if (req_write_r == 4'b0000) begin
            cpu_resp_valid = 1'b1;
            cpu_resp_data  = sram_word_old;
          end else begin
            data_ce                            = 1'b1;
            data_addr                          = {lookup_way_r, req_index_r, req_beat_r};
            data_we   [req_word_in_beat_r]     = 1'b1;
            data_wmask[req_word_in_beat_r]     = req_write_r;
            data_din  [req_word_in_beat_r]     = req_data_r;

            tag_ce    = 1'b1;
            tag_we    = 1'b1;
            tag_wmask = 4'hF;
            tag_addr  = {lookup_way_r, req_index_r};
            tag_din   = make_meta(1'b1, 1'b1, req_tag_r);
          end

          cpu_req_ready = 1'b1;
          state_n       = S_IDLE;
        end else if (lookup_way_r == WAY_BITS'(0)) begin
          tag_ce       = 1'b1;
          tag_addr     = {WAY_BITS'(1), req_index_r};
          data_ce      = 1'b1;
          data_addr    = {WAY_BITS'(1), req_index_r, req_beat_r};
          lookup_way_n = WAY_BITS'(1);
          state_n      = S_LOOKUP;
        end else begin
          beat_cnt_n = '0;
          if (victim_dirty_sel) begin
            data_ce   = 1'b1;
            data_addr = {victim_way_sel, req_index_r, {BEAT_BITS{1'b0}}};
            state_n   = S_WB_ADDR;
          end else begin
            state_n   = S_READ_ADDR;
          end
        end
      end

      S_WB_ADDR: begin
        mem_req_valid = 1'b1;
        mem_req_rw    = 1'b1;
        mem_req_addr  = wb_mem_addr;

        if (mem_req_ready) begin
          state_n = S_WB_DATA;
        end
      end

      S_WB_DATA: begin
        mem_req_data_valid = 1'b1;
        mem_req_data_bits  = sram_beat;
        mem_req_data_mask  = '1;

        if (mem_req_data_ready) begin
          if (beat_cnt_r == BEAT_BITS'(BEATS_PER_LINE-1)) begin
            beat_cnt_n = '0;
            state_n    = S_READ_ADDR;
          end else begin
            beat_cnt_n = beat_cnt_r + 1'b1;
            data_ce    = 1'b1;
            data_addr  = {victim_way_r, req_index_r, beat_cnt_r + 1'b1};
            state_n    = S_WB_ADDR;
          end
        end
      end

      S_READ_ADDR: begin
        mem_req_valid = 1'b1;
        mem_req_rw    = 1'b0;
        mem_req_addr  = refill_mem_addr;

        if (mem_req_ready) begin
          beat_cnt_n = '0;
          state_n    = S_READ_DATA;
        end
      end

      S_READ_DATA: begin
        if (mem_resp_valid) begin
          data_ce   = 1'b1;
          data_addr = {victim_way_r, req_index_r, beat_cnt_r};
          for (int i = 0; i < WORDS_PER_BEAT; i++) begin
            data_we   [i] = 1'b1;
            data_wmask[i] = 4'hF;
            data_din  [i] = refill_beat_new[i*CPU_WIDTH +: CPU_WIDTH];
          end

          if ((req_write_r == 4'b0000) &&
              (beat_cnt_r == req_beat_r) && !served_q) begin
            cpu_resp_valid = 1'b1;
            cpu_resp_data  = refill_word_old;
            cpu_req_ready  = 1'b1;
            served_n       = 1'b1;
          end

          if (beat_cnt_r == BEAT_BITS'(BEATS_PER_LINE-1)) begin
            tag_ce    = 1'b1;
            tag_we    = 1'b1;
            tag_wmask = 4'hF;
            tag_addr  = {victim_way_r, req_index_r};
            tag_din   = make_meta((req_write_r != 4'b0000), 1'b1, req_tag_r);

            if (req_write_r != 4'b0000) begin
              cpu_req_ready = 1'b1;
              served_n      = 1'b1;
            end

            beat_cnt_n = '0;
            state_n    = S_IDLE;
          end else begin
            beat_cnt_n = beat_cnt_r + 1'b1;
          end
        end
      end

      default: begin
        state_n = S_IDLE;
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      state              <= S_INIT;
      init_cnt_r         <= '0;
      beat_cnt_r         <= '0;
      lookup_way_r       <= '0;
      served_q           <= 1'b0;

      req_tag_r          <= '0;
      req_index_r        <= '0;
      req_beat_r         <= '0;
      req_word_in_beat_r <= '0;
      req_write_r        <= '0;
      req_data_r         <= '0;

      victim_way_r       <= '0;
      victim_tag_r       <= '0;
      way0_valid_r       <= 1'b0;
      way0_dirty_r       <= 1'b0;
      way0_tag_r         <= '0;
      refill_line_r      <= '0;

      linebuf_valid      <= 1'b0;
      linebuf_way        <= '0;
      linebuf_tag        <= '0;
      linebuf_index      <= '0;
      linebuf_line       <= '0;

      beatbuf_valid      <= 1'b0;
      beatbuf_way        <= '0;
      beatbuf_tag        <= '0;
      beatbuf_index      <= '0;
      beatbuf_beat       <= '0;
      beatbuf_data       <= '0;

      for (reset_i = 0; reset_i < SETS; reset_i = reset_i + 1) begin
        repl_way[reset_i] <= '0;
      end
    end else begin
      state        <= state_n;
      init_cnt_r   <= init_cnt_n;
      beat_cnt_r   <= beat_cnt_n;
      lookup_way_r <= lookup_way_n;
      served_q     <= served_n;

      if (state == S_IDLE && cpu_req_valid && hot_hit && (cpu_req_write != 4'b0000)) begin
        if (linebuf_hit) begin
          linebuf_line <= hot_line_new;
          if (beatbuf_valid && (beatbuf_tag == cpu_tag) && (beatbuf_index == cpu_index)) begin
            beatbuf_valid <= 1'b0;
          end
        end else begin
          beatbuf_data <= hot_beat_new;
        end
      end

      if (state == S_IDLE && cpu_req_valid && hot_hit) begin
        repl_way[cpu_index] <= ~hot_way;
      end

      if (state == S_IDLE && cpu_req_valid && !hot_hit) begin
        req_tag_r          <= cpu_tag;
        req_index_r        <= cpu_index;
        req_beat_r         <= cpu_beat;
        req_word_in_beat_r <= cpu_word_in_beat;
        req_write_r        <= cpu_req_write;
        req_data_r         <= cpu_req_data;
      end

      if (state == S_LOOKUP && sram_hit) begin
        beatbuf_valid <= 1'b1;
        beatbuf_way   <= lookup_way_r;
        beatbuf_tag   <= req_tag_r;
        beatbuf_index <= req_index_r;
        beatbuf_beat  <= req_beat_r;
        beatbuf_data  <= (req_write_r == 4'b0000) ? sram_beat : sram_beat_new;
        repl_way[req_index_r] <= ~lookup_way_r;
      end

      if (state == S_LOOKUP && !sram_hit && (lookup_way_r == WAY_BITS'(0))) begin
        way0_valid_r <= tag_dout_valid;
        way0_dirty_r <= tag_dout_dirty;
        way0_tag_r   <= tag_dout_tag;
      end

      if (state == S_LOOKUP && !sram_hit && (lookup_way_r == WAY_BITS'(1))) begin
        victim_way_r <= victim_way_sel;
        victim_tag_r <= victim_tag_sel;
      end

      if (state == S_READ_ADDR && mem_req_ready) begin
        refill_line_r <= '0;
      end

      if (state == S_READ_DATA && mem_resp_valid) begin
        refill_line_r <= refill_line_new;

        if (beat_cnt_r == BEAT_BITS'(BEATS_PER_LINE-1)) begin
          linebuf_valid <= 1'b1;
          linebuf_way   <= victim_way_r;
          linebuf_tag   <= req_tag_r;
          linebuf_index <= req_index_r;
          linebuf_line  <= refill_line_new;

          beatbuf_valid <= 1'b0;
          repl_way[req_index_r] <= ~victim_way_r;
        end
      end
    end
  end

  sram22_64x32m4w8 Cache_Tag (
    .clk   (clk),
    .rstb  (~reset),
    .ce    (tag_ce),
    .we    (tag_we),
    .wmask (tag_wmask),
    .addr  (tag_addr),
    .din   (tag_din),
    .dout  (tag_dout)
  );

  sram22_256x32m4w8 Cache_Data_0 (
    .clk(clk), .rstb(~reset),
    .ce(data_ce), .we(data_we[0]), .wmask(data_wmask[0]),
    .addr(data_addr), .din(data_din[0]), .dout(data_dout[0])
  );

  sram22_256x32m4w8 Cache_Data_1 (
    .clk(clk), .rstb(~reset),
    .ce(data_ce), .we(data_we[1]), .wmask(data_wmask[1]),
    .addr(data_addr), .din(data_din[1]), .dout(data_dout[1])
  );

  sram22_256x32m4w8 Cache_Data_2 (
    .clk(clk), .rstb(~reset),
    .ce(data_ce), .we(data_we[2]), .wmask(data_wmask[2]),
    .addr(data_addr), .din(data_din[2]), .dout(data_dout[2])
  );

  sram22_256x32m4w8 Cache_Data_3 (
    .clk(clk), .rstb(~reset),
    .ce(data_ce), .we(data_we[3]), .wmask(data_wmask[3]),
    .addr(data_addr), .din(data_din[3]), .dout(data_dout[3])
  );

endmodule

`default_nettype wire
