`default_nettype none

import const_pkg::*;
import opcode_pkg::*;
import alu_op_pkg::*;

module Riscv_assertions;

	// Upon reset, the program counter should become PC_Reset
	
	property p_reset_pc;
		@(posedge clk)
			reset |=> (pc_f == PC_RESET);
	endproperty

	assert property (p_reset_pc)
		else $error("Assertion failed: After reset, pc_f is not PC_RESET.");

	
	// For store instructions, the write enable mask should have the
// appropriate number of ones dependin on whereter the instruction si sb, sh
// or sw (1,2,4 set bits aka 0001, 1100, 1111)
	property p_sb_mask;
		@(posedge clk) disable iff (reset)
			(memwrite_m && (funct3_m == FNC_SB)) |-> $onehot(dcache_we);
		endproperty

		assert property (p_sb_mask)
			else $error("Assertion Failed: SB does not generate a one hot byte write mask.");
	
	property p_sh_mask;
		@(posedge clk) disable iff (reset)
			(memwrite_m && (funct3_m == FNC_SH)) |-> (dcache_we == 4'b0011 || dcache_we == 4'b1100);		
		endproperty

		assert property (p_sh_mask)
			else $error("Assertion Failed: SH does not generate a 2 byte  write mask.");

	property p_sw_mask;
		@(posedge clk) disable iff (reset)
			(memwrite_m && (funct3_m == FNC_SW)) |-> (dcache_we == 4'b1111);
		endproperty

		assert property (p_sw_mask)
			else $error("Assertion Failed: SW does not generate a write mask 4'b1111.");

	// For lb instructions, the upper 24 bits of data written to the
// regfle should be all 0s or 1s. FOr lh instructions, the upper 16 bits of
// data written to the regfile should be all 0s or 1s.
	property p_lb_signext;
		@(posedge clk) disable iff(reset)
			(regwen_m && memread_m && (funct3_m == FNC_LB))
			|->
			((wb_data_m[31:8] == 24'h000000) || (wb_data_m[31:8] == 24'hFFFFFF));
	endproperty

	assert property (p_lb_signext)
		else $error("Assertion failed: LB Writeback is not properly sign-extended.");
	
	property p_lh_signext;
		@(posedge clk) disable iff (reset)
		(regwen_m && memread_m && (funct3_m == FNC_LH))
		|->
			((wb_data_m[31:16] == 16'h0000) || (wb_data_m[31:16] == 16'hFFFF));
	endproperty

	assert property (p_lh_signext)
		else $error("Assertion failed: LH Writeback is not properly sign-extended.");

	// The x0 register should always be 0
	
	property p_x0_zero;
		@(posedge clk) regfile[0] == 32'b0;
	endproperty

	assert property (p_x0_zero)
		else $error("Assertion Failed: x0 is not zero.");
endmodule

bind Riscv151 Riscv_assertions u_riscv_assertions();








`default_nettype wire
