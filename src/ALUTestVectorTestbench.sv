//  Module: ALUTestVectorTestbench
//  Desc:   Alternative 32-bit ALU testbench for the RISC-V Processor
//  Feel free to edit this testbench to add additional functionality
//
//  Note that this testbench only tests correct operation of the ALU,
//  it doesn't check that you're mux-ing the correct values into the inputs
//  of the ALU.

`timescale 1ns / 1ps
`default_nettype none

import opcode_pkg::*;
import alu_op_pkg::*;

module ALUTestVectorTestbench;

  parameter int Halfcycle = 5; // half period is 5ns
  localparam int Cycle = 2 * Halfcycle;

  logic Clock;

  // Clock Signal generation:
  initial Clock = 1'b0;
  always #(Halfcycle) Clock = ~Clock;

  // Signals read from the input vector
  logic [6:0]  opcode;
  logic [2:0]  funct;
  logic        add_rshift_type;
  logic [31:0] A, B;
  logic [31:0] REFout;

  logic [31:0] DUTout;
  alu_op_t     ALUop;

  // Task for checking output
  task automatic checkOutput(
    input logic [6:0] opcode_i,
    input logic [2:0] funct_i,
    input logic       add_rshift_type_i
  );
    if (REFout !== DUTout) begin
      $display("FAIL: Incorrect result for opcode %b, funct: %b, add_rshift_type: %b",
               opcode_i, funct_i, add_rshift_type_i);
      $display("\tA: 0x%h, B: 0x%h, DUTout: 0x%h, REFout: 0x%h", A, B, DUTout, REFout);
      $finish();
    end else begin
      $display("PASS: opcode %b, funct %b, add_rshift_type %b",
               opcode_i, funct_i, add_rshift_type_i);
      $display("\tA: 0x%h, B: 0x%h, DUTout: 0x%h, REFout: 0x%h", A, B, DUTout, REFout);
    end
  endtask

  // Modules being tested
  ALUdec DUT1 (
    .opcode(opcode),
    .funct(funct),
    .add_rshift_type(add_rshift_type),
    .ALUop(ALUop)
  );

  ALU DUT2 (
    .A(A),
    .B(B),
    .ALUop(ALUop),
    .Out(DUTout)
  );

  /////////////////////////////////////////////////////////////////
  // Change this number to reflect the number of testcases in your
  // testvector input file, which you can find with the command:
  // % wc -l ../tests/testvectors.input
  /////////////////////////////////////////////////////////////////
  localparam int testcases = 130;

  // Each testcase has 107:0 => 108 bits total (matches original)
  logic [106:0] testvector [0:testcases-1];

  integer i;

  initial begin
    $vcdpluson;
    $readmemb("../../tests/testvectors.input", testvector);

    for (i = 0; i < testcases; i = i + 1) begin
      // TODO: unpack testvector[i] into opcode/funct/add_rshift_type/A/B/REFout,
      // drive inputs, wait as needed, then call checkOutput(opcode, funct, add_rshift_type).

      opcode = testvector[i][106:100];
      funct  = testvector[i][99:97];
      add_rshift_type = testvector[i][96];
      A = testvector[i][95:64];
      B = testvector[i][63:32];
      REFout = testvector[i][31:0];
      
      #1;
      checkOutput(opcode, funct, add_rshift_type);
    end

    $display("\n\nALL TESTS PASSED!");
    $vcdplusoff;
    $finish();
  end

endmodule
