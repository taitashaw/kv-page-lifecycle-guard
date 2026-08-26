// tag_tracker.sv
// Maps an AXI transaction tag to {lifecycle_slot, expected_generation, phys_idx}.
//
// This is what lets a completion be routed back to the RIGHT lifecycle entry
// and lets a STALE completion be rejected rather than decrementing a counter on
// whatever object now occupies the frame.
//
// Per-tag properties enforced here, not asserted elsewhere:
//   AXI_ACCEPT(tag)   at most once while outstanding
//   AXI_COMPLETE(tag) requires a prior AXI_ACCEPT(tag)
//   CANCEL(tag)       rejected after acceptance

`include "lifecycle_pkg.sv"

module tag_tracker
  import lifecycle_pkg::*;
#(
  parameter int unsigned MAX_OUTSTANDING = 2
)(
  input  wire               clk,
  input  wire               rst_n,

  input  wire               i_accept,      // AR/AW handshake
  input  descriptor_t       i_accept_desc,

  input  wire               i_complete,    // RLAST or B handshake
  input  wire [TAG_W-1:0]   i_complete_tag,

  input  wire               i_cancel,      // pre-issue only
  input  wire [TAG_W-1:0]   i_cancel_tag,

  output reg                o_lookup_valid,
  output descriptor_t       o_lookup_desc,
  output reg                o_err_valid,
  output err_e              o_err,
  output reg [$clog2(MAX_OUTSTANDING+1)-1:0] o_outstanding,
  output reg                o_accept_ready
);

  descriptor_t tag_desc [TAGS];
  logic        tag_busy [TAGS];

  integer i;

  assign o_accept_ready = (o_outstanding < MAX_OUTSTANDING[$bits(o_outstanding)-1:0]);

  // set by blocking assignment inside the always_ff below and read in the

  // same evaluation; never a state element.

  logic acc_ok, cmp_ok;


  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < TAGS; i = i + 1) begin
        tag_desc[i] <= '0;
        tag_busy[i] <= 1'b0;
      end
      o_lookup_valid <= 1'b0;
      o_lookup_desc  <= '0;
      o_err_valid    <= 1'b0;
      o_err          <= ERR_NONE;
      o_outstanding  <= '0;
    end else begin
      o_lookup_valid <= 1'b0;
      o_err_valid    <= 1'b0;
      o_err          <= ERR_NONE;

      // An AR handshake and the RLAST of a DIFFERENT transaction can land in
      // the same cycle. This used to be two independent if-blocks each
      // assigning o_outstanding from its pre-update value in one always_ff,
      // so the later (complete) branch won and a coincident pair DECREMENTED
      // instead of holding. The counter then under-read, wrapped past 0 in
      // OUTST_W bits, and wedged o_accept_ready low permanently. The delta is
      // now accumulated and applied exactly once.
      acc_ok = 1'b0;
      cmp_ok = 1'b0;

      if (i_accept) begin
        if (tag_busy[i_accept_desc.transaction_tag]) begin
          o_err_valid <= 1'b1;
          o_err       <= ERR_TAG_REUSE;
        end else if (!o_accept_ready) begin
          o_err_valid <= 1'b1;
          o_err       <= ERR_OVERFLOW;      // outstanding limit
        end else begin
          tag_desc[i_accept_desc.transaction_tag] <= i_accept_desc;
          tag_busy[i_accept_desc.transaction_tag] <= 1'b1;
          acc_ok = 1'b1;
        end
      end

      if (i_complete) begin
        if (!tag_busy[i_complete_tag]) begin
          o_err_valid <= 1'b1;
          o_err       <= ERR_TAG_UNKNOWN;   // completion without acceptance
        end else begin
          o_lookup_valid <= 1'b1;
          o_lookup_desc  <= tag_desc[i_complete_tag];
          tag_busy[i_complete_tag] <= 1'b0;
          cmp_ok = 1'b1;
        end
      end

      // Both or neither: hold. Only a lone accept or a lone complete moves it.
      if      (acc_ok && !cmp_ok) o_outstanding <= o_outstanding + 1'b1;
      else if (cmp_ok && !acc_ok) o_outstanding <= o_outstanding - 1'b1;

      if (i_cancel) begin
        if (tag_busy[i_cancel_tag]) begin
          o_err_valid <= 1'b1;
          o_err       <= ERR_CANCEL_AFTER_ACC;
        end
      end
    end
  end

`ifndef SYNTHESIS
  a_outstanding_bound: assert property (@(posedge clk) disable iff (!rst_n)
    o_outstanding <= MAX_OUTSTANDING)
    else $error("outstanding exceeded %0d", MAX_OUTSTANDING);

  // a_outstanding_bound watches the COUNTER, so it cannot see the counter
  // itself going wrong. This one watches the live tags directly.
  a_tag_busy_bound: assert property (@(posedge clk) disable iff (!rst_n)
    $countones(tag_busy) <= MAX_OUTSTANDING)
    else $error("live tags %0d exceeded %0d", $countones(tag_busy), MAX_OUTSTANDING);
`endif

endmodule
