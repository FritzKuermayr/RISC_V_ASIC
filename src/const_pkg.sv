`default_nettype none

/* Global design constants. */

package const_pkg;

  // -----------------------------
  // Memory interface parameters
  // -----------------------------
  localparam int MEM_DATA_BITS   = 128;
  localparam int MEM_TAG_BITS    = 5;
  localparam int MEM_ADDR_BITS   = 28;
  localparam int MEM_DATA_CYCLES = 4;

  // -----------------------------
  // CPU parameters
  // -----------------------------
  localparam int CPU_ADDR_BITS  = 32;
  localparam int CPU_INST_BITS  = 32;
  localparam int CPU_DATA_BITS  = 32;
  localparam int CPU_OP_BITS    = 4;
  localparam int CPU_WMASK_BITS = 16;
  localparam int CPU_TAG_BITS   = 15;

  // -----------------------------
  // PC address on reset
  // -----------------------------
  localparam logic [31:0] PC_RESET = 32'h0000_2000;

  // -----------------------------
  // NOP instruction
  // Depends on opcode_pkg definitions
  // -----------------------------
  localparam logic [31:0] INSTR_NOP =
      {12'd0, 5'd0, opcode_pkg::FNC_ADD_SUB, 5'd0, opcode_pkg::OPC_ARI_ITYPE};

  // -----------------------------
  // CSR addresses
  // -----------------------------
  localparam logic [11:0] CSR_TOHOST = 12'h51E;
  localparam logic [11:0] CSR_HARTID = 12'h50B;
  localparam logic [11:0] CSR_STATUS = 12'h50A;

endpackage : const_pkg

`default_nettype wire
