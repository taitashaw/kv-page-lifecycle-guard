// LENS 2 buildability probe: 4-tenant credit / deficit accountant with the
// three data-plane ledgers the integrated C+D design requires.
//
//   ledger 1: per-queue-class byte credit          (24 counters)
//   ledger 2: per-tenant DRR deficit               (4 counters)
//   ledger 3a: hard global speculative byte ceiling
//   ledger 3b: descriptor pool with RESERVED fallback descriptors
//
// Class index mapping: c = tenant*6 + obj*3 + cls
//   tenant in 0..3, obj in {KV=0, EXPERT=1}, cls in {MAND=0, FB=1, SPEC=2}
//
// Emits the 24-wide combinational eligibility vector consumed by the EDF tree,
// plus the safety flags that the assertions and ILA triggers key off.
`timescale 1ns/1ps
`default_nettype none

module credit_accountant_4t #(
  parameter int NT  = 4,
  parameter int NC  = 24,
  parameter int CW  = 32,   // credit / byte-ledger width
  parameter int BW  = 20,   // per-request byte count width (max 1 MiB)
  parameter int IFW = 6     // per-class in-flight counter width
)(
  input  wire               clk,
  input  wire               rst_n,

  // offered work, one slot per queue-class
  input  wire [NC-1:0]      i_req_valid,
  input  wire [NC*BW-1:0]   i_req_bytes,

  // grant coming back from the EDF tree
  input  wire               i_grant_valid,
  input  wire [4:0]         i_grant_idx,
  input  wire [BW-1:0]      i_grant_bytes,

  // P1 feedback path: data plane -> control plane
  input  wire               i_cmpl_valid,
  input  wire [4:0]         i_cmpl_idx,
  input  wire [BW-1:0]      i_cmpl_bytes,

  // DRR quantum replenish
  input  wire               i_quantum_tick,
  input  wire [CW-1:0]      i_quantum,
  input  wire [CW-1:0]      i_credit_cap,

  // configuration
  input  wire [CW-1:0]      i_spec_ceiling,
  input  wire [7:0]         i_desc_total,
  input  wire [7:0]         i_fb_reserve,

  output wire [NC-1:0]      o_eligible,
  output reg  [CW-1:0]      o_spec_out,
  output reg  [7:0]         o_desc_free,
  output reg  [7:0]         o_fb_free,
  output wire               o_spec_ceiling_hit,
  output wire               o_fb_exhausted,
  output reg                o_viol_spec_over,   // safety: spec exceeded ceiling
  output reg                o_viol_fb_starved   // safety: fallback reserve broken
);

  localparam [1:0] CLS_MAND = 2'd0;
  localparam [1:0] CLS_FB   = 2'd1;
  localparam [1:0] CLS_SPEC = 2'd2;

  reg [CW-1:0]  credit  [0:NC-1];
  reg [CW-1:0]  deficit [0:NT-1];
  reg [IFW-1:0] inflight[0:NC-1];

  wire [BW-1:0] bytes [0:NC-1];
  genvar g;
  generate
    for (g = 0; g < NC; g = g + 1) begin : G_BYTES
      assign bytes[g] = i_req_bytes[g*BW +: BW];
    end
  endgenerate

  // ---------------- combinational eligibility over all 24 classes ----------------
  wire [NC-1:0] elig;
  generate
    for (g = 0; g < NC; g = g + 1) begin : G_ELIG
      localparam int          TID = g / 6;
      localparam logic [1:0]  CLS = (g % 3);
      wire [CW-1:0] b_ext    = {{(CW-BW){1'b0}}, bytes[g]};
      wire [CW:0]   spec_sum = {1'b0, o_spec_out} + {1'b0, b_ext};
      wire ok_credit  = (credit[g]       >= b_ext);
      wire ok_deficit = (deficit[TID]    >= b_ext);
      wire ok_spec    = (CLS == CLS_SPEC) ? (spec_sum <= {1'b0, i_spec_ceiling}) : 1'b1;
      wire ok_desc    = (CLS == CLS_FB)   ? (o_fb_free != 8'd0)
                                          : (o_desc_free > i_fb_reserve);
      wire ok_if      = (inflight[g] != {IFW{1'b1}});
      assign elig[g]  = i_req_valid[g] & ok_credit & ok_deficit &
                        ok_spec & ok_desc & ok_if;
    end
  endgenerate
  assign o_eligible = elig;

  assign o_spec_ceiling_hit = (o_spec_out >= i_spec_ceiling);
  assign o_fb_exhausted     = (o_fb_free == 8'd0);

  // ---------------- grant / completion decode ----------------
  wire [1:0] gr_cls = (i_grant_idx % 5'd3);
  wire [1:0] cm_cls = (i_cmpl_idx  % 5'd3);
  wire [CW-1:0] gr_b = {{(CW-BW){1'b0}}, i_grant_bytes};
  wire [CW-1:0] cm_b = {{(CW-BW){1'b0}}, i_cmpl_bytes};
  wire [2:0] gr_tid = i_grant_idx / 5'd6;

  integer i;
  always @(posedge clk) begin
    if (!rst_n) begin
      for (i = 0; i < NC; i = i + 1) begin
        credit[i]   <= '0;
        inflight[i] <= '0;
      end
      for (i = 0; i < NT; i = i + 1) deficit[i] <= '0;
      o_spec_out       <= '0;
      o_desc_free      <= 8'd0;
      o_fb_free        <= 8'd0;
      o_viol_spec_over <= 1'b0;
      o_viol_fb_starved<= 1'b0;
    end else begin
      // DRR replenish, saturating
      if (i_quantum_tick) begin
        for (i = 0; i < NT; i = i + 1)
          deficit[i] <= ((deficit[i] + i_quantum) > i_credit_cap)
                        ? i_credit_cap : (deficit[i] + i_quantum);
        for (i = 0; i < NC; i = i + 1)
          credit[i]  <= ((credit[i] + i_quantum) > i_credit_cap)
                        ? i_credit_cap : (credit[i] + i_quantum);
      end

      // charge on grant (per-class state)
      if (i_grant_valid) begin
        credit[i_grant_idx]   <= credit[i_grant_idx]   - gr_b;
        deficit[gr_tid[1:0]]  <= deficit[gr_tid[1:0]]  - gr_b;
        inflight[i_grant_idx] <= inflight[i_grant_idx] + 1'b1;
      end
      // return on completion (D -> C feedback path)
      if (i_cmpl_valid)
        inflight[i_cmpl_idx] <= inflight[i_cmpl_idx] - 1'b1;

      // global ledgers: grant and completion can land in the same cycle,
      // so both deltas must be applied together, not as separate writes.
      o_desc_free <= o_desc_free
                     - ((i_grant_valid) ? 8'd1 : 8'd0)
                     + ((i_cmpl_valid)  ? 8'd1 : 8'd0);
      o_fb_free   <= o_fb_free
                     - ((i_grant_valid && gr_cls == CLS_FB) ? 8'd1 : 8'd0)
                     + ((i_cmpl_valid  && cm_cls == CLS_FB) ? 8'd1 : 8'd0);
      o_spec_out  <= o_spec_out
                     - ((i_cmpl_valid  && cm_cls == CLS_SPEC) ? cm_b : {CW{1'b0}})
                     + ((i_grant_valid && gr_cls == CLS_SPEC) ? gr_b : {CW{1'b0}});

      // safety monitors
      o_viol_spec_over  <= (o_spec_out > i_spec_ceiling);
      o_viol_fb_starved <= (o_desc_free < i_fb_reserve);
    end
  end

endmodule

`default_nettype wire
