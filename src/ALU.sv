`default_nettype none

// Module: ALU
// Desc:   32-bit ALU for the RISC-V Processor
// Inputs:
//   A, B  : 32-bit operands
//   ALUop : Selects the ALU operation
// Outputs:
//   Out   : Result of the selected operation on A and B

import opcode_pkg::*;
import alu_op_pkg::*;

module ALU (
    input  logic [31:0] A,
    input  logic [31:0] B,
    input  alu_op_t     ALUop,
    output logic [31:0] Out
);

    // Implement your ALU here, then delete this comment

endmodule
