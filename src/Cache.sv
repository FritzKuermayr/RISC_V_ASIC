`default_nettype none

import const_pkg::*;

// 2-way set-associative cache, 4 KB.
//   32 sets x 2 ways x 16 words/line.
//   Tag SRAM:  1x sram22_64x32m4w8.   addr {way, set}.
//   Data SRAM: 4x sram22_256x32m4w8.  addr {way, set, beat}. Each holds one word slot.
//   Reset warmup writes valid=0 to all 64 tag entries before serving requests.
//   On miss: optional dirty writeback, then refill with early-serve + inline write merge.

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

  // Geometry
  localparam int unsigned SETS           = LINES / NUM_WAYS;                          // 32
  localparam int unsigned WORDS_PER_LINE = 16;
  localparam int unsigned LINE_BITS      = WORDS_PER_LINE * CPU_WIDTH;                // 512
  localparam int unsigned BEATS_PER_LINE = LINE_BITS / MEM_DATA_BITS;                 // 4
  localparam int unsigned WORDS_PER_BEAT = MEM_DATA_BITS / CPU_WIDTH;                 // 4
  localparam int unsigned BEAT_BITS      = $clog2(BEATS_PER_LINE);                    // 2
  localparam int unsigned WORD_IN_BEAT_B = $clog2(WORDS_PER_BEAT);                    // 2
  localparam int unsigned OFFSET_BITS    = $clog2(WORDS_PER_LINE);                    // 4
  localparam int unsigned INDEX_BITS     = $clog2(SETS);                              // 5
  localparam int unsigned WAY_BITS       = $clog2(NUM_WAYS);                          // 1
  localparam int unsigned TAG_BITS       = WORD_ADDR_BITS - INDEX_BITS - OFFSET_BITS; // 21
  localparam int unsigned MEM_ADDR_LSB   = $clog2(WORDS_PER_BEAT);                    // 2
  localparam int unsigned INIT_BITS      = $clog2(LINES);                             // 6

  // CPU request decode (live)
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

  // Latched request (held for the whole transaction)
  logic [TAG_BITS-1:0]       req_tag_r;
  logic [INDEX_BITS-1:0]     req_index_r;
  logic [OFFSET_BITS-1:0]    req_offset_r;
  logic [BEAT_BITS-1:0]      req_beat_r;
  logic [WORD_IN_BEAT_B-1:0] req_word_in_beat_r;
  logic [3:0]                req_write_r;
  logic [CPU_WIDTH-1:0]      req_data_r;

  // FSM
  typedef enum logic [3:0] {
    S_INIT        = 4'd0,  // clear all 64 tag entries (valid=0)
    S_IDLE        = 4'd1,  // accept request, kick off way-0 SRAM read
    S_LOOKUP_W0   = 4'd2,  // way-0 dout valid; hit -> respond, miss -> probe way-1
    S_LOOKUP_W1   = 4'd3,  // way-1 dout valid; hit -> respond, miss -> evict
    S_WB_ADDR     = 4'd4,  // send writeback address
    S_WB_DATA     = 4'd5,  // send writeback beat data
    S_READ_ADDR   = 4'd6,  // send refill address
    S_READ_DATA   = 4'd7,  // collect refill beats; early-serve read, inline merge write
    S_RESPOND     = 4'd8   // post-refill commit cycle (only used if not early-served)
  } state_t;

  state_t state, state_n;

  logic [INIT_BITS-1:0] init_cnt_r, init_cnt_n;
  logic [BEAT_BITS-1:0] beat_cnt_r, beat_cnt_n;

  // Way-0 latched (since tag SRAM dout switches to way 1 in S_LOOKUP_W1)
  logic                way0_valid_q;
  logic                way0_dirty_q;
  logic [TAG_BITS-1:0] way0_tag_q;

  // Victim picked at end of S_LOOKUP_W1
  logic                victim_way_r;
  logic                victim_valid_r;
  logic                victim_dirty_r;
  logic [TAG_BITS-1:0] victim_tag_r;

  // Pseudo-LRU: 1 bit per set, points to next replacement way
  logic [SETS-1:0]     repl_reg;

  // True once we've handed cpu_resp_data to the CPU during a miss
  logic                served_q, served_n;

  // Tag SRAM signals.  Word layout: {9'b0, dirty, valid, tag[20:0]}
  logic                            tag_ce, tag_we;
  logic [3:0]                      tag_wmask;
  logic [WAY_BITS+INDEX_BITS-1:0]  tag_addr;
  logic [31:0]                     tag_din, tag_dout;

  logic                tag_dout_valid;
  logic                tag_dout_dirty;
  logic [TAG_BITS-1:0] tag_dout_tag;
  assign tag_dout_tag    = tag_dout[TAG_BITS-1:0];
  assign tag_dout_valid  = tag_dout[TAG_BITS];
  assign tag_dout_dirty  = tag_dout[TAG_BITS+1];

  // Data SRAM signals.  All 4 banks share addr+ce; per-bank we/wmask/din/dout.
  logic                                     data_ce;
  logic [WAY_BITS+INDEX_BITS+BEAT_BITS-1:0] data_addr;

  logic        data_we    [0:3];
  logic [3:0]  data_wmask [0:3];
  logic [31:0] data_din   [0:3];
  logic [31:0] data_dout  [0:3];

  // Hit detection (only meaningful in the matching lookup state)
  logic hit_w0;
  logic hit_w1;
  assign hit_w0 = (state == S_LOOKUP_W0) && tag_dout_valid && (tag_dout_tag == req_tag_r);
  assign hit_w1 = (state == S_LOOKUP_W1) && tag_dout_valid && (tag_dout_tag == req_tag_r);

  // Selected word from the data SRAMs (for hits)
  logic [CPU_WIDTH-1:0] hit_word;
  assign hit_word = data_dout[req_word_in_beat_r];

  // Memory addresses
  logic [WORD_ADDR_BITS-1:MEM_ADDR_LSB] refill_mem_addr;
  logic [WORD_ADDR_BITS-1:MEM_ADDR_LSB] wb_mem_addr;
  assign refill_mem_addr = {req_tag_r,    req_index_r, {BEAT_BITS{1'b0}}};
  assign wb_mem_addr     = {victim_tag_r, req_index_r, beat_cnt_r};

  // Victim selection (combinational, used in S_LOOKUP_W1 miss branch)
  logic                next_victim_way;
  logic                next_victim_valid;
  logic                next_victim_dirty;
  logic [TAG_BITS-1:0] next_victim_tag;
  always_comb begin
    if (!way0_valid_q) begin
      next_victim_way   = 1'b0;
      next_victim_valid = way0_valid_q;
      next_victim_dirty = way0_dirty_q;
      next_victim_tag   = way0_tag_q;
    end else if (!tag_dout_valid) begin
      next_victim_way   = 1'b1;
      next_victim_valid = tag_dout_valid;
      next_victim_dirty = tag_dout_dirty;
      next_victim_tag   = tag_dout_tag;
    end else if (repl_reg[req_index_r] == 1'b0) begin
      next_victim_way   = 1'b0;
      next_victim_valid = way0_valid_q;
      next_victim_dirty = way0_dirty_q;
      next_victim_tag   = way0_tag_q;
    end else begin
      next_victim_way   = 1'b1;
      next_victim_valid = tag_dout_valid;
      next_victim_dirty = tag_dout_dirty;
      next_victim_tag   = tag_dout_tag;
    end
  end

  // Inline write-merge for write miss in S_READ_DATA
  // (one merged word; the other 3 words of the requested beat get the
  //  raw memory response; non-requested beats also get raw memory response)
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

  // Combinational FSM and outputs
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

      // Reset warmup: walk through all 64 tag entries, write valid=0
      S_INIT: begin
        tag_ce    = 1'b1;
        tag_we    = 1'b1;
        tag_wmask = 4'hF;
        tag_addr  = init_cnt_r[WAY_BITS+INDEX_BITS-1:0];
        tag_din   = '0;
        if (&init_cnt_r) begin
          init_cnt_n = '0;
          state_n    = S_IDLE;
        end else begin
          init_cnt_n = init_cnt_r + 1'b1;
        end
      end

      // Idle: accept new transaction, fire SRAM read for way 0
      S_IDLE: begin
        cpu_req_ready = !cpu_req_valid;
        served_n      = 1'b0;
        if (cpu_req_valid) begin
          tag_ce    = 1'b1;
          tag_addr  = {1'b0, cpu_index};
          data_ce   = 1'b1;
          data_addr = {1'b0, cpu_index, cpu_beat};
          state_n   = S_LOOKUP_W0;
        end
      end

      // Way-0 dout is now valid
      S_LOOKUP_W0: begin
        if (hit_w0) begin
          if (req_write_r == 4'b0000) begin
            // Read hit (way 0)
            cpu_resp_valid = 1'b1;
            cpu_resp_data  = hit_word;
            cpu_req_ready  = 1'b1;
            state_n        = S_IDLE;
          end else begin
            // Write hit (way 0): byte-write into the matching data bank, mark dirty
            data_ce                          = 1'b1;
            data_addr                        = {1'b0, req_index_r, req_beat_r};
            data_we   [req_word_in_beat_r]   = 1'b1;
            data_wmask[req_word_in_beat_r]   = req_write_r;
            data_din  [req_word_in_beat_r]   = req_data_r;

            tag_ce    = 1'b1;
            tag_we    = 1'b1;
            tag_wmask = 4'hF;
            tag_addr  = {1'b0, req_index_r};
            tag_din   = {9'b0, 1'b1, 1'b1, req_tag_r};

            cpu_req_ready = 1'b1;
            state_n       = S_IDLE;
          end
        end else begin
          // Way-0 miss; probe way 1
          tag_ce    = 1'b1;
          tag_addr  = {1'b1, req_index_r};
          data_ce   = 1'b1;
          data_addr = {1'b1, req_index_r, req_beat_r};
          state_n   = S_LOOKUP_W1;
        end
      end

      // Way-1 dout is now valid
      S_LOOKUP_W1: begin
        if (hit_w1) begin
          if (req_write_r == 4'b0000) begin
            cpu_resp_valid = 1'b1;
            cpu_resp_data  = hit_word;
            cpu_req_ready  = 1'b1;
            state_n        = S_IDLE;
          end else begin
            data_ce                          = 1'b1;
            data_addr                        = {1'b1, req_index_r, req_beat_r};
            data_we   [req_word_in_beat_r]   = 1'b1;
            data_wmask[req_word_in_beat_r]   = req_write_r;
            data_din  [req_word_in_beat_r]   = req_data_r;

            tag_ce    = 1'b1;
            tag_we    = 1'b1;
            tag_wmask = 4'hF;
            tag_addr  = {1'b1, req_index_r};
            tag_din   = {9'b0, 1'b1, 1'b1, req_tag_r};

            cpu_req_ready = 1'b1;
            state_n       = S_IDLE;
          end
        end else begin
          // Both ways missed; pick a victim
          beat_cnt_n = '0;
          if (next_victim_valid && next_victim_dirty) begin
            // Pre-read victim beat 0 for writeback
            data_ce   = 1'b1;
            data_addr = {next_victim_way, req_index_r, {BEAT_BITS{1'b0}}};
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

      // Receive refill beats. Write each beat to the 4 data SRAMs in parallel.
      // Early-serve the requested word as soon as its beat arrives (read miss).
      // Inline-merge the requested word for write miss before SRAM commit.
      // On the last beat: commit metadata; if write miss, hand ready to CPU here.
      S_READ_DATA: begin
        if (mem_resp_valid) begin
          data_ce   = 1'b1;
          data_addr = {victim_way_r, req_index_r, beat_cnt_r};
          for (int i = 0; i < 4; i++) begin
            data_we   [i] = 1'b1;
            data_wmask[i] = 4'hF;
            data_din  [i] = mem_resp_data[i*CPU_WIDTH +: CPU_WIDTH];
          end

          // Inline merge: if write miss and this is the requested beat,
          // overwrite the requested word with the merged result
          if (req_write_r != 4'b0000 && beat_cnt_r == req_beat_r) begin
            data_din[req_word_in_beat_r] = req_beat_word_merged;
          end

          // Early-serve for read miss
          if (req_write_r == 4'b0000 && beat_cnt_r == req_beat_r && !served_q) begin
            cpu_resp_valid = 1'b1;
            cpu_resp_data  = req_beat_word_old;
            cpu_req_ready  = 1'b1;
            served_n       = 1'b1;
          end

          if (beat_cnt_r == BEAT_BITS'(BEATS_PER_LINE-1)) begin
            // Last beat: commit metadata
            tag_ce    = 1'b1;
            tag_we    = 1'b1;
            tag_wmask = 4'hF;
            tag_addr  = {victim_way_r, req_index_r};
            tag_din   = {9'b0, (req_write_r != 4'b0000), 1'b1, req_tag_r};

            // Write miss: serve CPU on last beat (if not already served, which
            // it can't be for a write miss since early-serve only runs for reads)
            if (req_write_r != 4'b0000 && !served_q) begin
              cpu_req_ready = 1'b1;
              served_n      = 1'b1;
            end

            beat_cnt_n = '0;
            // If served (write or read), back to idle directly. Otherwise the
            // RESPOND state catches the read-miss case where the requested beat
            // never arrived (cannot happen with this 4-beat protocol, but kept
            // as a defensive fallback).
            state_n = (req_write_r != 4'b0000 || served_q || (beat_cnt_r == req_beat_r))
                      ? S_IDLE : S_RESPOND;
          end else begin
            beat_cnt_n = beat_cnt_r + 1'b1;
          end
        end
      end

      // Defensive fallback: should never trigger in normal operation since
      // the requested beat is always among the 4 received in S_READ_DATA.
      S_RESPOND: begin
        cpu_resp_valid = 1'b1;
        cpu_resp_data  = '0;
        cpu_req_ready  = 1'b1;
        served_n       = 1'b1;
        state_n        = S_IDLE;
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
      repl_reg           <= '0;
      served_q           <= 1'b0;
      req_tag_r          <= '0;
      req_index_r        <= '0;
      req_offset_r       <= '0;
      req_beat_r         <= '0;
      req_word_in_beat_r <= '0;
      req_write_r        <= '0;
      req_data_r         <= '0;
      way0_valid_q       <= 1'b0;
      way0_dirty_q       <= 1'b0;
      way0_tag_q         <= '0;
      victim_way_r       <= 1'b0;
      victim_valid_r     <= 1'b0;
      victim_dirty_r     <= 1'b0;
      victim_tag_r       <= '0;
    end else begin
      state      <= state_n;
      init_cnt_r <= init_cnt_n;
      beat_cnt_r <= beat_cnt_n;
      served_q   <= served_n;

      // Latch CPU request when entering a lookup
      if (state == S_IDLE && cpu_req_valid) begin
        req_tag_r          <= cpu_tag;
        req_index_r        <= cpu_index;
        req_offset_r       <= cpu_offset;
        req_beat_r         <= cpu_beat;
        req_word_in_beat_r <= cpu_word_in_beat;
        req_write_r        <= cpu_req_write;
        req_data_r         <= cpu_req_data;
      end

      // Latch way-0 metadata when way 0 missed (so we still have it
      // after tag dout switches to way 1)
      if (state == S_LOOKUP_W0 && !hit_w0) begin
        way0_valid_q <= tag_dout_valid;
        way0_dirty_q <= tag_dout_dirty;
        way0_tag_q   <= tag_dout_tag;
      end

      // Latch victim info on miss (both ways missed)
      if (state == S_LOOKUP_W1 && !hit_w1) begin
        victim_way_r   <= next_victim_way;
        victim_valid_r <= next_victim_valid;
        victim_dirty_r <= next_victim_dirty;
        victim_tag_r   <= next_victim_tag;
      end

      // Update LRU pointer:
      //   on way-0 hit  -> way 1 becomes next victim
      //   on way-1 hit  -> way 0 becomes next victim
      //   on miss commit (last refill beat) -> the OTHER way becomes next victim
      if (state == S_LOOKUP_W0 && hit_w0)
        repl_reg[req_index_r] <= 1'b1;
      else if (state == S_LOOKUP_W1 && hit_w1)
        repl_reg[req_index_r] <= 1'b0;
      else if (state == S_READ_DATA && mem_resp_valid && beat_cnt_r == BEAT_BITS'(BEATS_PER_LINE-1))
        repl_reg[req_index_r] <= ~victim_way_r;
    end
  end

  // SRAM macros (auto-imported via Hammer's sram-cache.json)
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
    .clk   (clk),
    .rstb  (~reset),
    .ce    (data_ce),
    .we    (data_we[0]),
    .wmask (data_wmask[0]),
    .addr  (data_addr),
    .din   (data_din[0]),
    .dout  (data_dout[0])
  );

  sram22_256x32m4w8 Cache_Data_1 (
    .clk   (clk),
    .rstb  (~reset),
    .ce    (data_ce),
    .we    (data_we[1]),
    .wmask (data_wmask[1]),
    .addr  (data_addr),
    .din   (data_din[1]),
    .dout  (data_dout[1])
  );

  sram22_256x32m4w8 Cache_Data_2 (
    .clk   (clk),
    .rstb  (~reset),
    .ce    (data_ce),
    .we    (data_we[2]),
    .wmask (data_wmask[2]),
    .addr  (data_addr),
    .din   (data_din[2]),
    .dout  (data_dout[2])
  );

  sram22_256x32m4w8 Cache_Data_3 (
    .clk   (clk),
    .rstb  (~reset),
    .ce    (data_ce),
    .we    (data_we[3]),
    .wmask (data_wmask[3]),
    .addr  (data_addr),
    .din   (data_din[3]),
    .dout  (data_dout[3])
  );

endmodule

`default_nettype wire