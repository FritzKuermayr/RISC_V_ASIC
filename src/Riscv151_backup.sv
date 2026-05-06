`default_nettype none

import const_pkg::*;
import alu_op_pkg::*;

module Riscv151 (
  input  logic        clk,
  input  logic        reset,

  // Memory system ports
  // 
  // ichace --> address sent to instruction mem, instruction read enable,
  // instruction returned from mem
  //
  //dcach --> data address, byte write mask, load & store data, loaded data
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

  """
  //Implementation
  logic [2:0] ImmSel;
  logic RegWEn;
  logic BrEq;
  logic BrLt;
  logic BSel;
  logic Asel;
  logic Bsel;
  logic [3:0] ALUSel;
  logic [1:0] PCSel;
  logic [1:0] WBSel;
  logic MemRW;
  """

  logic [31:0] regfile[0:31];
  integer i;

  // Fetch Stage
  
  logic [31:0] pc_f;
  logic [31:0] next_pc_f;
  logic [31:0] pc_plus4_f;

  assign pc_plus4 = pc_f + 32'd4;
  
  // F --> X Pipeline Registers
  logic [31:0] pc_x;
  logic [31:0] inst_x;

  // X stage decode files --> general "R" Structure --> if Imm needed afterwards
  
  logic [6:0] opcode_x;
  logic [4:0] rd_x;
  logic [2:0] funct3_x;
  logic [4:0] rs1_x;
  logic [4:0] rs2_x;
  logic [6:0] funct7_x;

  // differentiates between ADD and SUB or SRL and SRA
  logic add_rshift_type_x;

  assign opcode_x          = inst_x[6:0];
  assign rd_x              = inst_x[11:7];
  assign funct3_x          = inst_x[14:12];
  assign rs1_x             = inst_x[19:15];
  assign rs2_x             = inst_x[24:20];
  assign funct7_x          = inst_x[31:25];
  assign add_rshift_type_x = inst_x[30];

  // Different Imm assignements according to types I/S/B/U/J --> R doesnt need
  // Imm
  
  logic [31:0] imm_i_x;
  logic [31:0] imm_s_x;
  logic [31:0] imm_b_x;
  logic [31:0] imm_u_x;
  logic [31:0] imm_j_x;
  // Special Instruction Z for the CSR cases csrw and csrwi
  logic [31:0] imm_z_x;

  // assignement off those different Imms to the Instruction:
  // 20{inst_x} --> sign extension, repeats either 0 or 1 before
  assign imm_i_x = {{20{inst_x[31]}}, inst_x[31:20]};
  assign imm_s_x = {{20{inst_x[31]}}, inst_x[31:25], inst_x[11:7]};
  // for branch --> last bit needs 50 be 0 aka imm[12|10:5|4:1|11] << 1
  assign imm_b_x = {{19{inst_x[31]}}, inst_x[31], inst_x[7], inst_x[30:22], inst_x[11:8]};
  assign imm_u_x = {inst_x[31:12], 12'b0};
  assign imm_j_x = {{11{inst_x[31]}},inst[31], inst_x[19:12], inst_x[20] inst_x[30:21], 1'b0};
  assign imm_z_x = {27'b0, inst_x[19:15]}; // CSR immediate

  always_comb begin
	  unique case (opcode_x)
	  	OPC_LUI,
		OPC_AUIPC: imm_x = imm_u_x;
		
		OPC_JAL: imm_x = imm_j_x;

                OPC_JALR,
		OPC_LOAD,
		OPC_ARI_ITYPE: imm_x = imm_i_x;

		OPC_STORE: imm_x = imm_s_x;
		OPC_BRACH: imm_x = imm_b_x;
		OPC_CSR: imm_x = imm_z_x;

		default: imm_x = 32'b0;
	  endcase
  end

  // X stage Control
  
  
  logic regwen_x; // register write enable
  logic memread_x; //data memory read
  logic memwrite_x // data memory write
  logic branch_x; //becomes 1 for branching
  logic jal_x; // if 1 --> PC will jump to PC + imm_j
  logic jalr_x; // if 1 --> pc will jump to (res1 + imm_i) & ~1
  logic csr_write_x; // writes to CSR if 1
  logic csr_imm_x; // value to write to csr comes from imm, not rs1
  // Muxes for  A & B are split up
  logic asel_x; // rs1_data_x vs pc_x
  logic bsel_x; // rs2_data_x vs imm_x
  logic brun_x; // 0 --> signed compare (blt, bge) vs 1 --> unsigned compare (bltu, bgeu)
  // Decided in X but used in MEM (Part 3) --> in X Stage one already knows,
  // what that is --> 0=men, 1 = alu/ 2 = pc+4
  logic [1:0] wbsel_x;
  
  always_comb begin
	  regwen_x = 1'b0;
	  memread_x = 1'b0;
	  memwrite_x = 1'b0;
	  branch_x = 1'b0;
	  jal_x  = 1'b0;
	  jalr_x = 1'b0;
	  csr_write_x = 1'b0;
	  csr_imm_x = 1'b0;
	  asel_x = 1'b0;
	  bsel_x = 1'b0;
	  brun_x = 1'b0;
	  wbsel_x = 1'b0;

	  unique case (opcode_x)
	  	OPC_LUI: begin
			regwen_x = 1'b1;
			asel_x = 1'b0;
			bsel_x = 1'b1;
			wbsel_x = 2'd1;
		end

	  	OPC_AUIPC: begin
			regwen_x = 1'b1;
			asel_x = 1'b0;
			bsel_x = 1'b1;
			wbsel_x = 2'd2;
		end

	  	OPC_JAL: begin
			regwen_x = 1'b1;
			jal_x = 1'b1;
			wbsel_x = 2'd2;
		end

	  	OPC_JALR: begin
			regwen_x = 1'b1;
			jalr_x = 1'b1;
			wbsel_x = 2'd2;
		end

	  	OPC_BRANCH: begin
			branch_x = 1'b1;
			brun_x = funxt3_x[1] // BLT/BGE signed= 0, B*TU/BGEU unsigned = 1
		end

	  	OPC_LOAD: begin
			regwen_x = 1'b1;
			memread = 1'b1;
			bsel_x = 1'b1;
			wbsel_x = 2'd0;
		end
	 
	  	OPC_STORE: begin
			memwrite_x = 1'b1;
			bsel_x = 1'b1;
		end
  
	  	OPC_ARI_ITYPE: begin
			regwen_x = 1'b1;
			bsel_x = 1'b1;
			wbsel_x = 2'd1;
		end 
  
	  	OPC_ARI_RTYPE: begin
			regwen_x = 1'b1;
			wbsel_x = 2'd1;
		end

		OPC_CSR: begin
			csr_write_x = 1'b1;
			regwen_x = (rd_x != 5'do); //set regwrite enable only to 1 if rd is not x0
			csr_imm_x = funct3_x[2]; // 001 = csrrw, 101=csrrwi
			wbsel_x = 2'd1;
			bsel_x = 1'b1;
		end

		default: begin
		end
	endcase
  end

  // ALU decoder
  
  alu_op_t aluop_x; // is a var from type alu_op_t out of alu_op_pkg
  
  ALUdec u_aludec(
	  .opcode (opcode_x),
	  .funct (funct3_x),
	  .add_rshift_type (add_rshift_type_x),
	  .ALUop (aluop_x)
  );

  // Register reads + simple WB forwarding
  
  // direct from File Registers 
  logic [31:0] rs1_data_raw_x;
  logic [31:0] rs2_data_raw_x;

  //Maybe from forwarding
  logic [31:0] rs1_data_x;
  logic [31:0] rs1_data_x;
  
  logic [31:0] wb_data_m;
  logic regwen_m; // write enable
  logic [4:0] rd_m;

  assign rs1_data_raw_x = (rs1_x == 5'd0) ? 32'b0 : regfile[rs1_x]; //x[0] from regfile needs always to be 0
  assign rs2_data_raw_x = (rs1_x == 5'd0) ? 32'b0 : regfile[rs1_x];
  
  always_comb begin
	  rs1_data_x = rs1_data_raw_x;
	  rs2_data_x = rs2_data_raw_x;

	  // regwen_m --> the older instruction in stage M actually write back
	  // to the register file
	  // && ignore writes to x0
	  // destination register of the older instruction is exactly the
	  // source register rs1/rs2 of the current instruction
	  // --> if all yes, instead of stle register file value, the CPU uses
		  // the new result directly from the later stage
	  if (regwen_m && (rd_m != 5'd0) && (rd_m == rs1_x))
		  rs_1_data_x = wb_data_m 
	  if (regwen_m && (rd_m != 5'd0) && (rd_m == rs2_x))
		  rs_2_data_x = wb_data_m
  end

  // Branch Comperator
  
  logic br_eq_x; // equal
  logic br_lt_x; // rs1 < rs2?
  logic branch_taken_x;

  assign br_eg_x = (rs1_data_x == rs2_data_x);
  // brun_x decided if branch comparisen should be (un)signed
  assign br_lt_x = brun_x ? (rs1_data_x < rs2_data_x)
  			  : ($signed(rs1_data_x) < $signedrs2_data_x));
  
  always_comb begin
	  branch_taken_x = 1'b0;
// Branch Equel, ~Equal, Less Than, Greater or Equal
	  unique case (funct3_x)
	  	FNC_BEQ: branch_taken_x = br_eq_x;
	  	FNC_BNE: branch_taken_x = ~br_eq_x;
	  	FNC_BLT: branch_taken_x = br_lt_x;
	  	FNC_BGE: branch_taken_x = ~br_lt_x;
	  	FNC_BLTU: branch_taken_x = br_lt_x;
	  	FNC_BGEU: branch_taken_x = ~br_lt_x;
		default: branch_taken_x = 1'b0;
	  endcase
  end

  // ALU inputs and execute
  
  logic [31:0] alu_a_x;
  logic [31:0] alu_b_x;
  logic [31:0] alu_out_x;

  // CSR uses ALU_COPY_B, so B must be rs1 or zimm (csrqi tohost, 1)
  logic [31:0] alu_b_pre_x;
  assign alu_b_pre_x = csr_imm_x ? imm_z_x : rs2_data_x;

  assign alu_a_x = asel_x ? pc_x : rs1_data_x; // 1 takes pc_x, 0 takes rs_data_x, forwarding logic is already implemented in rs1_data_x, see if clauses further above
  assign alu_b_x = bsel_x ? imm_x : alu_b_pre_x; // 1 takes imm_x, 0 takes alu_b_pre_x

  ALU u_alu (
	  .A (alu_a_x),
	  .B (alu_b_x),
	  .ALUop (aluop_x),
	  .Out (alu_out_x),
  );

  // Next PC logic
  
  logic pcsel_x;
  logic [31:0] branch_target_x;
  logic [31:0] jalr_target_x;

  assign branch_target_x = pc_x + imm_b_x; //PC + branch immediate
  assign jalr_target_x = (rs1_data_x + imm_i_x) & 32'hFFFF_FFFE; //target = rs1 + imm

  assign pcsel_x = jal_x |jalr_x|(branch_x & branch_taken_x); // if one of those is true --> pcsel_x = 1 --> normal pc+4 wird verlassen

  // jalr, jal, branch if taken, PC+4
  always_comb begin
	  if (jalr_x)
		  nex_pc_f = jalr_target_x
	  else if (jal_x)
		  next_pc_f = pc_x + imm_j_x;
	  else if (branch_x && branch_taken_x)
		  next_pc_f = branch_target_x;
	  else
		  next_pc_f = pc_plus4_f;
  end

  // X --> M pipeline registers
  
  logic [31:0] pc_m;
  logic [31:0] inst_m;
  logic [31:0] alu_out_m;
  logic [31:0] rs2_data_m;
  logic [2:0] funct3_m;
  logic [1:0] wbsel_m;
  logic memread_m;
  logic memwrite_m;
  logic csr_write_m;




















  always_ff @(posedge clk or posedge reset) begin
	  if (reset) begin
		  pc_x <= 32'b0;
		  inst_x <= 32'b0;
	  end else if (!stall) begin
		  pc_x <= pc_f
		  inst_x <= inst_f
	  end
  end
  
  logic [6:0] opcode_x;
  logic [4:0] rd_addr_x;
  logic [2:0] funct3_x;
  logic [4:0] rs1_addr_x;
  logic [4:0] rs2_addr_x;
  logic [6:0] funct7_x;

  












  
  
  assign icache_addr = pc_f;
  assign icache_re = 1'b1;
  assign inst_f = icache_dout;

  always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
    		pc_f <= 32'b0;
	end else if (!stall) bein
		pc_f <= next_pc_f;
	end
  end
    
  
  //Registers for Pipelining between state 1 and 2


endmodule


`default_nettype wire
