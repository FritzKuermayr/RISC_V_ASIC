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
    always_comb begin
	   unique case (ALUop)
	  	ALU_ADD : Out = A + B;
		ALU_SUB : Out = A - B;
		ALU_AND : Out = A & B;
		ALU_OR  : Out = A | B;
		ALU_XOR : Out = A ^ B;
		ALU_SLT : Out = ($signed(A) < $signed(B)) ? 32'd1 : 32'd0;
		ALU_SLTU : Out = (A < B) ? 32'd1 : 32'd0;
		ALU_SLL : Out = A << B[4:0];
		ALU_SRA : Out = $signed(A) >>> B[4:0];
	        ALU_SRL : Out = A >> B[4:0];
		ALU_COPY_B : Out = B;
	        default    : Out = 32'hXXXX_XXXX;
	   endcase
    end

endmodule
