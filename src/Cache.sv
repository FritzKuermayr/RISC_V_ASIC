`default_nettype none

import const_pkg::*;

// Direct-mapped cache, 4 KB.
//   64 sets x 16 words/line.
//   Tag SRAM:  1x sram22_64x32m4w8.   addr = set[5:0].
//   Data SRAM: 4x sram22_256x32m4w8.  addr = {set[5:0], beat[1:0]}.
//   Reset warmup writes valid=0 to all 64 tag entries.
//   Hit latency: 1-cycle stall.
//   Miss: optional dirty writeback, refill with early-serve + inline write merge.

module cache #(
  parameter int unsigned NUM_WAYS       = 1,
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

  // Geometry
  localparam int unsigned WORDS_PER_LINE = 16;
  localparam int unsigned LINE_BITS      = WORDS_PER_LINE * CPU_WIDTH;
  localparam int unsigned BEATS_PER_LINE = LINE_BITS / MEM_DATA_BITS;
  localparam int unsigned WORDS_PER_BEAT = MEM_DATA_BITS / CPU_WIDTH;
  localparam int unsigned BEAT_BITS      = $clog2(BEATS_PER_LINE);
  localparam int unsigned WORD_IN_BEAT_B = $clog2(WORDS_PER_BEAT);
  localparam int unsigned OFFSET_BITS    = $clog2(WORDS_PER_LINE);
  localparam int unsigned INDEX_BITS     = $clog2(LINES);
  localparam int unsigned TAG_BITS       = WORD_ADDR_BITS - INDEX_BITS - OFFSET_BITS;
  localparam int unsigned MEM_ADDR_LSB   = $clog2(WORDS_PER_BEAT);
  localparam int unsigned INIT_BITS      = $clog2(LINES);

  // CPU address decode
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

  // Latched request
  logic [TAG_BITS-1:0]       req_tag_r;
  logic [INDEX_BITS-1:0]     req_index_r;
  logic [BEAT_BITS-1:0]      req_beat_r;
  logic [WORD_IN_BEAT_B-1:0] req_word_in_beat_r;
  logic [3:0]                req_write_r;
  logic [CPU_WIDTH-1:0]      req_data_r;

  // FSM
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

  logic [INIT_BITS-1:0] init_cnt_r, init_cnt_n;
  logic [BEAT_BITS-1:0] beat_cnt_r, beat_cnt_n;
  logic [LINE_BITS-1:0] refill_line_r;
  logic                 served_q, served_n;

  logic [TAG_BITS-1:0]  victim_tag_r;
  logic                 victim_dirty_r;

  // Tag SRAM signals (sram22_64x32m4w8)
  // word layout: {11'b0, dirty, valid, tag[19:0]}
  logic                  tag_ce, tag_we;
  logic [3:0]            tag_wmask;
  logic [INDEX_BITS-1:0] tag_addr;
  logic [31:0]           tag_din, tag_dout;

  logic                tag_dout_valid;
  logic                tag_dout_dirty;
  logic [TAG_BITS-1:0] tag_dout_tag;
  assign tag_dout_tag    = tag_dout[TAG_BITS-1:0];
  assign tag_dout_valid  = tag_dout[TAG_BITS];
  assign tag_dout_dirty  = tag_dout[TAG_BITS+1];

  // Data SRAM signals (4x sram22_256x32m4w8)
  logic                            data_ce;
  logic [INDEX_BITS+BEAT_BITS-1:0] data_addr;
  logic        data_we    [0:3];
  logic [3:0]  data_wmask [0:3];
  logic [31:0] data_din   [0:3];
  logic [31:0] data_dout  [0:3];

  // Hit detection (in S_LOOKUP)
  logic hit_n;
  assign hit_n = tag_dout_valid && (tag_dout_tag == req_tag_r);

  // Hit word
  logic [CPU_WIDTH-1:0] hit_word;
  assign hit_word = data_dout[req_word_in_beat_r];

  // Memory addresses
  logic [WORD_ADDR_BITS-1:MEM_ADDR_LSB] refill_mem_addr;
  logic [WORD_ADDR_BITS-1:MEM_ADDR_LSB] wb_mem_addr;
  assign refill_mem_addr = {req_tag_r, req_index_r, {BEAT_BITS{1'b0}}};
  assign wb_mem_addr     = {victim_tag_r, req_index_r, beat_cnt_r};

  // Inline merge for write miss
  logic [CPU_WIDTH-1:0] req_beat_word_old;
  logic [CPU_WIDTH-1:0] req_beat_word_merged;
  assign req_beat_word_old = mem_resp_data[req_word_in_beat_r * CPU_WIDTH +: CPU_WIDTH];
  always_comb begin
    req_beat_word_merged = req_beat_word_old;
    if (req_write_r[0]) req_beat_word_merged[7:0]   = req_data_r[7:0];
    if (req_write_r[1]) req_beat_word_merged[15:8]  = req_data_r[15:8];
    if (req_write_r[2]) req_beat_word_merged[23:16] = req_data_r[23:16];
    if (req_write_r[3]) req_beat_word_merged[31:24] = req_data_r[31:24];
  end

  // Combinational FSM
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

    state_n    = state;
    init_cnt_n = init_cnt_r;
    beat_cnt_n = beat_cnt_r;
    served_n   = served_q;

    case (state)
      S_INIT: begin
        tag_ce    = 1'b1;
        tag_we    = 1'b1;
        tag_wmask = 4'hF;
        tag_addr  = init_cnt_r[INDEX_BITS-1:0];
        tag_din   = '0;
        if (&init_cnt_r) begin
          init_cnt_n = '0;
          state_n    = S_IDLE;
        end else begin
          init_cnt_n = init_cnt_r + 1'b1;
        end
      end

      S_IDLE: begin
        cpu_req_ready = !cpu_req_valid;
        served_n      = 1'b0;
        if (cpu_req_valid) begin
          tag_ce    = 1'b1;
          tag_addr  = cpu_index;
          data_ce   = 1'b1;
          data_addr = {cpu_index, cpu_beat};
          state_n   = S_LOOKUP;
        end
      end

      S_LOOKUP: begin
        if (hit_n) begin
          if (req_write_r == 4'b0000) begin
            // Read hit
            cpu_resp_valid = 1'b1;
            cpu_resp_data  = hit_word;
            cpu_req_ready  = 1'b1;
            state_n        = S_IDLE;
          end else begin
            // Write hit: byte-write into one bank, mark dirty
            data_ce                          = 1'b1;
            data_addr                        = {req_index_r, req_beat_r};
            data_we   [req_word_in_beat_r]   = 1'b1;
            data_wmask[req_word_in_beat_r]   = req_write_r;
            data_din  [req_word_in_beat_r]   = req_data_r;

            tag_ce    = 1'b1;
            tag_we    = 1'b1;
            tag_wmask = 4'hF;
            tag_addr  = req_index_r;
            tag_din   = {11'b0, 1'b1, 1'b1, req_tag_r};

            cpu_req_ready = 1'b1;
            state_n       = S_IDLE;
          end
        end else begin
          // Miss
          beat_cnt_n = '0;
          if (tag_dout_valid && tag_dout_dirty) begin
            // Pre-read victim beat 0
            data_ce   = 1'b1;
            data_addr = {req_index_r, {BEAT_BITS{1'b0}}};
            state_n   = S_WB_ADDR;
          end else begin
            state_n = S_READ_ADDR;
          end
        end
      end

      S_WB_ADDR: begin
        mem_req_valid = 1'b1;
        mem_req_rw    = 1'b1;
        mem_req_addr  = wb_mem_addr;
        if (mem_req_ready) state_n = S_WB_DATA;
      end

      S_WB_DATA: begin
        mem_req_data_valid = 1'b1;
        mem_req_data_bits  = {data_dout[3], data_dout[2], data_dout[1], data_dout[0]};
        mem_req_data_mask  = '1;
        if (mem_req_data_ready) begin
          if (beat_cnt_r == BEAT_BITS'(BEATS_PER_LINE-1)) begin
            beat_cnt_n = '0;
            state_n    = S_READ_ADDR;
          end else begin
            beat_cnt_n = beat_cnt_r + 1'b1;
            data_ce    = 1'b1;
            data_addr  = {req_index_r, beat_cnt_r + 1'b1};
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
          data_addr = {req_index_r, beat_cnt_r};
          for (int i = 0; i < 4; i++) begin
            data_we   [i] = 1'b1;
            data_wmask[i] = 4'hF;
            data_din  [i] = mem_resp_data[i*CPU_WIDTH +: CPU_WIDTH];
          end

          if (req_write_r != 4'b0000 && beat_cnt_r == req_beat_r) begin
            data_din[req_word_in_beat_r] = req_beat_word_merged;
          end

          if (req_write_r == 4'b0000 && beat_cnt_r == req_beat_r && !served_q) begin
            cpu_resp_valid = 1'b1;
            cpu_resp_data  = req_beat_word_old;
            cpu_req_ready  = 1'b1;
            served_n       = 1'b1;
          end

          if (beat_cnt_r == BEAT_BITS'(BEATS_PER_LINE-1)) begin
            tag_ce    = 1'b1;
            tag_we    = 1'b1;
            tag_wmask = 4'hF;
            tag_addr  = req_index_r;
            tag_din   = {11'b0, (req_write_r != 4'b0000), 1'b1, req_tag_r};

            if (req_write_r != 4'b0000 && !served_q) begin
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

      default: state_n = S_IDLE;
    endcase
  end

  // Sequential
  always_ff @(posedge clk) begin
    if (reset) begin
      state              <= S_INIT;
      init_cnt_r         <= '0;
      beat_cnt_r         <= '0;
      refill_line_r      <= '0;
      served_q           <= 1'b0;
      req_tag_r          <= '0;
      req_index_r        <= '0;
      req_beat_r         <= '0;
      req_word_in_beat_r <= '0;
      req_write_r        <= '0;
      req_data_r         <= '0;
      victim_tag_r       <= '0;
      victim_dirty_r     <= 1'b0;
    end else begin
      state      <= state_n;
      init_cnt_r <= init_cnt_n;
      beat_cnt_r <= beat_cnt_n;
      served_q   <= served_n;

      if (state == S_READ_DATA && mem_resp_valid)
        refill_line_r[beat_cnt_r * MEM_DATA_BITS +: MEM_DATA_BITS] <= mem_resp_data;

      if (state == S_IDLE && cpu_req_valid) begin
        req_tag_r          <= cpu_tag;
        req_index_r        <= cpu_index;
        req_beat_r         <= cpu_beat;
        req_word_in_beat_r <= cpu_word_in_beat;
        req_write_r        <= cpu_req_write;
        req_data_r         <= cpu_req_data;
      end

      if (state == S_LOOKUP && !hit_n) begin
        victim_tag_r   <= tag_dout_tag;
        victim_dirty_r <= tag_dout_dirty;
      end
    end
  end

  // SRAM macros
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