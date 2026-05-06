`default_nettype none

import const_pkg::*;

module Memory151 (
  input  logic clk,
  input  logic reset,

  // Cache <=> CPU interface
  input  logic [31:0] dcache_addr,
  input  logic [31:0] icache_addr,
  input  logic [3:0]  dcache_we,
  input  logic        dcache_re,
  input  logic        icache_re,
  input  logic [31:0] dcache_din,
  output logic [31:0] dcache_dout,
  output logic [31:0] icache_dout,
  output logic        stall,

  // Arbiter <=> Main memory interface
  output logic                  mem_req_valid,
  input  logic                  mem_req_ready,
  output logic                  mem_req_rw,
  output logic [MEM_ADDR_BITS-1:0] mem_req_addr,
  output logic [MEM_TAG_BITS-1:0]  mem_req_tag,

  output logic                     mem_req_data_valid,
  input  logic                     mem_req_data_ready,
  output logic [MEM_DATA_BITS-1:0]  mem_req_data_bits,
  output logic [(MEM_DATA_BITS/8)-1:0] mem_req_data_mask,

  input  logic                     mem_resp_valid,
  input  logic [MEM_DATA_BITS-1:0]  mem_resp_data,
  input  logic [MEM_TAG_BITS-1:0]   mem_resp_tag
);

  logic i_stall_n;
  logic d_stall_n;

  logic ic_mem_req_valid;
  logic ic_mem_req_ready;
  logic [MEM_ADDR_BITS-1:0] ic_mem_req_addr;
  logic ic_mem_resp_valid;

  logic dc_mem_req_valid;
  logic dc_mem_req_ready;
  logic dc_mem_req_rw;
  logic [MEM_ADDR_BITS-1:0] dc_mem_req_addr;
  logic dc_mem_resp_valid;

  logic [(MEM_DATA_BITS/8)-1:0] dc_mem_req_mask; // (kept for parity with original; may be unused)

`ifdef no_cache_mem
  no_cache_mem icache (
    .clk          (clk),
    .reset        (reset),
    .cpu_req_valid(icache_re),
    .cpu_req_ready(i_stall_n),
    .cpu_req_addr (icache_addr[31:2]),
    .cpu_req_data (),          // core does not write to icache
    .cpu_req_write(4'b0),      // never write
    .cpu_resp_valid(),
    .cpu_resp_data(icache_dout)
  );

  no_cache_mem dcache (
    .clk          (clk),
    .reset        (reset),
    .cpu_req_valid((|dcache_we) || dcache_re),
    .cpu_req_ready(d_stall_n),
    .cpu_req_addr (dcache_addr[31:2]),
    .cpu_req_data (dcache_din),
    .cpu_req_write(dcache_we),
    .cpu_resp_valid(),
    .cpu_resp_data(dcache_dout)
  );

  assign stall = (!i_stall_n) || (!d_stall_n);

`else
  cache icache (
    .clk            (clk),
    .reset          (reset),
    .cpu_req_valid  (icache_re),
    .cpu_req_ready  (i_stall_n),
    .cpu_req_addr   (icache_addr[31:2]),
    .cpu_req_data   (),          // core does not write to icache
    .cpu_req_write  (4'b0),      // never write
    .cpu_resp_valid (),
    .cpu_resp_data  (icache_dout),

    .mem_req_valid      (ic_mem_req_valid),
    .mem_req_ready      (ic_mem_req_ready),
    .mem_req_addr       (ic_mem_req_addr),
    .mem_req_data_valid (),
    .mem_req_data_bits  (),
    .mem_req_data_mask  (),
    .mem_req_data_ready (),
    .mem_req_rw         (),

    .mem_resp_valid (ic_mem_resp_valid),
    .mem_resp_data  (mem_resp_data)
  );

  cache dcache (
    .clk            (clk),
    .reset          (reset),
    .cpu_req_valid  ((|dcache_we) || dcache_re),
    .cpu_req_ready  (d_stall_n),
    .cpu_req_addr   (dcache_addr[31:2]),
    .cpu_req_data   (dcache_din),
    .cpu_req_write  (dcache_we),
    .cpu_resp_valid (),
    .cpu_resp_data  (dcache_dout),

    .mem_req_valid      (dc_mem_req_valid),
    .mem_req_ready      (dc_mem_req_ready),
    .mem_req_addr       (dc_mem_req_addr),
    .mem_req_rw         (dc_mem_req_rw),
    .mem_req_data_valid (mem_req_data_valid),
    .mem_req_data_bits  (mem_req_data_bits),
    .mem_req_data_mask  (mem_req_data_mask),
    .mem_req_data_ready (mem_req_data_ready),

    .mem_resp_valid (dc_mem_resp_valid),
    .mem_resp_data  (mem_resp_data)
  );

  assign stall = (!i_stall_n) || (!d_stall_n);

  //                           ICache
  //                         /        \
  //   Riscv151 --- Memory151          Arbiter <--> ExtMemModel
  //                         \        /
  //                           DCache

  riscv_arbiter arbiter (
    .clk            (clk),
    .reset          (reset),

    .ic_mem_req_valid (ic_mem_req_valid),
    .ic_mem_req_ready (ic_mem_req_ready),
    .ic_mem_req_addr  (ic_mem_req_addr),
    .ic_mem_resp_valid(ic_mem_resp_valid),

    .dc_mem_req_valid (dc_mem_req_valid),
    .dc_mem_req_ready (dc_mem_req_ready),
    .dc_mem_req_rw    (dc_mem_req_rw),
    .dc_mem_req_addr  (dc_mem_req_addr),
    .dc_mem_resp_valid(dc_mem_resp_valid),

    .mem_req_valid (mem_req_valid),
    .mem_req_ready (mem_req_ready),
    .mem_req_rw    (mem_req_rw),
    .mem_req_addr  (mem_req_addr),
    .mem_req_tag   (mem_req_tag),
    .mem_resp_valid(mem_resp_valid),
    .mem_resp_tag  (mem_resp_tag)
  );
`endif

endmodule

`default_nettype wire
