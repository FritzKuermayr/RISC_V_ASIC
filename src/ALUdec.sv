`default_nettype none

// Module: ALUdec
// Desc:   Sets the ALU operation
// Inputs:
//   opcode          : instruction opcode
//   funct           : funct3 field (for R-type / I-type instructions)
//   add_rshift_type : distinguishes ADD vs SUB, or SRL vs SRA
// Outputs:
//   ALUop           : selects the ALU operation

import opcode_pkg::*;
import alu_op_pkg::*;

module ALUdec (
  input  logic [6:0] opcode,
  input  logic [2:0] funct,
  input  logic       add_rshift_type,
  output alu_op_t    ALUop
);

  // Implement your ALU decoder here, then delete this comment

endmodule
