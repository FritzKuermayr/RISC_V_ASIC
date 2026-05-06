`default_nettype none

import const_pkg::*;
import alu_op_pkg::*;
import opcode_pkg::*;

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

  logic [31:0] regfile[0:31];
  integer i;

  // Fetch Stage
  
  logic [31:0] pc_f;
  logic [31:0] next_pc_f;
  logic [31:0] pc_plus4_f;

  assign pc_plus4_f = pc_f + 32'd4;
  
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
  
  logic [31:0] imm_x;


  // assignement off those different Imms to the Instruction:
  // 20{inst_x} --> sign extension, repeats either 0 or 1 before
  assign imm_i_x = {{20{inst_x[31]}}, inst_x[31:20]};
  assign imm_s_x = {{20{inst_x[31]}}, inst_x[31:25], inst_x[11:7]};
  // for branch --> last bit needs 50 be 0 aka imm[12|10:5|4:1|11] << 1
  assign imm_b_x = {{19{inst_x[31]}}, inst_x[31], inst_x[7], inst_x[30:25], inst_x[11:8], 1'b0};
  assign imm_u_x = {inst_x[31:12], 12'b0};
  assign imm_j_x = {{11{inst_x[31]}},inst_x[31], inst_x[19:12], inst_x[20], inst_x[30:21], 1'b0};
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
		OPC_BRANCH: imm_x = imm_b_x;
		OPC_CSR: imm_x = imm_z_x;

		default: imm_x = 32'b0;
	  endcase
  end

  // X stage Control
  
  
  logic regwen_x; // register write enable
  logic memread_x; //data memory read
  logic memwrite_x; // data memory write
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
	  wbsel_x = 2'd1;

	  unique case (opcode_x)
	  	OPC_LUI: begin
			regwen_x = 1'b1;
			asel_x = 1'b0;
			bsel_x = 1'b1;
			wbsel_x = 2'd1;
		end

	  	OPC_AUIPC: begin
			regwen_x = 1'b1;
			asel_x = 1'b1;
			bsel_x = 1'b1;
			wbsel_x = 2'd1;
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
			brun_x = funct3_x[1]; // BLT/BGE signed= 0, B*TU/BGEU unsigned = 1
		end

	  	OPC_LOAD: begin
			regwen_x = 1'b1;
			memread_x = 1'b1;
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
			if ((funct3_x == FNC_RW) || (funct3_x == FNC_RWI)) begin	
				csr_write_x = 1'b1;
				regwen_x = (rd_x != 5'd0); //set regwrite enable only to 1 if rd is not x0
				csr_imm_x = funct3_x[2]; // 001 = csrrw, 101=csrrwi
				wbsel_x = 2'd1;
			end
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
  logic [31:0] rs2_data_x;
  
  logic [31:0] wb_data_m;
  logic regwen_m; // write enable
  logic [4:0] rd_m;

  assign rs1_data_raw_x = (rs1_x == 5'd0) ? 32'b0 : regfile[rs1_x]; //x[0] from regfile needs always to be 0
  assign rs2_data_raw_x = (rs2_x == 5'd0) ? 32'b0 : regfile[rs2_x];
  
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
		  rs1_data_x = wb_data_m; 
	  if (regwen_m && (rd_m != 5'd0) && (rd_m == rs2_x))
		  rs2_data_x = wb_data_m;
  end

  // Branch Comperator
  
  logic br_eq_x; // equal
  logic br_lt_x; // rs1 < rs2?
  logic branch_taken_x;

  assign br_eq_x = (rs1_data_x == rs2_data_x);
  // brun_x decided if branch comparisen should be (un)signed
  assign br_lt_x = brun_x ? (rs1_data_x < rs2_data_x)
  			  : ($signed(rs1_data_x) < $signed(rs2_data_x));
  
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

  assign alu_a_x = asel_x ? pc_x : rs1_data_x; // 1 takes pc_x, 0 takes rs_data_x, forwarding logic is already implemented in rs1_data_x, see if clauses further above
  assign alu_b_x = bsel_x ? imm_x : rs2_data_x; // 1 takes imm_x, 0 takes rs2

  ALU u_alu (
	  .A (alu_a_x),
	  .B (alu_b_x),
	  .ALUop (aluop_x),
	  .Out (alu_out_x)
  );

  logic [31:0] csr_wdata_x;
  logic [11:0] csr_addr_x;

  assign csr_wdata_x = csr_imm_x ? imm_z_x : rs1_data_x;
  assign csr_addr_x = inst_x[31:20];

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
		  next_pc_f = jalr_target_x;
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
  logic [31:0] csr_wdata_m;
  logic [11:0] csr_addr_m;

  // Memory Stage
  
  logic [31:0] load_data_m;

  assign dcache_addr = alu_out_m;
  assign dcache_re = memread_m;
  assign icache_re = 1'b1;
  assign icache_addr = pc_f;

  always_comb begin
	  dcache_we = 4'b0000; // decides where to put data in 32 bit --> 1 mean replace word w/ data from rs2_data_m
	  dcache_din = 32'b0;
	  if (memwrite_m) begin
		  unique case (funct3_m)
			FNC_SB: begin // SB = Store Byte
				unique case (alu_out_m[1:0])
					2'd0: begin 
						dcache_we = 4'b0001;
						dcache_din = {24'b0, rs2_data_m[7:0]};
					end
				
					2'd1: begin 
						dcache_we = 4'b0010;
						dcache_din = {16'b0, rs2_data_m[7:0], 8'b0};
					end

					2'd2: begin 
						dcache_we = 4'b0100;
						dcache_din = {8'b0, rs2_data_m[7:0], 16'b0};
					end

					2'd3: begin 
						dcache_we = 4'b1000;
						dcache_din = {rs2_data_m[7:0], 24'b0};
					end
					default : begin dcache_we = 4'b0000; dcache_din = 32'b0; end
				endcase
			end

			FNC_SH: begin // store Half Word = SH
				unique case (alu_out_m[1])
					1'b0: begin 
						dcache_we = 4'b0011; 
						dcache_din = {16'b0, rs2_data_m[15:0]};
					end	
					
					1'b1: begin 
						dcache_we = 4'b1100; 
						dcache_din = {rs2_data_m[15:0], 16'b0};
					end
					default: begin dcache_we = 4'b0000; dcache_din = 32'b0; end
				endcase
			end
			
			FNC_SW: begin
				dcache_we = memwrite_m ? 4'b1111 : 4'b0000;
				dcache_din = rs2_data_m;
			end
			
			default: begin
				dcache_we = 4'b0000;
				dcache_din = 32'b0;
			end
		endcase
	  end
  end

  always_comb begin
	load_data_m = dcache_dout;

	unique case (funct3_m)
		FNC_LB: begin // Byte ausgewält und sign extended auf 32 bit
			unique case (alu_out_m[1:0])
				2'd0: load_data_m = {{24{dcache_dout[7]}}, dcache_dout[7:0]};
				2'd1: load_data_m = {{24{dcache_dout[15]}}, dcache_dout[15:8]};
				2'd2: load_data_m = {{24{dcache_dout[23]}}, dcache_dout[23:16]};
				2'd3: load_data_m = {{24{dcache_dout[31]}}, dcache_dout[31:24]};
				default: load_data_m = 32'b0;
			endcase
		end

		FNC_LBU: begin // Byte ausgewählt und zero extended
			unique case (alu_out_m[1:0])
				2'd0: load_data_m = {24'b0, dcache_dout[7:0]};
				2'd1: load_data_m = {24'b0, dcache_dout[15:8]};
				2'd2: load_data_m = {24'b0, dcache_dout[23:16]};
				2'd3: load_data_m = {24'b0, dcache_dout[31:24]};
				default: load_data_m = 32'b0;
			endcase
		end

		FNC_LH: begin // sign extension
			if (alu_out_m[1] == 1'b0)
				load_data_m = {{16{dcache_dout[15]}}, dcache_dout[15:0]};
			else
				load_data_m = {{16{dcache_dout[31]}}, dcache_dout[31:16]};
		end

		FNC_LHU: begin // zero extension
			if (alu_out_m[1] == 1'b0)
				load_data_m = {16'b0, dcache_dout[15:0]};
			else
				load_data_m = {16'b0, dcache_dout[31:16]};
		end

		FNC_LW: begin // full 32 Bit Word
			load_data_m = dcache_dout;
		end

		default: begin
			load_data_m = dcache_dout;
		end
	endcase
  end

  // CSR handling
  
  logic [31:0] csr_reg; // Implemented CSR Reg for Test Harness
  assign csr = csr_reg; // Module has output csr and checks it

  // WB mux
  
  always_comb begin
	  unique case (wbsel_m)
	  	2'd0: wb_data_m = load_data_m;
	  	2'd1: wb_data_m = alu_out_m;
	  	2'd2: wb_data_m = pc_m + 32'd4;
		default: wb_data_m = 32'b0;
	  endcase
  end

  // Sequential Logic

  always_ff @(posedge clk) begin
	  if (reset) begin
		 pc_f <= PC_RESET; // defined in const_pkg.sv
		 pc_x <= 32'b0;
		 inst_x <= INSTR_NOP;

		 pc_m <= 32'b0;
		 inst_m <= INSTR_NOP;
		 alu_out_m <= 32'b0;
		 rs2_data_m <= 32'b0;
		 funct3_m <= 3'b0;
		 wbsel_m <= 2'b0;
		 regwen_m <= 1'b0;
		 rd_m <= 5'b0;
		 memread_m <= 1'b0;
		 memwrite_m <= 1'b0;
		 csr_write_m <= 1'b0;
		 csr_wdata_m <= 32'b0;
		 csr_addr_m <= 12'b0;

		 csr_reg <= 32'b0;

		 for (i=0; i <32; i = i+1)
			 regfile[i] <= 32'b0;
	 end
	 else if (!stall) begin
		 // WB write to regfile
		 if (regwen_m && (rd_m != 5'd0))
			 regfile[rd_m] <= wb_data_m;

		 regfile[0] <= 32'b0;

		 if (csr_write_m && (csr_addr_m == CSR_TOHOST))
			 csr_reg <= csr_wdata_m;

		 // Update fetch PC
		 pc_f <= next_pc_f;

		 // F --> X pipeline register & FLush fetched wrong path
		 // instruction on taen control transfer

		 if (pcsel_x) begin // PC Sel Mux = 1 --> ALU Path taken
			 pc_x <= 32'b0;
			 inst_x <= INSTR_NOP;
		 end
		 else begin // PC Sel Mux = 0 --> Normal Path
			 pc_x <= pc_f;
			 inst_x <= icache_dout;
		 end
		 
		 // X --> M Pipeline Registers

		 pc_m <= pc_x;
		 inst_m <= inst_x;
		 alu_out_m <= alu_out_x;
		 rs2_data_m <= rs2_data_x;
		 funct3_m <= funct3_x;
		 wbsel_m <= wbsel_x;
		 regwen_m <= regwen_x;
		 rd_m <= rd_x;
		 memread_m <= memread_x;
		 memwrite_m <= memwrite_x;
		 csr_write_m <= csr_write_x;
		 csr_wdata_m <= csr_wdata_x;
		 csr_addr_m <= csr_addr_x;
	 end
  end

endmodule


`default_nettype wire
