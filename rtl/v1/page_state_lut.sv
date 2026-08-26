// page_state_lut.sv
// Atomic lifecycle state transitions and the safe-reuse predicate.
//
// One command per cycle, one-cycle registered response. Every transition is
// atomic: the entry is read, checked, and written in the same cycle, so no
// intermediate state is ever visible to a concurrent reuse attempt.
//
// SAFETY INVARIANT, enforced not merely asserted:
//   a REUSE is refused unless refcount==0 && reservation==0
//                          && inflight==0 && !fill_pending
// The generation is advanced ONLY on a granted reuse, and only AFTER the old
// mapping is unpublished, so there is no cycle in which a replacement is
// visible carrying the previous generation.

`include "lifecycle_pkg.sv"

module page_state_lut
  import lifecycle_pkg::*;
#(
  parameter bit UNSAFE_BYPASS_SUPPORTED  = 1,
  parameter bit NAIVE_NO_GEN_SUPPORTED   = 1
)(
  input  wire                 clk,
  input  wire                 rst_n,

  // Deliberately unsafe modes, for the side-by-side ILA demonstration. These
  // are TWO INDEPENDENT protections and each has its own bypass:
  //
  //   i_unsafe_bypass       removes the EVICTABLE INTERLOCK. A reuse commits
  //                         while inflight > 0. On its own this does NOT
  //                         corrupt a payload: the generation comparison below
  //                         still rejects the stale completion.
  //   i_no_generation_check removes GENERATION TAGGING. desc_valid degrades to
  //                         slot + frame identity, modelling a naive design
  //                         that carries no generation at all.
  //
  // Both asserted together is the only combination that actually corrupts the
  // new owner's data.
  input  wire                 i_unsafe_bypass,
  input  wire                 i_no_generation_check,

  input  lc_cmd_t             i_cmd,
  input  wire [SLOT_W-1:0]    i_slot,

  // reuse request path
  input  wire                 i_reuse_req,
  input  wire [SLOT_W-1:0]    i_reuse_slot,
  input  wire [PHYS_W-1:0]    i_reuse_phys,
  input  wire [TENANT_W-1:0]  i_reuse_tenant,

  output lc_rsp_t             o_rsp,
  output reg                  o_reuse_grant,
  output reg                  o_reuse_refused,
  output reg  [GEN_W-1:0]     o_reuse_new_gen,

  // observability
  output reg                  o_unsafe_reuse_blocked,
  output reg                  o_unsafe_reuse_committed,
  output reg                  o_stale_descriptor,
  output reg  [31:0]          o_cnt_refused,
  output reg  [31:0]          o_cnt_stale,
  output reg  [31:0]          o_cnt_unsafe_commit
);

  lc_entry_t ram [SLOTS];

  lc_entry_t  e_cmd, e_reuse, e_next;
  logic       hit_cmd, evict_ok;
  logic       naive_mode, desc_ok;
  err_e       err_n;
  logic       ok_n;

  integer i;

  // GENERATION TAGGING, the second and independent line of defence. When
  // i_no_generation_check is asserted the design degrades to a naive lookup
  // with no generation comparison at all.
  assign naive_mode = NAIVE_NO_GEN_SUPPORTED && i_no_generation_check;

  always_comb begin
    e_cmd    = ram[i_slot];
    e_reuse  = ram[i_reuse_slot];
    e_next   = e_cmd;
    err_n    = ERR_NONE;
    ok_n     = 1'b0;
    hit_cmd  = e_cmd.valid;

    desc_ok  = naive_mode ? desc_valid_no_gen(e_cmd, i_cmd.desc)
                          : desc_valid       (e_cmd, i_cmd.desc);

    if (i_cmd.valid) begin
      // descriptor validation happens BEFORE any state change
      if (i_cmd.use_desc && !desc_ok) begin
        err_n = ERR_STALE_DESC;
      end else if (i_cmd.use_desc && (e_cmd.tenant != i_cmd.desc.tenant)) begin
        err_n = ERR_CROSS_TENANT;
      end else begin
        ok_n = 1'b1;
        unique case (i_cmd.ev)
          LC_ACQUIRE : begin
            if (&e_cmd.refcount) begin err_n = ERR_OVERFLOW; ok_n = 1'b0; end
            else e_next.refcount = e_cmd.refcount + 1'b1;
          end
          LC_RELEASE : begin
            if (e_cmd.refcount == '0) begin err_n = ERR_UNDERFLOW; ok_n = 1'b0; end
            else e_next.refcount = e_cmd.refcount - 1'b1;
          end
          LC_ADMIT   : begin
            if (&e_cmd.reservation) begin err_n = ERR_OVERFLOW; ok_n = 1'b0; end
            else e_next.reservation = e_cmd.reservation + 1'b1;
          end
          LC_CANCEL  : begin
            if (e_cmd.reservation == '0) begin err_n = ERR_UNDERFLOW; ok_n = 1'b0; end
            else e_next.reservation = e_cmd.reservation - 1'b1;
          end
          LC_ISSUE   : begin
            if (e_cmd.reservation == '0) begin err_n = ERR_UNDERFLOW; ok_n = 1'b0; end
            else if (&e_cmd.inflight)   begin err_n = ERR_OVERFLOW;  ok_n = 1'b0; end
            else begin
              e_next.reservation = e_cmd.reservation - 1'b1;
              e_next.inflight    = e_cmd.inflight    + 1'b1;
            end
          end
          LC_COMPLETE: begin
            if (e_cmd.inflight == '0) begin err_n = ERR_UNDERFLOW; ok_n = 1'b0; end
            else e_next.inflight = e_cmd.inflight - 1'b1;
          end
          LC_FILL_ST : begin
            if (&e_cmd.fill_pending) begin err_n = ERR_OVERFLOW; ok_n = 1'b0; end
            else e_next.fill_pending = e_cmd.fill_pending + 1'b1;
          end
          LC_FILL_DN : begin
            if (e_cmd.fill_pending == '0) begin err_n = ERR_UNDERFLOW; ok_n = 1'b0; end
            else e_next.fill_pending = e_cmd.fill_pending - 1'b1;
          end
          default: begin err_n = ERR_SLOT_INVALID; ok_n = 1'b0; end
        endcase
      end
    end
  end

  // THE INTERLOCK. Safe mode refuses; unsafe bypass commits and is counted.
  assign evict_ok = is_evictable(e_reuse);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < SLOTS; i = i + 1) ram[i] <= '0;
      o_rsp                    <= '0;
      o_reuse_grant            <= 1'b0;
      o_reuse_refused          <= 1'b0;
      o_reuse_new_gen          <= '0;
      o_unsafe_reuse_blocked   <= 1'b0;
      o_unsafe_reuse_committed <= 1'b0;
      o_stale_descriptor       <= 1'b0;
      o_cnt_refused            <= '0;
      o_cnt_stale              <= '0;
      o_cnt_unsafe_commit      <= '0;
    end else begin
      o_reuse_grant            <= 1'b0;
      o_reuse_refused          <= 1'b0;
      o_unsafe_reuse_blocked   <= 1'b0;
      o_unsafe_reuse_committed <= 1'b0;
      o_stale_descriptor       <= 1'b0;

      if (i_cmd.valid) begin
        if (ok_n) ram[i_slot] <= e_next;
        o_rsp.valid     <= 1'b1;
        o_rsp.ok        <= ok_n;
        o_rsp.err       <= err_n;
        o_rsp.entry     <= ok_n ? e_next : e_cmd;
        o_rsp.evictable <= is_evictable(ok_n ? e_next : e_cmd);
        if (err_n == ERR_STALE_DESC) begin
          o_stale_descriptor <= 1'b1;
          o_cnt_stale        <= o_cnt_stale + 1'b1;
        end
      end else begin
        o_rsp.valid <= 1'b0;
      end

      if (i_reuse_req) begin
        if (evict_ok) begin
          // SAFE reuse: unpublish, advance generation, install replacement.
          // All in one cycle, so no replacement is ever visible at the old
          // generation.
          ram[i_reuse_slot].valid        <= 1'b1;
          ram[i_reuse_slot].phys_idx     <= i_reuse_phys;
          ram[i_reuse_slot].generation   <= e_reuse.generation + 1'b1;
          ram[i_reuse_slot].refcount     <= '0;
          ram[i_reuse_slot].reservation  <= '0;
          ram[i_reuse_slot].inflight     <= '0;
          ram[i_reuse_slot].fill_pending <= '0;
          ram[i_reuse_slot].tenant       <= i_reuse_tenant;
          o_reuse_grant   <= 1'b1;
          o_reuse_new_gen <= e_reuse.generation + 1'b1;
        end else if (UNSAFE_BYPASS_SUPPORTED && i_unsafe_bypass) begin
          // DELIBERATELY UNSAFE. Present only so the ILA can capture the
          // corruption the interlock prevents. Never enabled in a safe run.
          ram[i_reuse_slot].valid        <= 1'b1;
          ram[i_reuse_slot].phys_idx     <= i_reuse_phys;
          ram[i_reuse_slot].generation   <= e_reuse.generation + 1'b1;
          ram[i_reuse_slot].refcount     <= '0;
          ram[i_reuse_slot].reservation  <= '0;
          ram[i_reuse_slot].tenant       <= i_reuse_tenant;
          // inflight is NOT cleared: the old transfer is still outstanding
          o_reuse_grant            <= 1'b1;
          o_reuse_new_gen          <= e_reuse.generation + 1'b1;
          o_unsafe_reuse_committed <= 1'b1;
          o_cnt_unsafe_commit      <= o_cnt_unsafe_commit + 1'b1;
        end else begin
          o_reuse_refused        <= 1'b1;
          o_unsafe_reuse_blocked <= 1'b1;
          o_cnt_refused          <= o_cnt_refused + 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  // The invariant, checked every cycle in simulation.
  property p_no_unsafe_reuse;
    @(posedge clk) disable iff (!rst_n || i_unsafe_bypass)
      (i_reuse_req && !is_evictable(ram[i_reuse_slot])) |=> o_reuse_refused;
  endproperty
  a_no_unsafe_reuse: assert property (p_no_unsafe_reuse)
    else $error("SAFETY: reuse granted while not evictable");
`endif

endmodule
