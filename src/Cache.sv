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

endmodule
