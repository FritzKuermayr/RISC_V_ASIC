`default_nettype none

import const_pkg::*;

module cache #(
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

  // Implement your cache here, then delete this comment

  localparam int unsigned NUM_WAYS = 2;
  localparam int unsigned SETS = LINES / NUM_WAYS;

  localparam int unsigned WORDS_PER_LINE = 16; // 512/32 (Bits per Line/CPU Word size)
  localparam int unsigned LINE_BITS = WORDS_PER_LINE * CPU_WIDTH; // 512
  localparam int unsigned BEATS_PER_LINE = 4; // 512/128 (128 = memory interface) --> requires 4 beats/cycles to perform memory transaction
  localparam int unsigned BEAT_BITS = $clog2(BEATS_PER_LINE); // 2 --> how many bits do i need to cover all beats

  localparam int unsigned OFFSET_BITS = $clog2(WORDS_PER_LINE); // 4 --> how many bits do i need to describe what word i want to adress
  localparam int unsigned INDEX_BITS = $clog2(SETS); // 2 lines per set --> 32 sets --> need 5 bits to describe all 32 sets
  localparam int unsigned TAG_BITS = WORD_ADDR_BITS - INDEX_BITS - OFFSET_BITS; //Tag Bits explain, which Memory Adress is rn in the cache

  localparam int unsigned MEM_WORDS_PER_BEAT = MEM_DATA_BITS / CPU_WIDTH; // 4
  localparam int unsigned MEM_ADDR_LSB = $clog2(MEM_WORDS_PER_BEAT); // 2
  
  logic [LINE_BITS-1:0] data_array [0:NUM_WAYS-1][0:SETS-1]; // thats everything --> saves 512 line bits with 2 NUM_WAYS & 32 SETS --> 64 Cache Lines with each 512 bits
  logic [TAG_BITS-1:0] tag_array [0:NUM_WAYS-1][0:SETS-1]; // saves for each cache line the tag bits
  logic valid_array [0:NUM_WAYS-1][0:SETS-1]; // single valid bit for each cache line (is this the valid line? if 1 --> Tag & Data are allowed to be used)
  logic dirty_array [0:NUM_WAYS-1][0:SETS-1]; // single dirty bt for each cache line (was this line changed w/o being written back into the main memory?)
  logic repl_array [0:SETS-1]; // Replacement Array --> Info, which Way should be replaced next

  integer i, j;

  // Parts of the CPU-Address after splitting up the Adresse for the Cache:
  //Idea: cpu_req_addr = [tag|index|offset]

  logic [OFFSET_BITS-1:0] cpu_offset;
  logic [INDEX_BITS-1:0] cpu_index;
  logic [TAG_BITS-1:0] cpu_tag;

  assign cpu_offset = cpu_req_addr[OFFSET_BITS-1:0];
  assign cpu_index = cpu_req_addr[OFFSET_BITS + INDEX_BITS - 1: OFFSET_BITS];
  assign cpu_tag = cpu_req_addr[WORD_ADDR_BITS-1:OFFSET_BITS + INDEX_BITS];

  logic [LINE_BITS-1:0] way0_line, way1_line;
  logic [TAG_BITS-1:0] way0_tag, way1_tag;
  logic way0_valid, way1_valid;
  logic way0_dirty, way1_dirty;

  logic hit0, hit1, hit; // Found in Way0/Way1/Any of the Ways
  logic hit_way; // e.g. assigne hit_way = hit1

  assign way0_line = data_array[0][cpu_index];
  assign way1_line = data_array[1][cpu_index];
  assign way0_tag = tag_array[0][cpu_index];
  assign way1_tag = tag_array[1][cpu_index];
  assign way0_valid = valid_array[0][cpu_index];
  assign way1_valid = valid_array[1][cpu_index];
  assign way0_dirty = dirty_array[0][cpu_index];
  assign way1_dirty = dirty_array[1][cpu_index];

  assign hit0 = way0_valid && (way0_tag == cpu_tag);
  assign hit1 = way1_valid && (way1_tag == cpu_tag);
  assign hit = hit0 || hit1;

  assign hit_way = hit1;

  logic victim_way_sel; // If I have to place a new line into this set, which way will I overwrite?
  logic victim_valid; // is the chosen victim entry currently valid? (is this the valid line? if 1 --> Tag & Data are allowed to be used)
  logic victim_dirty_cur; // is the chosen victim line dirty right now? (was this line changed w/o being written back into the main memory?)
  logic [TAG_BITS-1:0] victim_tag_cur; // This is the tag of the victim line currently in the cache.
  logic [LINE_BITS-1:0] victim_line_cur; // This is the actual 512-bit cache line data of the chosen victim.

  always_comb begin
    if (!way0_valid) begin
      victim_way_sel = 1'b0;
    end else if (!way1_valid) begin
      victim_way_sel = 1'b1;
    end else begin
      victim_way_sel = repl_array[cpu_index]; // For the current set cpu_index, use the stored replacement bit to decide which way to evict.
    end
  end

  assign victim_valid = victim_way_sel ? way1_valid : way0_valid;
  assign victim_dirty_cur = victim_way_sel ? way1_dirty : way0_dirty;
  assign victim_tag_cur = victim_way_sel ? way1_tag : way0_tag;
  assign victim_line_cur = victim_way_sel ? way1_line : way0_line;

  // Reads a whole word from a single Cache line

  function automatic logic [CPU_WIDTH-1:0] get_word_from_line(
    input logic [LINE_BITS-1:0] line,
    input logic [OFFSET_BITS-1:0] word_off
  );
    get_word_from_line = line[word_off * CPU_WIDTH +: CPU_WIDTH];
  endfunction

  // Function to put a 32-bit word in a cache line --> which line, how far off, what is the new word?

  function automatic logic [LINE_BITS-1:0] set_word_in_line(
    input logic [LINE_BITS-1:0] line,
    input logic [OFFSET_BITS-1:0] word_off,
    input logic [CPU_WIDTH-1:0] new_word
  );
    logic [LINE_BITS-1:0] tmp;
    begin
      tmp = line;
      tmp[word_off * CPU_WIDTH +: CPU_WIDTH] = new_word;
      set_word_in_line = tmp;
    end
  endfunction

  // Takes an existing 32-bit word, a new 32-bit write value, and a 4-bit byte mask, and returns the updated 32-bit word after applying the masked write.

  function automatic logic [CPU_WIDTH-1:0] apply_write_mask_to_word(
    input logic [CPU_WIDTH-1:0] old_word,
    input logic [CPU_WIDTH-1:0] write_word,
    input logic [3:0] write_mask
  );
    logic [CPU_WIDTH-1:0] tmp;
    begin
      tmp = old_word;
      if(write_mask[0]) tmp[7:0] = write_word[7:0];
      if(write_mask[1]) tmp[15:8] = write_word[15:8];
      if(write_mask[2]) tmp[23:16] = write_word[23:16];
      if(write_mask[3]) tmp[31:24] = write_word[31:24];
      apply_write_mask_to_word = tmp;
    end
  endfunction

  // Returns one 128-bit (beat) chunk from the full 512-bit cache line.

  function automatic logic [MEM_DATA_BITS-1:0] get_beat_from_line(
    input logic [LINE_BITS-1:0] line,
    input logic [BEAT_BITS-1:0] beat_idx
  );
    get_beat_from_line = line[beat_idx*MEM_DATA_BITS +: MEM_DATA_BITS];
  endfunction

  // Takes a full 512-bit line and replaces one 128-bit beat inside it with beat_data.

  function automatic logic [LINE_BITS-1:0] set_beat_in_line(
    input logic [LINE_BITS-1:0] line,
    input logic [BEAT_BITS-1:0] beat_idx,
    input logic [MEM_DATA_BITS-1:0] beat_data
  );
    logic [LINE_BITS-1:0] tmp;
    begin
      tmp = line;
      tmp[beat_idx * MEM_DATA_BITS +: MEM_DATA_BITS] = beat_data;
      set_beat_in_line = tmp;
    end
  endfunction

  // These are the latched request fields for a miss.
  // The cache needs them because a miss takes multiple cycles, 
  // so it must remember the original CPU request while doing writeback/refill.

  // on a miss, the cache stores the request here, handles memory traffic, 
  // and then later uses these saved fields to install the line and finish the read or write.

  logic [WORD_ADDR_BITS-1:0] req_addr_r;
  logic [CPU_WIDTH-1:0] req_data_r;
  logic [3:0] req_write_r;
  logic [OFFSET_BITS-1:0] req_offset_r;
  logic [INDEX_BITS-1:0] req_index_r;
  logic [TAG_BITS-1:0] req_tag_r;

  logic victim_way_r;
  logic [TAG_BITS-1:0] victim_tag_r;
  logic [LINE_BITS-1:0] victim_line_r;

  logic [LINE_BITS-1:0] refill_line_r; // stores the partially or fully refilled cache lin

  logic [ BEAT_BITS-1:0] beat_cnt_r, beat_cnt_n; // tells the cache which beat it is currently handling
  // beat_cnt_r = which 128-bit chunk is currently being received or sent
  // beat_cnt_n = what the counter should become next cycle 

  logic [WORD_ADDR_BITS-1:MEM_ADDR_LSB] refill_mem_addr; // This is the memory address used when the cache wants to fetch a missing cache line from main memory.
  logic [WORD_ADDR_BITS-1:MEM_ADDR_LSB] wb_mem_addr; // This is the memory address used when the cache wants to write back a dirty victim line to main memory.

  assign refill_mem_addr = {req_tag_r, req_index_r, {BEAT_BITS{1'b0}}}; // refill the new line
  assign wb_mem_addr = {victim_tag_r, req_index_r, beat_cnt_r}; // wb the old victim line

  typedef enum logic [2:0]{
    S_IDLE = 3'd0,
    S_WB_ADDR = 3'd1,
    S_WB_DATA = 3'd2,
    S_REFILL_ADDR = 3'd3,
    S_REFILL_WAIT = 3'd4,
    S_RESPOND = 3'd5
  } state_t;

  state_t state, state_n; // current and next state

  always_comb begin
    cpu_req_ready = 1'b0;
    cpu_resp_valid = 1'b0;
    cpu_resp_data = '0;

    mem_req_valid = 1'b0;
    mem_req_addr = '0;
    mem_req_rw = 1'b0;
    mem_req_data_valid = 1'b0;
    mem_req_data_bits = '0;
    mem_req_data_mask = '0;

    state_n = state;
    beat_cnt_n = beat_cnt_r;

    unique case (state)
      // cache FSM is in IDLE state --> now wb/refill rn in process
      S_IDLE: begin
        cpu_req_ready = !cpu_req_valid || hit; // ready to accept a request

        if (cpu_req_valid && hit) begin
          if (cpu_req_write == 4'b0000) begin
            cpu_resp_valid = 1'b1;
            cpu_resp_data = hit_way
                          ? get_word_from_line(way1_line, cpu_offset)
                          : get_word_from_line(way0_line, cpu_offset);
          end
        end else if (cpu_req_valid && !hit) begin
          beat_cnt_n = '0; // initialize beat counter for miss handling sequence
          if (victim_valid && victim_dirty_cur) begin // is wb needed?
            state_n = S_WB_ADDR; // need to wb
          end else begin
            state_n = S_REFILL_ADDR; // no wb needed --> can directly request new line from memory
          end
        end
      end

      // FSM state where cache start one wb beat adress request --> 
      // there was a miss, the victim line is dirty, so before a wb for the old victim line must occur to maintain mem
      // Happens in two steps: send the write addr & then the write data --> S_WB_ADDR is step 1

      S_WB_ADDR: begin
        mem_req_valid = 1'b1;
        mem_req_rw = 1'b1;
        mem_req_addr = wb_mem_addr;

        if (mem_req_ready) begin
          state_n = S_WB_DATA;
        end
      end

      // FSM state where the cache sends the actual writeback data beat to memory

      S_WB_DATA: begin
        mem_req_rw= 1'b1; // write transaction
        mem_req_data_valid = 1'b1; // write data on mem_req_data_bits is valid now
        mem_req_data_bits = get_beat_from_line(victim_line_r, beat_cnt_r); // This selects the current 128-bit beat from the dirty victim line; beat_cnt_r says if 0/1/2/3 is written rn
        mem_req_data_mask = {(MEM_DATA_BITS/8){1'b1}}; // creates an all 1s bit mask --> write all 16 bytes of this 128-bit beat

        if (mem_req_data_ready) begin // checks whether memory accepted the write data beat
          if (beat_cnt_r == BEATS_PER_LINE-1) begin // The full 512 bit victim line has now been written back
            beat_cnt_n = '0; // resets beat counter to 0
            state_n = S_REFILL_ADDR; // moves to next addr
          end else begin // more beats remain
            beat_cnt_n = beat_cnt_r + 1'b1; //go to next beat
            state_n = S_WB_ADDR; // stay in this state until all beats rewritten
          end
        end
      end

      // FSM state where the cache starts a refill read request to main memory
      // either there was no dirty victim or the dirty victim has already been wb
      // now the cache wants to fetch the missing line from mem

      S_REFILL_ADDR: begin
        mem_req_valid = 1'b1; // issue mem req
        mem_req_rw = 1'b0; // this is a read req, not a write
        mem_req_addr = refill_mem_addr; // gives addr of line to fetch

        // Handshake
        if (mem_req_ready) begin
          beat_cnt_n = '0;
          state_n = S_REFILL_WAIT;
        end
      end

      // FSM state where the cache is waiting for the refill data beats to come back from memory

      S_REFILL_WAIT: begin
        if (mem_resp_valid) begin
          if (beat_cnt_r == BEATS_PER_LINE-1) begin
            beat_cnt_n = '0;
            state_n = S_RESPOND;
          end else begin
            beat_cnt_n = beat_cnt_r +1'b1;
          end
        end
      end

      // FSM state right after the refill has finished

      S_RESPOND: begin
        cpu_req_ready  = 1'b1;
        if (req_write_r == 4'b0000) begin // Checks whether the original miss was a read miss; req_write_r = 4'b0000 → read; nonzero -> miss
          cpu_resp_valid = 1'b1; // if it was a read miss --> tell cpu data is now valid
          cpu_resp_data = get_word_from_line(refill_line_r, req_offset_r); // return the requested 32-bit word
        end
        state_n = S_IDLE;
      end
      
      default: begin
        state_n = S_IDLE;
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin // set everything back to 0
      state <= S_IDLE;
      beat_cnt_r <= '0;

      req_addr_r <= '0;
      req_data_r <= '0;
      req_write_r <= '0;
      req_offset_r <= '0;
      req_index_r <= '0;
      req_tag_r <= '0;

      victim_way_r <= 1'b0;
      victim_tag_r <= '0;
      victim_line_r <= '0;
      refill_line_r <= '0;

      for (i = 0; i < NUM_WAYS; i = i+1) begin
        for (j = 0; j < SETS; j = j+1) begin
          data_array[i][j] <= '0;
          tag_array[i][j] <= '0;
          valid_array[i][j] <= 1'b0;
          dirty_array[i][j] <= 1'b0;
        end
      end

      for (j = 0; j < SETS; j = j+1) begin
        repl_array[j] <= 1'b0;
      end
    end else begin //Sequential write-hit update logic
      // sequential state update
      state <= state_n;
      beat_cnt_r <= beat_cnt_n;

      // cache is idel, cpu makes a request, request hits cache and its write, not read --> write hit
      if (state == S_IDLE && cpu_req_valid && hit && (cpu_req_write != 4'b0000)) begin
        logic [CPU_WIDTH-1:0] old_word;
        logic [CPU_WIDTH-1:0] new_word;
        logic [LINE_BITS-1:0] new_line;
        logic way_sel;

        way_sel = hit_way;
        old_word = way_sel
                  ? get_word_from_line(way1_line, cpu_offset)
                  : get_word_from_line(way0_line, cpu_offset);
        new_word = apply_write_mask_to_word(old_word, cpu_req_data, cpu_req_write);
        new_line = way_sel
                  ? set_word_in_line(way1_line, cpu_offset, new_word)
                  : set_word_in_line(way0_line, cpu_offset, new_word);
        
        data_array[way_sel][cpu_index] <= new_line;
        tag_array[way_sel][cpu_index] <= cpu_tag;
        valid_array[way_sel][cpu_index] <= 1'b1;
        dirty_array[way_sel][cpu_index] <= 1'b1;

        repl_array[cpu_index] <= ~way_sel;
      end

      // same as above, but read instead of write
      if ( state == S_IDLE && cpu_req_valid && hit && (cpu_req_write == 4'b0000)) begin
        repl_array[cpu_index] <= ~hit_way; // look at which way was used on the hit --> set replacement bit to the other way
      end

      // miss in IDLE --> latches everything the cache will need later while handeling the miss
      if (state == S_IDLE && cpu_req_valid && !hit) begin
        // save CPU request
        req_addr_r <= cpu_req_addr;
        req_data_r <= cpu_req_data;
        req_write_r <= cpu_req_write;
        req_offset_r <= cpu_offset;
        req_index_r <= cpu_index;
        req_tag_r <= cpu_tag;

        // save victim info
        victim_way_r <= victim_way_sel;
        victim_tag_r <= victim_tag_cur;
        victim_line_r <= victim_line_cur;
        refill_line_r <= '0;
      end

      // stores an incoming refill beat into the refill buffer
      if (state == S_REFILL_WAIT && mem_resp_valid) begin
        refill_line_r <= set_beat_in_line(refill_line_r, beat_cnt_r, mem_resp_data);
      end

      // happens once full line has been fetched from mem
      if (state == S_RESPOND) begin
        // helpers
        logic [LINE_BITS-1:0] final_line;
        logic [CPU_WIDTH-1:0] old_word;
        logic [CPU_WIDTH-1:0] new_word;
        logic final_dirty;

        //by default, the line to install is the line that came back from mem & it is clean
        final_line = refill_line_r;
        final_dirty = 1'b0;

        // the original request was a miss
        if (req_write_r != 4'b0000) begin
          old_word = get_word_from_line(refill_line_r, req_offset_r);
          new_word = apply_write_mask_to_word(old_word, req_data_r, req_write_r); // merges cpu pending store into that word --> sb, sh, sw
          final_line = set_word_in_line(refill_line_r, req_offset_r, new_word); // pull updated word back into the line
          final_dirty = 1'b1; // make dirty
        end

        // install into the cache
        data_array[victim_way_r][req_index_r] <= final_line;
        tag_array[victim_way_r][req_index_r] <= req_tag_r;
        valid_array[victim_way_r][req_index_r] <= 1'b1;
        dirty_array[victim_way_r][req_index_r] <= final_dirty;

        // update replacement policy --> always fill the older one
        repl_array[req_index_r] <= ~victim_way_r;
      end
    end
  end

endmodule
