// Test harness for EECS151 RISC-V Processor
`default_nettype none

import const_pkg::*;
`define INPUT_DELAY (`CLOCK_PERIOD / 5)

module rocketTestHarness;

  logic [31:0] seed;
  initial seed = $get_initial_random_seed();

  //-----------------------------------------------
  // Setup clocking and reset

  logic clk   = 1'b0;
  logic reset = 1'b1;
  logic r_reset;
  logic start = 1'b0;

  always #(`CLOCK_PERIOD*0.5) clk = ~clk;

  logic                        mem_req_valid, mem_req_rw, mem_req_data_valid;
  logic [MEM_TAG_BITS-1:0]     mem_req_tag;
  logic [MEM_ADDR_BITS-1:0]    mem_req_addr;
  logic [MEM_DATA_BITS-1:0]    mem_req_data_bits;
  logic                        mem_req_ready, mem_req_data_ready, mem_resp_valid;

  // Delayed inputs to DUT
  wire #`INPUT_DELAY mem_req_ready_delay      = mem_req_ready;
  wire #`INPUT_DELAY mem_req_data_ready_delay = mem_req_data_ready;
  wire #`INPUT_DELAY mem_resp_valid_delay     = mem_resp_valid;

  logic [MEM_TAG_BITS-1:0]  mem_resp_tag;
  wire [MEM_TAG_BITS-1:0] #`INPUT_DELAY mem_resp_tag_delay = mem_resp_tag;

  logic [MEM_DATA_BITS-1:0] mem_resp_data;
  wire [MEM_DATA_BITS-1:0] #`INPUT_DELAY mem_resp_data_delay = mem_resp_data;

  logic [(MEM_DATA_BITS/8)-1:0] mem_req_data_mask;
  logic [31:0]                  exit;

  //-----------------------------------------------
  // Instantiate the processor

  riscv_top dut (
    .clk                (clk),
    .reset              (r_reset),
    .mem_req_valid      (mem_req_valid),
    .mem_req_ready      (mem_req_ready_delay),
    .mem_req_rw         (mem_req_rw),
    .mem_req_addr       (mem_req_addr),
    .mem_req_tag        (mem_req_tag),
    .mem_req_data_valid (mem_req_data_valid),
    .mem_req_data_ready (mem_req_data_ready_delay),
    .mem_req_data_bits  (mem_req_data_bits),
    .mem_req_data_mask  (mem_req_data_mask),
    .mem_resp_valid     (mem_resp_valid_delay),
    .mem_resp_tag       (mem_resp_tag_delay),
    .mem_resp_data      (mem_resp_data_delay),
    .csr                (exit)
  );

  //-----------------------------------------------
  // Memory interface

  always_ff @(negedge clk) begin
    r_reset <= reset;
  end

  ExtMemModel mem (
    .clk                (clk),
    .reset              (r_reset),
    .mem_req_valid      (mem_req_valid),
    .mem_req_ready      (mem_req_ready),
    .mem_req_rw         (mem_req_rw),
    .mem_req_addr       (mem_req_addr),
    .mem_req_tag        (mem_req_tag),
    .mem_req_data_valid (mem_req_data_valid),
    .mem_req_data_ready (mem_req_data_ready),
    .mem_req_data_bits  (mem_req_data_bits),
    .mem_req_data_mask  (mem_req_data_mask),
    .mem_resp_valid     (mem_resp_valid),
    .mem_resp_data      (mem_resp_data),
    .mem_resp_tag       (mem_resp_tag)
  );

  //-----------------------------------------------
  // Start the simulation

  logic [31:0]   mem_width      = MEM_DATA_BITS;
  logic [63:0]   max_cycles     = 64'd0;
  logic [63:0]   trace_count    = 64'd0;
  logic [1023:0] loadmem        = 1024'd0;
  logic [1023:0] vcdplusfile    = 1024'd0;
  logic [1023:0] vcdfile        = 1024'd0;
  logic          stats_active   = 1'b0;
  logic          stats_tracking = 1'b0;
  logic          verbose        = 1'b0;
  integer        stderr         = 32'h80000002;

  logic [31:0] clksel = 32'd0;

  // Helper tasks for stat tracking
  task automatic start_stats;
    begin
      if (!reset || !stats_active) begin
`ifdef DEBUG
        if (vcdplusfile) begin
          $vcdpluson(0);
          $vcdplusmemon(0);
        end
        if (vcdfile) begin
          $dumpon;
        end
`endif
        stats_tracking = 1'b1;
      end
    end
  endtask

  task automatic stop_stats;
    begin
`ifdef DEBUG
      $vcdplusoff;
      $dumpoff;
`endif
      stats_tracking = 1'b0;
    end
  endtask

`ifdef DEBUG
  `define VCDPLUSCLOSE $vcdplusclose; $dumpoff;
`else
  `define VCDPLUSCLOSE
`endif

  // Read input arguments and initialize
  initial begin
    void'($value$plusargs("max-cycles=%d", max_cycles));
    void'($value$plusargs("loadmem=%s", loadmem));

    if (loadmem) begin
`ifdef no_cache_mem
      #0.1 $readmemh(loadmem, dut.mem.icache.ram);
      #0.1 $readmemh(loadmem, dut.mem.dcache.ram);
`else
      #0.1 $readmemh(loadmem, mem.ram);
`endif
    end

    verbose = $test$plusargs("verbose");

`ifdef DEBUG
    stats_active = $test$plusargs("stats");
    if ($value$plusargs("vcdplusfile=%s", vcdplusfile)) begin
      $vcdplusfile(vcdplusfile);
    end
    if ($value$plusargs("vcdfile=%s", vcdfile)) begin
      $dumpfile(vcdfile);
      $dumpvars(0, dut);
    end
    if (!stats_active) begin
      start_stats();
    end else begin
      if (vcdfile) begin
        $dumpoff;
      end
    end
`endif

    // Strobe reset
    #100 reset = 1'b0;
  end

  logic [255:0] reason = 256'd0;

  always @(posedge clk) begin
    if (reset == 1'b0) begin
      #0.1;
`ifndef GATELEVEL
      $fwrite(32'h80000002, "C%0d: \n", trace_count);
`endif
    end

    if ((max_cycles > 0) && (trace_count > max_cycles)) begin
      reason = "timeout";
    end
    if ((exit > 32'd1) && (trace_count > 64'd1)) begin
      $sformat(reason, "tohost = %d", exit);
    end

    if (reason != 0) begin
      $fdisplay(stderr, "*** FAILED *** (%0s) after %0d simulation cycles", reason, trace_count);
      `VCDPLUSCLOSE
      $finish;
    end

    if (exit == 32'd1) begin
      $fdisplay(stderr, "*** PASSED *** (%0s) after %0d simulation cycles", reason, trace_count);
      `VCDPLUSCLOSE
      $finish;
    end
  end

  //-----------------------------------------------
  // Tracing code

  always @(posedge clk) begin
    if (stats_active) begin
      if (!stats_tracking) begin
        start_stats();
      end
      if (stats_tracking) begin
        stop_stats();
      end
    end
  end

  always_ff @(posedge clk) begin
    if (verbose && mem_req_valid && mem_req_ready) begin
      $fdisplay(stderr, "MB: rw=%d addr=%x", mem_req_rw, {mem_req_addr, 4'd0});
    end
  end

  always_ff @(posedge clk) begin
    trace_count <= trace_count + 64'd1;
`ifdef GATE_LEVEL
    if (verbose) begin
      $fdisplay(stderr, "C: %10d", trace_count - 64'd1);
    end
`endif
  end

endmodule

`default_nettype wire
