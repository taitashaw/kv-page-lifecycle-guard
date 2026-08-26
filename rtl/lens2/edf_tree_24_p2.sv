// LENS 2 remedy probe: same 24-entry EDF tree, cut into 2 pipeline stages
// (register inserted after level 2, i.e. after 24 -> 12 -> 6).
// Adds one cycle of arbitration latency. Everything else identical.
`timescale 1ns/1ps
`default_nettype none

module edf_tree_24_p2 #(
  parameter int N   = 24,
  parameter int DW  = 32,
  parameter int IDW = 5
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [N-1:0]        i_valid,
  input  wire [N-1:0]        i_eligible,
  input  wire [N*DW-1:0]     i_deadline,
  input  wire [2*N-1:0]      i_class,
  input  wire [2*N-1:0]      i_tenant,
  input  wire [DW-1:0]       i_now,
  output reg                 o_grant_valid,
  output reg  [IDW-1:0]      o_grant_idx,
  output reg  [DW-1:0]       o_grant_rel,
  output reg  [1:0]          o_grant_class,
  output reg  [1:0]          o_grant_tenant
);

  localparam int PW = 1 + 2 + DW + 2 + IDW;

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

  wire [PW-1:0] l0 [0:23];
  genvar g;
  generate
    for (g = 0; g < N; g = g + 1) begin : G_LEAF
      localparam logic [IDW-1:0] MYIDX = g[IDW-1:0];
      wire [DW-1:0] dl  = r_deadline[g*DW +: DW];
      wire [DW-1:0] rel = dl - r_now;
      wire          ok  = r_valid[g] & r_elig[g];
      assign l0[g] = { ok, r_class[g*2 +: 2], rel, r_tenant[g*2 +: 2], MYIDX };
    end
  endgenerate

  wire [PW-1:0] l1 [0:11];
  wire [PW-1:0] l2 [0:5];
  reg  [PW-1:0] p2 [0:5];
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
    // ---- pipeline cut ----
    for (g = 0; g < 6; g = g + 1) begin : G_P2
      always @(posedge clk) p2[g] <= l2[g];
    end
    for (g = 0; g < 3; g = g + 1) begin : G_L3
      assign l3[g] = pick_a(p2[2*g], p2[2*g+1]) ? p2[2*g] : p2[2*g+1];
    end
  endgenerate

  assign l4[0] = pick_a(l3[0], l3[1]) ? l3[0] : l3[1];
  assign l4[1] = l3[2];
  assign l5    = pick_a(l4[0], l4[1]) ? l4[0] : l4[1];

  always @(posedge clk) begin
    if (!rst_n) o_grant_valid <= 1'b0;
    else        o_grant_valid <= l5[PW-1];
    o_grant_class  <= l5[PW-2 -: 2];
    o_grant_rel    <= l5[IDW+2 +: DW];
    o_grant_tenant <= l5[IDW +: 2];
    o_grant_idx    <= l5[IDW-1:0];
  end

endmodule

`default_nettype wire
