// LENS 2 buildability probe: EDF selection tree over 24 queue-classes.
// 4 tenants x {KV, expert} x {mandatory, fallback, speculative} = 24.
// Worst case by construction: single-cycle combinational reduction tree,
// flop-in / flop-out, class-priority-then-deadline ordering, wrap-safe
// relative-deadline comparison, deterministic left-biased tie-break.
`timescale 1ns/1ps
`default_nettype none

module edf_tree_24 #(
  parameter int N   = 24,
  parameter int DW  = 32,
  parameter int IDW = 5
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [N-1:0]        i_valid,
  input  wire [N-1:0]        i_eligible,   // from the credit accountant
  input  wire [N*DW-1:0]     i_deadline,
  input  wire [2*N-1:0]      i_class,      // 0 mandatory, 1 fallback, 2 speculative
  input  wire [2*N-1:0]      i_tenant,
  input  wire [DW-1:0]       i_now,
  output reg                 o_grant_valid,
  output reg  [IDW-1:0]      o_grant_idx,
  output reg  [DW-1:0]       o_grant_rel,
  output reg  [1:0]          o_grant_class,
  output reg  [1:0]          o_grant_tenant
);

  localparam int PW = 1 + 2 + DW + 2 + IDW;   // ok | class | rel | tenant | idx

  // ---------------- input registers ----------------
  reg [N-1:0]    r_valid, r_elig;
  reg [N*DW-1:0] r_deadline;
  reg [2*N-1:0]  r_class, r_tenant;
  reg [DW-1:0]   r_now;

  always @(posedge clk) begin
    if (!rst_n) begin
      r_valid <= '0; r_elig <= '0;
    end else begin
      r_valid <= i_valid; r_elig <= i_eligible;
    end
    r_deadline <= i_deadline;
    r_class    <= i_class;
    r_tenant   <= i_tenant;
    r_now      <= i_now;
  end

  // ---------------- comparator ----------------
  // a wins iff: a eligible and b not; else lower class number; else smaller
  // relative deadline; else lower index (implicit, left subtree bias).
  function automatic logic pick_a(input logic [PW-1:0] a, input logic [PW-1:0] b);
    logic          ok_a, ok_b;
    logic [1:0]    ca, cb;
    logic [DW-1:0] ra, rb;
    begin
      ok_a = a[PW-1];        ok_b = b[PW-1];
      ca   = a[PW-2 -: 2];   cb   = b[PW-2 -: 2];
      ra   = a[IDW+2 +: DW]; rb   = b[IDW+2 +: DW];
      if (ok_a != ok_b)      pick_a = ok_a;
      else if (!ok_a)        pick_a = 1'b1;
      else if (ca != cb)     pick_a = (ca < cb);
      else                   pick_a = (ra <= rb);
    end
  endfunction

  // ---------------- leaves ----------------
  wire [PW-1:0] l0 [0:23];
  genvar g;
  generate
    for (g = 0; g < N; g = g + 1) begin : G_LEAF
      localparam logic [IDW-1:0] MYIDX = g[IDW-1:0];
      wire [DW-1:0] dl  = r_deadline[g*DW +: DW];
      wire [DW-1:0] rel = dl - r_now;                    // wrap-safe
      wire          ok  = r_valid[g] & r_elig[g];
      assign l0[g] = { ok, r_class[g*2 +: 2], rel, r_tenant[g*2 +: 2], MYIDX };
    end
  endgenerate

  // ---------------- reduction tree: 24 -> 12 -> 6 -> 3 -> 2 -> 1 ----------------
  wire [PW-1:0] l1 [0:11];
  wire [PW-1:0] l2 [0:5];
  wire [PW-1:0] l3 [0:2];
  wire [PW-1:0] l4 [0:1];
  wire [PW-1:0] l5;

  generate
    for (g = 0; g < 12; g = g + 1) begin : G_L1
      assign l1[g] = pick_a(l0[2*g], l0[2*g+1]) ? l0[2*g] : l0[2*g+1];
    end
    for (g = 0; g < 6; g = g + 1) begin : G_L2
      assign l2[g] = pick_a(l1[2*g], l1[2*g+1]) ? l1[2*g] : l1[2*g+1];
    end
    for (g = 0; g < 3; g = g + 1) begin : G_L3
      assign l3[g] = pick_a(l2[2*g], l2[2*g+1]) ? l2[2*g] : l2[2*g+1];
    end
  endgenerate

  assign l4[0] = pick_a(l3[0], l3[1]) ? l3[0] : l3[1];
  assign l4[1] = l3[2];
  assign l5    = pick_a(l4[0], l4[1]) ? l4[0] : l4[1];

  // ---------------- output registers ----------------
  always @(posedge clk) begin
    if (!rst_n) begin
      o_grant_valid <= 1'b0;
    end else begin
      o_grant_valid <= l5[PW-1];
    end
    o_grant_class  <= l5[PW-2 -: 2];
    o_grant_rel    <= l5[IDW+2 +: DW];
    o_grant_tenant <= l5[IDW +: 2];
    o_grant_idx    <= l5[IDW-1:0];
  end

endmodule

`default_nettype wire
