`default_nettype none

import const_pkg::*;

module Riscv151 (
  input  logic        clk,
  input  logic        reset,

  // Memory system ports
  output logic [31:0] dcache_addr,
  output logic [31:0] icache_addr,
  output logic [3:0]  dcache_we,
  output logic        dcache_re,
  output logic        icache_re,
  output logic [31:0] dcache_din,
  input  logic [31:0] dcache_dout,
  input  logic [31:0] icache_dout,
  input  logic        stall,
  output logic [31:0] csr
);

  // Implement your core here, then delete this comment

endmodule
