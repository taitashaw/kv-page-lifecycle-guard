// LENS 2 buildability probe: 4-way set-associative page-state lookup in URAM
// with the FULL integrated entry: refcount, inflight, fill_pending, generation,
// tenant, reservation and the inherited deadline that the coalesced-fill
// witness in the Candidate C pass forces into the table.
//
// EW is a parameter so the same RTL is synthesised at both candidate entry
// widths:
//   EW=129  exact 48-bit identity, no verifier word
//   EW=193  64-bit hashed identity + 64-bit verifier word
//
// Pipeline: addr -> URAM read -> cascade reg -> way compare/select ->
//           read-modify-write merge, with same-set forwarding.
`timescale 1ns/1ps
`default_nettype none

module page_state_lut #(
  parameter int SETS = 16384,
  parameter int IDXW = 14,
  parameter int WAYS = 4,
  parameter int TAGW = 34,
  parameter int EW   = 129
)(
  input  wire             clk,
  input  wire             rst_n,

  // lookup request
  input  wire             i_lk_valid,
  input  wire [IDXW-1:0]  i_lk_index,
  input  wire [TAGW-1:0]  i_lk_tag,
  input  wire [1:0]       i_lk_tenant,
  input  wire [1:0]       i_lk_op,     // 0 ref, 1 release, 2 fill-start, 3 fill-done
  input  wire [31:0]      i_lk_deadline,

  // lookup result
  output reg              o_hit,
  output reg              o_miss,
  output reg  [1:0]       o_hit_way,
  output reg  [19:0]      o_phys_idx,
  output reg  [7:0]       o_refcount,
  output reg  [5:0]       o_inflight,
  output reg              o_fill_pending,
  output reg  [7:0]       o_generation,
  output reg              o_reserved,
  output reg  [31:0]      o_deadline_inh,
  output reg  [3:0]       o_state,

  // safety monitors (assertion + ILA trigger sources)
  output reg              o_viol_evict_live,     // evict while ref/inflight/fill nonzero
  output reg              o_viol_tenant_cross,   // tag hit with wrong tenant
  output reg              o_viol_gen_stale,      // completion against retired generation
  output reg              o_viol_refcount_sat,

  // stale-completion probe from the data plane
  input  wire             i_cmpl_valid,
  input  wire [IDXW-1:0]  i_cmpl_index,
  input  wire [1:0]       i_cmpl_way,
  input  wire [7:0]       i_cmpl_gen
);

  // -------- entry field offsets (LSB-first) --------
  localparam int O_VALID = 0;                    // 1
  localparam int O_TAG   = O_VALID + 1;          // TAGW
  localparam int O_PHYS  = O_TAG   + TAGW;       // 20
  localparam int O_STATE = O_PHYS  + 20;         // 4
  localparam int O_REF   = O_STATE + 4;          // 8
  localparam int O_LRU   = O_REF   + 8;          // 4
  localparam int O_GEN   = O_LRU   + 4;          // 8
  localparam int O_TEN   = O_GEN   + 8;          // 2
  localparam int O_RSV   = O_TEN   + 2;          // 1
  localparam int O_RSVO  = O_RSV   + 1;          // 6
  localparam int O_IFL   = O_RSVO  + 6;          // 6
  localparam int O_FILL  = O_IFL   + 6;          // 1
  localparam int O_DLI   = O_FILL  + 1;          // 32
  localparam int O_CLS   = O_DLI   + 32;         // 2  -> 129 bits total

  // -------- stage 0: request register --------
  reg             s0_v;
  reg [IDXW-1:0]  s0_idx;
  reg [TAGW-1:0]  s0_tag;
  reg [1:0]       s0_ten, s0_op;
  reg [31:0]      s0_dl;

  always @(posedge clk) begin
    if (!rst_n) s0_v <= 1'b0; else s0_v <= i_lk_valid;
    s0_idx <= i_lk_index;
    s0_tag <= i_lk_tag;
    s0_ten <= i_lk_tenant;
    s0_op  <= i_lk_op;
    s0_dl  <= i_lk_deadline;
  end

  // -------- writeback port (driven by stage 3) --------
  reg             wb_en;
  reg [IDXW-1:0]  wb_idx;
  reg [1:0]       wb_way;
  reg [EW-1:0]    wb_data;

  // -------- the four way banks, one URAM stack each --------
  wire [EW-1:0] rd2 [0:WAYS-1];
  genvar w;
  generate
    for (w = 0; w < WAYS; w = w + 1) begin : G_WAY
      (* ram_style = "ultra" *) reg [EW-1:0] mem [0:SETS-1];
      reg [EW-1:0] rd_r, rd_rr;
      always @(posedge clk) begin
        if (wb_en && (wb_way == w[1:0])) mem[wb_idx] <= wb_data;
        rd_r  <= mem[s0_idx];
        rd_rr <= rd_r;          // cascade / output pipeline stage
      end
      assign rd2[w] = rd_rr;
    end
  endgenerate

  // -------- stage 1 / 2: carry request alongside the memory latency --------
  reg            s1_v, s2_v;
  reg [IDXW-1:0] s1_idx, s2_idx;
  reg [TAGW-1:0] s1_tag, s2_tag;
  reg [1:0]      s1_ten, s2_ten, s1_op, s2_op;
  reg [31:0]     s1_dl,  s2_dl;

  always @(posedge clk) begin
    if (!rst_n) begin s1_v <= 1'b0; s2_v <= 1'b0; end
    else        begin s1_v <= s0_v; s2_v <= s1_v; end
    s1_idx <= s0_idx; s2_idx <= s1_idx;
    s1_tag <= s0_tag; s2_tag <= s1_tag;
    s1_ten <= s0_ten; s2_ten <= s1_ten;
    s1_op  <= s0_op;  s2_op  <= s1_op;
    s1_dl  <= s0_dl;  s2_dl  <= s1_dl;
  end

  // -------- stage 3: way compare and select, with same-set forwarding --------
  wire [EW-1:0] way_d [0:WAYS-1];
  wire [WAYS-1:0] way_tag_hit;
  wire [WAYS-1:0] way_full_hit;

  generate
    for (w = 0; w < WAYS; w = w + 1) begin : G_CMP
      // forward an in-flight writeback to the same set and way
      assign way_d[w] = (wb_en && wb_idx == s2_idx && wb_way == w[1:0])
                        ? wb_data : rd2[w];
      assign way_tag_hit[w]  = way_d[w][O_VALID] &&
                               (way_d[w][O_TAG +: TAGW] == s2_tag);
      // tenant is part of lookup equality: isolation is structural, not advisory
      assign way_full_hit[w] = way_tag_hit[w] &&
                               (way_d[w][O_TEN +: 2] == s2_ten);
    end
  endgenerate

  wire hit_any = |way_full_hit;
  wire [1:0] hit_way = way_full_hit[0] ? 2'd0 :
                       way_full_hit[1] ? 2'd1 :
                       way_full_hit[2] ? 2'd2 : 2'd3;
  wire [EW-1:0] hit_e = way_d[hit_way];

  wire [7:0] cur_ref  = hit_e[O_REF +: 8];
  wire [5:0] cur_ifl  = hit_e[O_IFL +: 6];
  wire       cur_fill = hit_e[O_FILL];
  wire [3:0] cur_st   = hit_e[O_STATE +: 4];
  wire [31:0] cur_dli = hit_e[O_DLI +: 32];

  // quiescence: the C pass counterexample requires ALL of these to be zero
  wire quiescent = (cur_ref == 8'd0) && (cur_ifl == 6'd0) && !cur_fill;

  wire [7:0]  nxt_ref  = (s2_op == 2'd0) ? (cur_ref + 8'd1)
                       : (s2_op == 2'd1) ? (cur_ref - 8'd1) : cur_ref;
  wire [5:0]  nxt_ifl  = (s2_op == 2'd2) ? (cur_ifl + 6'd1)
                       : (s2_op == 2'd3) ? (cur_ifl - 6'd1) : cur_ifl;
  wire        nxt_fill = (s2_op == 2'd2) ? 1'b1
                       : (s2_op == 2'd3) ? 1'b0 : cur_fill;
  // inherited deadline: a shared prerequisite fill takes the earliest waiter
  wire        dl_earlier = (s2_dl - cur_dli) & 32'h8000_0000 ? 1'b1 : 1'b0;
  wire [31:0] nxt_dli  = (cur_fill && dl_earlier) ? s2_dl
                       : (s2_op == 2'd2)          ? s2_dl : cur_dli;

  reg [EW-1:0] merged;
  always @(*) begin
    merged                = hit_e;
    merged[O_REF  +: 8]   = nxt_ref;
    merged[O_IFL  +: 6]   = nxt_ifl;
    merged[O_FILL]        = nxt_fill;
    merged[O_DLI  +: 32]  = nxt_dli;
    merged[O_LRU  +: 4]   = 4'd0;
    merged[O_STATE +: 4]  = (s2_op == 2'd2) ? 4'd4 : cur_st;
    // generation advances only when the frame is genuinely reclaimable
    merged[O_GEN  +: 8]   = (quiescent && s2_op == 2'd1)
                            ? (hit_e[O_GEN +: 8] + 8'd1)
                            : hit_e[O_GEN +: 8];
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      wb_en <= 1'b0;
      o_hit <= 1'b0; o_miss <= 1'b0;
      o_viol_evict_live   <= 1'b0;
      o_viol_tenant_cross <= 1'b0;
      o_viol_gen_stale    <= 1'b0;
      o_viol_refcount_sat <= 1'b0;
    end else begin
      wb_en   <= s2_v && hit_any;
      wb_idx  <= s2_idx;
      wb_way  <= hit_way;
      wb_data <= merged;

      o_hit          <= s2_v &&  hit_any;
      o_miss         <= s2_v && !hit_any;
      o_hit_way      <= hit_way;
      o_phys_idx     <= hit_e[O_PHYS +: 20];
      o_refcount     <= nxt_ref;
      o_inflight     <= nxt_ifl;
      o_fill_pending <= nxt_fill;
      o_generation   <= hit_e[O_GEN +: 8];
      o_reserved     <= hit_e[O_RSV];
      o_deadline_inh <= nxt_dli;
      o_state        <= cur_st;

      // safety monitors
      o_viol_evict_live   <= s2_v && hit_any && (s2_op == 2'd1) && !quiescent &&
                             (cur_st == 4'd5);
      o_viol_tenant_cross <= s2_v && (|way_tag_hit) && !hit_any;
      o_viol_refcount_sat <= s2_v && hit_any && (s2_op == 2'd0) &&
                             (cur_ref == 8'hFF);
      o_viol_gen_stale    <= i_cmpl_valid &&
                             (i_cmpl_gen != rd2[i_cmpl_way][O_GEN +: 8]);
    end
  end

endmodule

`default_nettype wire
