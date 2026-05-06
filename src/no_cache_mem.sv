`default_nettype none

import const_pkg::*;

module no_cache_mem #(
  parameter int unsigned CPU_WIDTH      = CPU_INST_BITS,
  parameter int unsigned WORD_ADDR_BITS = CPU_ADDR_BITS - $clog2(CPU_INST_BITS/8)
) (
  input  logic clk,
  input  logic reset,

  input  logic                      cpu_req_valid,
  output logic                      cpu_req_ready,
  input  logic [WORD_ADDR_BITS-1:0] cpu_req_addr,
  input  logic [CPU_WIDTH-1:0]      cpu_req_data,
  input  logic [3:0]                cpu_req_write,

  output logic                 cpu_resp_valid,
  output logic [CPU_WIDTH-1:0] cpu_resp_data
);

  localparam int unsigned DEPTH = 2*1024*1024;
  localparam int unsigned WORDS = MEM_DATA_BITS/CPU_WIDTH;

  logic [MEM_DATA_BITS-1:0] ram [0:DEPTH-1];

  logic [WORD_ADDR_BITS-$clog2(WORDS)-1:0] upper_addr;
  assign upper_addr = cpu_req_addr[WORD_ADDR_BITS-1:$clog2(WORDS)];

  logic [$clog2(DEPTH)-1:0] ram_addr;
  assign ram_addr = upper_addr[$clog2(DEPTH)-1:0];

  logic [$clog2(WORDS)-1:0] lower_addr;
  assign lower_addr = cpu_req_addr[$clog2(WORDS)-1:0];

  logic [MEM_DATA_BITS-1:0] read_data;
  assign read_data = (ram[ram_addr] >> (CPU_WIDTH * lower_addr));

  assign cpu_req_ready = 1'b1;

  logic [CPU_WIDTH-1:0] wmask;
  assign wmask = {
    {8{cpu_req_write[3]}},
    {8{cpu_req_write[2]}},
    {8{cpu_req_write[1]}},
    {8{cpu_req_write[0]}}
  };

  logic [MEM_DATA_BITS-1:0] write_data;
  assign write_data =
      (ram[ram_addr] &
       ~({{(MEM_DATA_BITS-CPU_WIDTH){1'b0}}, wmask} << (CPU_WIDTH * lower_addr)))
    | ((cpu_req_data & wmask) << (CPU_WIDTH * lower_addr));

  always @(posedge clk) begin
    if (reset) begin
      cpu_resp_valid <= 1'b0;
    end else if (cpu_req_valid && cpu_req_ready) begin
      if (|cpu_req_write) begin
        cpu_resp_valid <= 1'b0;
        ram[ram_addr]  <= write_data;
      end else begin
        cpu_resp_valid <= 1'b1;
        cpu_resp_data  <= read_data[CPU_WIDTH-1:0];
      end
    end else begin
      cpu_resp_valid <= 1'b0;
    end
  end

  initial begin : zero
    integer i;
    for (i = 0; i < DEPTH; i = i + 1) begin
      ram[i] = '0;
    end
  end

endmodule

`default_nettype wire
