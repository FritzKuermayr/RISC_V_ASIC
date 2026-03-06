//  Module: ALUTestbench
//  Desc:   32-bit ALU testbench for the RISC-V Processor
//  Feel free to edit this testbench to add additional functionality
//
//  Note that this testbench only tests correct operation of the ALU,
//  it doesn't check that you're mux-ing the correct values into the inputs
//  of the ALU.

// If #1 is in the initial block of your testbench, time advances by
// 1ns rather than 1ps
`timescale 1ns / 1ps
`default_nettype none

import opcode_pkg::*;
import alu_op_pkg::*;

module ALUTestbench;

  parameter int Halfcycle = 5; // half period is 5ns
  localparam int Cycle = 2 * Halfcycle;

  logic Clock;

  // Clock Signal generation:
  initial Clock = 1'b0;
  always #(Halfcycle) Clock = ~Clock;

  // Registers and wires to test the ALU
  logic [2:0]  funct;
  logic        add_rshift_type;
  logic [6:0]  opcode;
  logic [31:0] A, B;

  logic [31:0] DUTout;
  logic [31:0] REFout;

  // With packages, ALUop is a type, not a macro-defined [3:0]
  alu_op_t ALUop;

  logic [30:0] rand_31;
  logic [14:0] rand_15;

  // Signed operations; these are useful for signed operations
  logic signed [31:0] B_signed;
  assign B_signed = $signed(B);

  logic signed_comp, unsigned_comp;
  assign signed_comp   = ($signed(A) < $signed(B));
  assign unsigned_comp = (A < B);

  // Task for checking output
  task automatic checkOutput(
    input logic [6:0] opcode_i,
    input logic [2:0] funct_i,
    input logic       add_rshift_type_i
  );
    if (REFout !== DUTout) begin
      $display("FAIL: Incorrect result for opcode %b, funct: %b:, add_rshift_type: %b",
               opcode_i, funct_i, add_rshift_type_i);
      $display("\tA: 0x%h, B: 0x%h, DUTout: 0x%h, REFout: 0x%h", A, B, DUTout, REFout);
      $finish();
    end else begin
      $display("PASS: opcode %b, funct %b, add_rshift_type %b",
               opcode_i, funct_i, add_rshift_type_i);
      $display("\tA: 0x%h, B: 0x%h, DUTout: 0x%h, REFout: 0x%h", A, B, DUTout, REFout);
    end
  endtask

  // This is where the modules being tested are instantiated.
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

  integer i;
  localparam int loops = 25; // number of times to run the tests for

  // Testing logic:
  initial begin
    $vcdpluson;
    for (i = 0; i < loops; i = i + 1) begin
      /////////////////////////////////////////////
      // Put your random tests inside of this loop
      // and hard-coded tests outside of the loop
      // (see comment below)
      /////////////////////////////////////////////
      #1;
      // Make both A and B negative to check signed operations
      rand_31 = {$random} & 31'h7FFF_FFFF;
      rand_15 = {$random} & 15'h7FFF;
      A       = {1'b1, rand_31};
      // Hard-wire 16 1's in front of B for sign extension
      B       = {16'hFFFF, 1'b1, rand_15};
      // Set funct random to test that it doesn't affect non-R-type insts

      // Tests for the non R-Type and I-Type instructions.
      // Add your own tests for R-Type and I-Type instructions
      opcode          = OPC_LUI;
      // Set funct random to verify that the value doesn't matter
      funct           = $random & 3'b111;
      add_rshift_type = $random & 1'b1;
      REFout          = B;
      #1;
      checkOutput(opcode, funct, add_rshift_type);

      opcode          = OPC_AUIPC;
      funct           = $random & 3'b111;
      add_rshift_type = $random & 1'b1;
      REFout          = A + B;
      #1;
      checkOutput(opcode, funct, add_rshift_type);

      opcode          = OPC_BRANCH;
      funct           = $random & 3'b111;
      add_rshift_type = $random & 1'b1;
      REFout          = A + B;
      #1;
      checkOutput(opcode, funct, add_rshift_type);

      opcode          = OPC_LOAD;
      funct           = $random & 3'b111;
      add_rshift_type = $random & 1'b1;
      REFout          = A + B;
      #1;
      checkOutput(opcode, funct, add_rshift_type);

      opcode          = OPC_STORE;
      funct           = $random & 3'b111;
      add_rshift_type = $random & 1'b1;
      REFout          = A + B;
      #1;
      checkOutput(opcode, funct, add_rshift_type);
    end

    ///////////////////////////////
    // Hard coded tests go here
    ///////////////////////////////

    $display("\n\nALL TESTS PASSED!");
    $vcdplusoff;
    $finish();
  end

endmodule
