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
  always_comb begin
	  ALUop = ALU_XXX;

	  unique case (opcode)
	  	OPC_AUIPC,
		OPC_JAL,
		OPC_JALR,
		OPC_BRANCH,
		OPC_LOAD,
		OPC_STORE: ALUop = ALU_ADD;

		OPC_LUI: ALUop = ALU_COPY_B;

		OPC_CSR: ALUop = ALU_COPY_B;

		OPC_ARI_ITYPE: begin
			unique case (funct)
				FNC_ADD_SUB : ALUop = ALU_ADD;
				FNC_SLL : ALUop = ALU_SLL;
				FNC_SLT : ALUop = ALU_SLT;
				FNC_SLTU : ALUop = ALU_SLTU;
				FNC_XOR : ALUop = ALU_XOR;
				FNC_SRL_SRA : ALUop = add_rshift_type ? ALU_SRA : ALU_SRL;
				FNC_OR : ALUop = ALU_OR;
				FNC_AND : ALUop = ALU_AND;
				default : ALUop = ALU_XXX;
			endcase
		end

		OPC_ARI_RTYPE: begin
			unique case (funct)
				FNC_ADD_SUB : ALUop = add_rshift_type ? ALU_SUB : ALU_ADD; // SUB / ADD
				FNC_SLL     : ALUop = ALU_SLL;
			        FNC_SLT     : ALUop = ALU_SLT;
			        FNC_SLTU    : ALUop = ALU_SLTU;
				FNC_XOR     : ALUop = ALU_XOR;
				FNC_SRL_SRA : ALUop = add_rshift_type ? ALU_SRA : ALU_SRL; // SRA / SRL
				FNC_OR      : ALUop = ALU_OR;
			        FNC_AND     : ALUop = ALU_AND;
				default     : ALUop = ALU_XXX;
			endcase
		end

		default: ALUop = ALU_XXX;
	endcase
  end

endmodule

`default_nettype wire
