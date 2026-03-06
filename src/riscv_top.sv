`default_nettype none

import const_pkg::*;

module riscv_top (
  input  logic                     clk,
  input  logic                     reset,

  output logic                     mem_req_valid,
  input  logic                     mem_req_ready,
  output logic                     mem_req_rw,
  output logic [MEM_ADDR_BITS-1:0] mem_req_addr,
  output logic [MEM_TAG_BITS-1:0]  mem_req_tag,

  output logic                     mem_req_data_valid,
  input  logic                     mem_req_data_ready,
  output logic [MEM_DATA_BITS-1:0] mem_req_data_bits,
  output logic [(MEM_DATA_BITS/8)-1:0] mem_req_data_mask,

  input  logic                     mem_resp_valid,
  input  logic [MEM_TAG_BITS-1:0]  mem_resp_tag,
  input  logic [MEM_DATA_BITS-1:0] mem_resp_data,
  output logic [31:0]              csr
);

  logic [31:0] dcache_addr; // From cpu of Riscv151
  logic [31:0] dcache_din;  // From cpu of Riscv151
  logic [31:0] dcache_dout; // From mem of Memory151
  logic        dcache_re;   // From cpu of Riscv151
  logic [3:0]  dcache_we;   // From cpu of Riscv151
  logic [31:0] icache_addr; // From cpu of Riscv151
  logic [31:0] icache_dout; // From mem of Memory151
  logic        icache_re;   // From cpu of Riscv151
  logic        stall;       // From mem of Memory151

  Memory151 mem (
    // Outputs
    .dcache_dout         (dcache_dout),
    .icache_dout         (icache_dout),
    .stall               (stall),
    .mem_req_valid       (mem_req_valid),
    .mem_req_rw          (mem_req_rw),
    .mem_req_addr        (mem_req_addr),
    .mem_req_tag         (mem_req_tag),
    .mem_req_data_valid  (mem_req_data_valid),
    .mem_req_data_bits   (mem_req_data_bits),
    .mem_req_data_mask   (mem_req_data_mask),

    // Inputs
    .clk                 (clk),
    .reset               (reset),
    .dcache_addr         (dcache_addr),
    .icache_addr         (icache_addr),
    .dcache_we           (dcache_we),
    .dcache_re           (dcache_re),
    .icache_re           (icache_re),
    .dcache_din          (dcache_din),
    .mem_req_ready       (mem_req_ready),
    .mem_req_data_ready  (mem_req_data_ready),
    .mem_resp_valid      (mem_resp_valid),
    .mem_resp_data       (mem_resp_data),
    .mem_resp_tag        (mem_resp_tag)
  );

  // RISC-V 151 CPU
  Riscv151 cpu (
    // Outputs
    .dcache_addr (dcache_addr),
    .icache_addr (icache_addr),
    .dcache_we   (dcache_we),
    .dcache_re   (dcache_re),
    .icache_re   (icache_re),
    .dcache_din  (dcache_din),
    .csr         (csr),

    // Inputs
    .clk         (clk),
    .reset       (reset),
    .dcache_dout (dcache_dout),
    .icache_dout (icache_dout),
    .stall       (stall)
  );

endmodule
