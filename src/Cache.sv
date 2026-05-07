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

  // CPU <-> Cache
  input  logic                         cpu_req_valid, // CPU has a request for cache
  output logic                         cpu_req_ready, // cache can take the request -> transfer when both are 1; Handshake = valid && ready
  input  logic [WORD_ADDR_BITS-1:0]    cpu_req_addr, // 32 bit Word --> 4 bytes --> needs 2 bit to differentiate between bytes
  input  logic [CPU_WIDTH-1:0]         cpu_req_data,
  input  logic [3:0]                   cpu_req_write, // 4 bit byte mask --> 4'b0000 read; 4'b0010 store byte 01; can control store byte, half-word, word

  output logic                         cpu_resp_valid, // data valid
  output logic [CPU_WIDTH-1:0]         cpu_resp_data, // the read word

  // Cache <-> Main Memory
  output logic                         mem_req_valid, 
  input  logic                         mem_req_ready,
  output logic [WORD_ADDR_BITS-1:$clog2(MEM_DATA_BITS/CPU_WIDTH)] mem_req_addr,
  output logic                         mem_req_rw, // 0 read, 1 write
  output logic                         mem_req_data_valid,
  input  logic                         mem_req_data_ready,
  output logic [MEM_DATA_BITS-1:0]     mem_req_data_bits,
  output logic [(MEM_DATA_BITS/8)-1:0] mem_req_data_mask,

  input  logic                         mem_resp_valid,
  input  logic [MEM_DATA_BITS-1:0]     mem_resp_data
);

  localparam int unsigned SETS           = LINES / NUM_WAYS; // 64/2 = 32
  localparam int unsigned WAY_BITS       = $clog2(NUM_WAYS); // 1
  localparam int unsigned WORDS_PER_LINE = 16;
  localparam int unsigned LINE_BITS      = WORDS_PER_LINE * CPU_WIDTH; 
  localparam int unsigned BEATS_PER_LINE = LINE_BITS / MEM_DATA_BITS; // 512/128 = 4
  localparam int unsigned WORDS_PER_BEAT = MEM_DATA_BITS / CPU_WIDTH; // 128/32 = 4 --> Beat = Bits of MEM_DATA_BITS
  localparam int unsigned BEAT_BITS      = $clog2(BEATS_PER_LINE); // 2
  localparam int unsigned WORD_IN_BEAT_B = $clog2(WORDS_PER_BEAT); // How many bits to select a word in a beat
  localparam int unsigned OFFSET_BITS    = $clog2(WORDS_PER_LINE); // How many bits to select a word in a line? log2(512/32) = 4
  localparam int unsigned INDEX_BITS     = $clog2(SETS); // which set? 
  localparam int unsigned TAG_BITS       = WORD_ADDR_BITS - INDEX_BITS - OFFSET_BITS; // 30-5-4 = 21; Tag is unique identifier; CPU Adress is decomposed to | TAG | INDEX | OFFSET |
  localparam int unsigned MEM_ADDR_LSB   = $clog2(WORDS_PER_BEAT); // How many bits do i have to throw away, because i need them to identify the word in the beat
  localparam int unsigned INIT_BITS      = $clog2(LINES); // How many bits to count through all cache lines
  localparam int unsigned META_PAD_BITS  = 32 - TAG_BITS - 2; // cache only safes dirty, valid & tag --> the rest is already stored through its position --> | 9 unused(padding) | 21 tag | dirty | valid |

  typedef enum logic [3:0] {
    S_INIT      = 4'd0, // Set all 64 to valid = 0, so that no Tag 
    S_IDLE      = 4'd1, // Waits for CPU req
    S_LOOKUP    = 4'd2, // SRAM Lookup runs (way 0 or 1)
    S_WB_ADDR   = 4'd3, // WB -> Sends adress to mem (for dirty victim)
    S_WB_DATA   = 4'd4, // Sends data to mem
    S_READ_ADDR = 4'd5, // Read Adresse to Mem
    S_READ_DATA = 4'd6 // Get data from Mem
  } state_t;

  state_t state, state_n;

  logic [OFFSET_BITS-1:0]    cpu_offset; // offset = 2 bits for beat in line, 2 bits for word in beat, 2 bits for byte in word
  logic [INDEX_BITS-1:0]     cpu_index; 
  logic [TAG_BITS-1:0]       cpu_tag;
  logic [BEAT_BITS-1:0]      cpu_beat; 
  logic [WORD_IN_BEAT_B-1:0] cpu_word_in_beat;

  assign cpu_offset       = cpu_req_addr[OFFSET_BITS-1:0];
  assign cpu_index        = cpu_req_addr[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
  assign cpu_tag          = cpu_req_addr[WORD_ADDR_BITS-1:OFFSET_BITS+INDEX_BITS];
  assign cpu_beat         = cpu_offset[OFFSET_BITS-1:WORD_IN_BEAT_B];
  assign cpu_word_in_beat = cpu_offset[WORD_IN_BEAT_B-1:0];

  // if request cant be answered immediatly (no hot-hit, lookup is required), cpu fields are latched here; 
  // CPU may then switch its entrances --> Those registers are held by S_LOOKUP, S_WB_, S_READ_
  logic [TAG_BITS-1:0]       req_tag_r;
  logic [INDEX_BITS-1:0]     req_index_r;
  logic [BEAT_BITS-1:0]      req_beat_r;
  logic [WORD_IN_BEAT_B-1:0] req_word_in_beat_r;
  logic [3:0]                req_write_r;
  logic [CPU_WIDTH-1:0]      req_data_r;

  logic [INIT_BITS-1:0] init_cnt_r, init_cnt_n; // 6 bits, counts from 0-63 for S_INIT
  logic [BEAT_BITS-1:0] beat_cnt_r, beat_cnt_n; // Which beat is currently worked on in S_WB_DATA & S_READ_DATA
  logic                 served_q, served_n; // during a read miss, was the cpu already served with an early serve (cpu gets word as soon as it is loaded)? So that it does not happen twice

  logic [WAY_BITS-1:0] lookup_way_r, lookup_way_n; // in S_LOOKUP --> which way
  logic [WAY_BITS-1:0] victim_way_r; // which way will be kicked out at refill
  logic [TAG_BITS-1:0] victim_tag_r; // which tag has the victim --> needed for wb adress

  logic                way0_valid_r; // Important trick: Single port Tag-SRAM can per Cycle only read one Way. In Cycle N+1 one has the Way0 in tag_dout
  logic                way0_dirty_r; // In Cycle N+2 is tag_dout already W1. To not forget Way_0 Info, it is stored here
  logic [TAG_BITS-1:0] way0_tag_r;

  logic [WAY_BITS-1:0] repl_way [0:SETS-1]; // Which way would i through out next? Effectifly NRU (Not recently used) Bit
  integer reset_i; 

  logic                            tag_ce, tag_we; // chip enable --> if 1, SRAM makes RD/WR in this cycle & tag_we = 1 WR, 0 = RD
  logic [3:0]                      tag_wmask; // 4 bit Bytemask
  logic [WAY_BITS+INDEX_BITS-1:0]  tag_addr; //6 bit = {way (1), set(index) (5)}
  logic [31:0]                     tag_din, tag_dout;

  logic                tag_dout_valid;
  logic                tag_dout_dirty;
  logic [TAG_BITS-1:0] tag_dout_tag;

  assign tag_dout_tag   = tag_dout[TAG_BITS-1:0];
  assign tag_dout_valid = tag_dout[TAG_BITS];
  assign tag_dout_dirty = tag_dout[TAG_BITS+1];

  logic                                  data_ce; // chip enable; 1 --> SRAM rd/wr
  logic [WAY_BITS+INDEX_BITS+BEAT_BITS-1:0] data_addr;  // 1 + 5 + 2 = 8; which word in Data SRAM
  logic        data_we    [0:WORDS_PER_BEAT-1]; // which word write enable = we
  logic [3:0]  data_wmask [0:WORDS_PER_BEAT-1]; // byte mask for each word
  logic [31:0] data_din   [0:WORDS_PER_BEAT-1]; // data written into SRAM
  logic [31:0] data_dout  [0:WORDS_PER_BEAT-1]; // data coming out of SRAM

  // Complete Cache-Line in Reg-File, identified through tag, index, way, filled directly after a refill on the last beat, used when linebuf_hit -> same line as current request
  // linebuf holds cacheline that is currently loaded from mem (refill after miss)
  logic                  linebuf_valid;
  logic [WAY_BITS-1:0]   linebuf_way;
  logic [TAG_BITS-1:0]   linebuf_tag;
  logic [INDEX_BITS-1:0] linebuf_index;
  logic [LINE_BITS-1:0]  linebuf_line;

  // Stores currently arriving beat --> easy serve
  logic [WAY_BITS-1:0]      beatbuf_way;
  logic                     beatbuf_valid;
  logic [TAG_BITS-1:0]      beatbuf_tag;
  logic [INDEX_BITS-1:0]    beatbuf_index;
  logic [BEAT_BITS-1:0]     beatbuf_beat;
  logic [MEM_DATA_BITS-1:0] beatbuf_data;

  // During a Refill (S_READ_DATA) the cache assembles a line from the arriving beats before going into linebuf
  logic [LINE_BITS-1:0] refill_line_r; 


  // Functions


  // builds the meta-data
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

  logic linebuf_hit; // searched address is on linebuf
  logic beatbuf_hit; // searched address is on beatbuf
  logic hot_hit; // either beatbuf_hit or linebuf_hit
  logic [WAY_BITS-1:0] hot_way; // What way is hit - line or beat
  logic [CPU_WIDTH-1:0] hot_word_old; // currently saved word at that position
  logic [CPU_WIDTH-1:0] hot_word_new; // If Write - new Word after Byte Mask Merge
  logic [LINE_BITS-1:0] hot_line_new; // Linebuf-Data after write (to safe)
  logic [MEM_DATA_BITS-1:0] hot_beat_new; // beatbuf-data after write
  
  // all combinatorial --> 0 Cycle Latency; Writes/reads directly in linebuf/beatbuf

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

  // minimizes latency --> cpu can get next request while old one is compared against the current SRAM tag
  logic sram_hit; // hit on latched request (req_tag_r), not against the current cpu_tag; CPU Request was latched in S_IDLE, now compared against SRAM answer
  logic [MEM_DATA_BITS-1:0] sram_beat; // concat 4 SRAM Banks to 128 bit
  logic [CPU_WIDTH-1:0]     sram_word_old; // the looked-for word, coming from req_word_in_beat_r
  logic [CPU_WIDTH-1:0]     sram_word_new; // after Merge with wr-data/mask
  logic [MEM_DATA_BITS-1:0] sram_beat_new; // Beat w/new word, safed in Beatbuf

  assign sram_hit = tag_dout_valid && (tag_dout_tag == req_tag_r);
  assign sram_beat = {data_dout[3], data_dout[2], data_dout[1], data_dout[0]};
  assign sram_word_old = data_dout[req_word_in_beat_r];
  assign sram_word_new = merge_word(sram_word_old, req_data_r, req_write_r);
  assign sram_beat_new = set_word_in_beat(sram_beat, req_word_in_beat_r, sram_word_new);

  // evaluated in S_LOOKUPm after Way-1-Lookup evaluated
  logic [WAY_BITS-1:0] victim_way_sel;
  logic                victim_dirty_sel;
  logic [TAG_BITS-1:0] victim_tag_sel;

  always_comb begin
    if (!way0_valid_r) begin // if Way_0 invalid, way_0 out (valid - does it contain valid data?)
      victim_way_sel = WAY_BITS'(0);
    end else if (!tag_dout_valid) begin //if way_0 valid but way_1 invalid, way_1 out
      victim_way_sel = WAY_BITS'(1);
    end else begin
      victim_way_sel = repl_way[req_index_r]; // if both valid --> kick out what has been selected by req_index_r
    end

    // check if wb is nessesary --> tag needed for wb
    victim_dirty_sel =
        (victim_way_sel == WAY_BITS'(0)) ? way0_dirty_r : tag_dout_dirty;
    victim_tag_sel =
        (victim_way_sel == WAY_BITS'(0)) ? way0_tag_r : tag_dout_tag;
  end

  // Ccache receiving beat from mem during refill
  logic [CPU_WIDTH-1:0] refill_word_old; // Original word on req. position
  logic [CPU_WIDTH-1:0] refill_word_new; // if Original Req was a Write-Miss, merge write into it
  logic [MEM_DATA_BITS-1:0] refill_beat_new; // if Write-Mis and we fill the write beat at this moment (beat_cnt_r == req_beat_r) -> Beat w/merged word; Otherwise Beat 1:1 like received from mem
  logic [LINE_BITS-1:0] refill_line_new;

  assign refill_word_old = get_word_from_beat(mem_resp_data, req_word_in_beat_r);
  assign refill_word_new = merge_word(refill_word_old, req_data_r, req_write_r);
  assign refill_beat_new =
      ((req_write_r != 4'b0000) && (beat_cnt_r == req_beat_r))
        ? set_word_in_beat(mem_resp_data, req_word_in_beat_r, refill_word_new)
        : mem_resp_data;
  assign refill_line_new = set_beat_in_line(refill_line_r, beat_cnt_r, refill_beat_new);

  // Mem Addresses
  logic [WORD_ADDR_BITS-1:MEM_ADDR_LSB] refill_mem_addr;
  logic [WORD_ADDR_BITS-1:MEM_ADDR_LSB] wb_mem_addr;

  assign refill_mem_addr = {req_tag_r, req_index_r, {BEAT_BITS{1'b0}}};
  assign wb_mem_addr     = {victim_tag_r, req_index_r, beat_cnt_r};

  // combinatorial/directly
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

    // hold is default --> if nothing else, next cycle = current cycle
    state_n      = state;
    init_cnt_n   = init_cnt_r;
    beat_cnt_n   = beat_cnt_r;
    lookup_way_n = lookup_way_r;
    served_n     = served_q;

    unique case (state)
      S_INIT: begin
        tag_ce    = 1'b1; // SRAM active
        tag_we    = 1'b1; // Write
        tag_wmask = 4'hF; // all 4 bytes
        tag_addr  = init_cnt_r; // 6 bit, runs 0...63
        tag_din   = '0; // 32'b0 -> valid, dirty, tag = 0

        if (&init_cnt_r) begin // all init_cnt_r = 1
          init_cnt_n = '0;
          state_n    = S_IDLE;
        end else begin
          init_cnt_n = init_cnt_r + 1'b1;
        end
      end

      S_IDLE: begin
        cpu_req_ready = !cpu_req_valid || hot_hit; // no req or hot_hit = ready
        served_n      = 1'b0; // no refill active

        if (cpu_req_valid && hot_hit) begin
          if (cpu_req_write == 4'b0000) begin //4'b0000 = read, no SRAM Access - 0 Cycle Latency hit
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
            tag_din   = make_meta(1'b1, 1'b1, cpu_tag); // set to dirty
          end
        end else if (cpu_req_valid) begin // if request there but no hot_hit --> Read Tag_SRAM --> S_LOOKUP
          tag_ce       = 1'b1;
          tag_addr     = {WAY_BITS'(0), cpu_index};
          data_ce      = 1'b1;
          data_addr    = {WAY_BITS'(0), cpu_index, cpu_beat};
          lookup_way_n = WAY_BITS'(0);
          state_n      = S_LOOKUP;
        end
      end

      S_LOOKUP: begin
        if (sram_hit) begin // SRAM hit for only read and write --> afterwards go back to S_IDLE
          if (req_write_r == 4'b0000) begin // just read (4'b000)
            cpu_resp_valid = 1'b1;
            cpu_resp_data  = sram_word_old;
          end else begin // write
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
        end else if (lookup_way_r == WAY_BITS'(0)) begin // Way_0 was miss, now try Way_1
          tag_ce       = 1'b1;
          tag_addr     = {WAY_BITS'(1), req_index_r};
          data_ce      = 1'b1;
          data_addr    = {WAY_BITS'(1), req_index_r, req_beat_r};
          lookup_way_n = WAY_BITS'(1);
          state_n      = S_LOOKUP; // at next posedge, now check lookup_way_n = 1
        end else begin // both way miss
          beat_cnt_n = '0; // set beat cnt back
          if (victim_dirty_sel) begin // select victim & check if dirty
            data_ce   = 1'b1;
            data_addr = {victim_way_sel, req_index_r, {BEAT_BITS{1'b0}}};
            state_n   = S_WB_ADDR; // WB victim if dirty
          end else begin 
            state_n   = S_READ_ADDR; // if not dirty, directly S_READ_ADDR
          end
        end
      end

      S_WB_ADDR: begin // Writes Adress for wb to mem
        mem_req_valid = 1'b1;
        mem_req_rw    = 1'b1;
        mem_req_addr  = wb_mem_addr;

        if (mem_req_ready) begin // waits until mem signals that its ready
          state_n = S_WB_DATA;
        end
      end

      S_WB_DATA: begin
        mem_req_data_valid = 1'b1;
        mem_req_data_bits  = sram_beat;
        mem_req_data_mask  = '1; // all 16 bytes are written

        if (mem_req_data_ready) begin
          if (beat_cnt_r == BEAT_BITS'(BEATS_PER_LINE-1)) begin // if last beat, reset and finish
            beat_cnt_n = '0;
            state_n    = S_READ_ADDR;
          end else begin // continue to fill in the other beats
            beat_cnt_n = beat_cnt_r + 1'b1;
            data_ce    = 1'b1;
            data_addr  = {victim_way_r, req_index_r, beat_cnt_r + 1'b1};
            state_n    = S_WB_ADDR;
          end
        end
      end

      S_READ_ADDR: begin // sends address, wants 4 beat answer
        mem_req_valid = 1'b1;
        mem_req_rw    = 1'b0;
        mem_req_addr  = refill_mem_addr;

        if (mem_req_ready) begin
          beat_cnt_n = '0;
          state_n    = S_READ_DATA;
        end
      end

      S_READ_DATA: begin
        if (mem_resp_valid) begin // SRAM Write: incoming beat in all 4 Banks; each one received one of the 4 words of the beat
          data_ce   = 1'b1;
          data_addr = {victim_way_r, req_index_r, beat_cnt_r};
          for (int i = 0; i < WORDS_PER_BEAT; i++) begin
            data_we   [i] = 1'b1;
            data_wmask[i] = 4'hF;
            data_din  [i] = refill_beat_new[i*CPU_WIDTH +: CPU_WIDTH];
          end

          // Early Serve with Read-Miss
          if ((req_write_r == 4'b0000) &&
              (beat_cnt_r == req_beat_r) && !served_q) begin
            cpu_resp_valid = 1'b1;
            cpu_resp_data  = refill_word_old;
            cpu_req_ready  = 1'b1;
            served_n       = 1'b1;
          end

          // Last beat --> Update Tag-SRAM & back to S_IDLE
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
    if (reset) begin // if reset --> all back to 0; state |-> S_INIT
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
    end else begin // one the next clk, all currently saved values will become the next values
      state        <= state_n;
      init_cnt_r   <= init_cnt_n;
      beat_cnt_r   <= beat_cnt_n;
      lookup_way_r <= lookup_way_n;
      served_q     <= served_n;

      // write hot-hit --> update hotbuffer
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

      // at each hot-hit the replacement bit for the set is placed in a way, such that the next victim is the other way
      if (state == S_IDLE && cpu_req_valid && hot_hit) begin
        repl_way[cpu_index] <= ~hot_way;
      end

      // if request cannot be served hot, cpu_* values are latched in req_*S_READ_
      // cpu can change and cache has its own copy for the next cycles in S_LOOKUP/S_WB/S_READ_
      if (state == S_IDLE && cpu_req_valid && !hot_hit) begin
        req_tag_r          <= cpu_tag;
        req_index_r        <= cpu_index;
        req_beat_r         <= cpu_beat;
        req_word_in_beat_r <= cpu_word_in_beat;
        req_write_r        <= cpu_req_write;
        req_data_r         <= cpu_req_data;
      end

      // after SRAM-Hit, Beatbuf is filled up w/current beat data
      if (state == S_LOOKUP && sram_hit) begin
        beatbuf_valid <= 1'b1;
        beatbuf_way   <= lookup_way_r;
        beatbuf_tag   <= req_tag_r;
        beatbuf_index <= req_index_r;
        beatbuf_beat  <= req_beat_r;
        beatbuf_data  <= (req_write_r == 4'b0000) ? sram_beat : sram_beat_new;
        repl_way[req_index_r] <= ~lookup_way_r; // NRU Bit (Not recently used) = other Way
      end

      // if way_0 missed and we swap to way_1, before tag-sram gets overwritten - snap of Way_0_Metadata
      // Data needed in victim selection --> victim_dirty_sel uses way0_*_r
      if (state == S_LOOKUP && !sram_hit && (lookup_way_r == WAY_BITS'(0))) begin
        way0_valid_r <= tag_dout_valid;
        way0_dirty_r <= tag_dout_dirty;
        way0_tag_r   <= tag_dout_tag;
      end

      // if after way_0 also way_1 is missed --> safe victim-selection --> used for wb_mem_addr
      // selected vs in register
      if (state == S_LOOKUP && !sram_hit && (lookup_way_r == WAY_BITS'(1))) begin
        victim_way_r <= victim_way_sel;
        victim_tag_r <= victim_tag_sel;
      end

      // set refill line back
      // register buffer for the cache line currently being loaded from memory.
      if (state == S_READ_ADDR && mem_req_ready) begin
        refill_line_r <= '0;
      end

      if (state == S_READ_DATA && mem_resp_valid) begin
        refill_line_r <= refill_line_new; // for each new beat, refill_line_r is updated

        if (beat_cnt_r == BEAT_BITS'(BEATS_PER_LINE-1)) begin // at the last beat, in addition Linebuf commit beatbuf invalid, NRU (Not recently used) Update
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
