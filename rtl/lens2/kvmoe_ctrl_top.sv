// LENS 2 compounding probe: the integrated C+D control path in one module.
// EDF tree + credit accountant + page-state lookup + deadline-aware admission
// + descriptor reservation + a 128-bit AXI4 read-address issuer with 4 KiB
// boundary splitting, plus the counters and probe bundle.
//
// This exists to measure what INTEGRATION costs, not to be a finished design.
`timescale 1ns/1ps
`default_nettype none

module kvmoe_ctrl_top #(
  parameter int NC   = 24,
  parameter int BW   = 20,
  parameter int CW   = 32,
  parameter int IDXW = 14,
  parameter int TAGW = 34,
  parameter int EW   = 129,
  parameter int AW   = 40
)(
  input  wire              clk,
  input  wire              rst_n,

  // offered work
  input  wire [NC-1:0]     i_req_valid,
  input  wire [NC*BW-1:0]  i_req_bytes,
  input  wire [NC*32-1:0]  i_req_deadline,
  input  wire [2*NC-1:0]   i_req_class,
  input  wire [2*NC-1:0]   i_req_tenant,
  input  wire [31:0]       i_now,

  // page identity for the head of the granted class
  input  wire [IDXW-1:0]   i_lk_index,
  input  wire [TAGW-1:0]   i_lk_tag,

  // config
  input  wire [CW-1:0]     i_spec_ceiling,
  input  wire [7:0]        i_desc_total,
  input  wire [7:0]        i_fb_reserve,
  input  wire [CW-1:0]     i_quantum,
  input  wire [CW-1:0]     i_credit_cap,
  input  wire              i_quantum_tick,
  input  wire [31:0]       i_svc_rate,      // declared downstream service envelope
  input  wire [AW-1:0]     i_base_addr,

  // AXI4 read address channel to S_AXI_HP (128-bit)
  output reg  [AW-1:0]     m_axi_araddr,
  output reg  [7:0]        m_axi_arlen,
  output reg  [2:0]        m_axi_arsize,
  output reg  [1:0]        m_axi_arburst,
  output reg  [5:0]        m_axi_arid,
  output reg               m_axi_arvalid,
  input  wire              m_axi_arready,

  // completion feedback from the data plane (P1 D -> C)
  input  wire              i_cmpl_valid,
  input  wire [4:0]        i_cmpl_idx,
  input  wire [BW-1:0]     i_cmpl_bytes,
  input  wire [IDXW-1:0]   i_cmpl_index,
  input  wire [1:0]        i_cmpl_way,
  input  wire [7:0]        i_cmpl_gen,

  // observability
  output wire [31:0]       o_cnt_offered,
  output wire [31:0]       o_cnt_admitted,
  output wire [31:0]       o_cnt_completed,
  output wire [31:0]       o_cnt_ontime,
  output wire [31:0]       o_cnt_rejected,
  output wire [255:0]      o_probe,
  output wire [8:0]        o_trigger
);

  // ---------------- credit accountant ----------------
  wire [NC-1:0] elig;
  wire [CW-1:0] spec_out;
  wire [7:0]    desc_free, fb_free;
  wire          spec_hit, fb_exh, viol_spec, viol_fb;

  wire        gr_v;
  wire [4:0]  gr_idx;
  wire [31:0] gr_rel;
  wire [1:0]  gr_cls, gr_ten;

  wire [BW-1:0] gr_bytes = i_req_bytes[gr_idx*BW +: BW];

  credit_accountant_4t #(.NC(NC), .CW(CW), .BW(BW)) u_credit (
    .clk(clk), .rst_n(rst_n),
    .i_req_valid(i_req_valid), .i_req_bytes(i_req_bytes),
    .i_grant_valid(admit), .i_grant_idx(gr_idx), .i_grant_bytes(gr_bytes),
    .i_cmpl_valid(i_cmpl_valid), .i_cmpl_idx(i_cmpl_idx), .i_cmpl_bytes(i_cmpl_bytes),
    .i_quantum_tick(i_quantum_tick), .i_quantum(i_quantum), .i_credit_cap(i_credit_cap),
    .i_spec_ceiling(i_spec_ceiling), .i_desc_total(i_desc_total), .i_fb_reserve(i_fb_reserve),
    .o_eligible(elig), .o_spec_out(spec_out),
    .o_desc_free(desc_free), .o_fb_free(fb_free),
    .o_spec_ceiling_hit(spec_hit), .o_fb_exhausted(fb_exh),
    .o_viol_spec_over(viol_spec), .o_viol_fb_starved(viol_fb)
  );

  // ---------------- EDF selection ----------------
  edf_tree_24 #(.N(NC)) u_edf (
    .clk(clk), .rst_n(rst_n),
    .i_valid(i_req_valid), .i_eligible(elig),
    .i_deadline(i_req_deadline), .i_class(i_req_class), .i_tenant(i_req_tenant),
    .i_now(i_now),
    .o_grant_valid(gr_v), .o_grant_idx(gr_idx), .o_grant_rel(gr_rel),
    .o_grant_class(gr_cls), .o_grant_tenant(gr_ten)
  );

  // ---------------- page state lookup ----------------
  wire        pg_hit, pg_miss;
  wire [1:0]  pg_way;
  wire [19:0] pg_phys;
  wire [7:0]  pg_ref, pg_gen;
  wire [5:0]  pg_ifl;
  wire        pg_fill, pg_rsv;
  wire [31:0] pg_dli;
  wire [3:0]  pg_state;
  wire        v_evict, v_ten, v_gen, v_sat;

  page_state_lut #(.IDXW(IDXW), .TAGW(TAGW), .EW(EW)) u_pg (
    .clk(clk), .rst_n(rst_n),
    .i_lk_valid(gr_v), .i_lk_index(i_lk_index), .i_lk_tag(i_lk_tag),
    .i_lk_tenant(gr_ten), .i_lk_op(gr_cls), .i_lk_deadline(gr_rel),
    .o_hit(pg_hit), .o_miss(pg_miss), .o_hit_way(pg_way), .o_phys_idx(pg_phys),
    .o_refcount(pg_ref), .o_inflight(pg_ifl), .o_fill_pending(pg_fill),
    .o_generation(pg_gen), .o_reserved(pg_rsv), .o_deadline_inh(pg_dli),
    .o_state(pg_state),
    .o_viol_evict_live(v_evict), .o_viol_tenant_cross(v_ten),
    .o_viol_gen_stale(v_gen), .o_viol_refcount_sat(v_sat),
    .i_cmpl_valid(i_cmpl_valid), .i_cmpl_index(i_cmpl_index),
    .i_cmpl_way(i_cmpl_way), .i_cmpl_gen(i_cmpl_gen)
  );

  // ---------------- deadline-aware admission ----------------
  // Non-preemptive demand test with quiescence precedence:
  //   drain(A) + fill(B) <= slack(B), and the frame must be reservable.
  wire [31:0] bytes_ext   = {12'd0, gr_bytes};
  wire [31:0] drain_cyc   = {26'd0, pg_ifl} << 3;                 // in-flight drain
  wire [31:0] fill_cyc    = bytes_ext[31:4];                      // 128-bit beats
  wire [31:0] demand_cyc  = drain_cyc + fill_cyc;
  wire [31:0] svc_cyc     = (i_svc_rate == 32'd0) ? 32'hFFFF_FFFF
                            : (demand_cyc * 32'd1) + i_svc_rate;
  wire        quiescent   = (pg_ref == 8'd0) && (pg_ifl == 6'd0) && !pg_fill;
  wire        feasible    = (svc_cyc <= gr_rel);
  wire        reservable  = (desc_free > i_fb_reserve) && !pg_rsv;
  wire        spec_ok     = (gr_cls != 2'd2) || (!spec_hit);

  wire admit  = gr_v && (pg_hit || quiescent) && feasible && reservable && spec_ok;
  wire reject = gr_v && !admit;

  // ---------------- AXI read-address issue with 4 KiB split ----------------
  reg [AW-1:0] cur_addr;
  reg [31:0]   cur_rem;
  reg          busy;

  wire [12:0] to_boundary = 13'd4096 - {1'b0, cur_addr[11:0]};
  wire [31:0] this_chunk  = (cur_rem > {19'd0, to_boundary})
                            ? {19'd0, to_boundary} : cur_rem;
  wire [8:0]  this_beats  = this_chunk[12:4] + (|this_chunk[3:0]);
  wire [7:0]  this_len    = (this_beats == 9'd0) ? 8'd0 : (this_beats[7:0] - 8'd1);

  always @(posedge clk) begin
    if (!rst_n) begin
      busy <= 1'b0; m_axi_arvalid <= 1'b0; cur_rem <= 32'd0;
    end else begin
      if (!busy && admit) begin
        busy          <= 1'b1;
        cur_addr      <= i_base_addr + {12'd0, pg_phys, 8'd0};
        cur_rem       <= bytes_ext;
      end else if (busy && (!m_axi_arvalid || m_axi_arready)) begin
        m_axi_arvalid <= 1'b1;
        m_axi_araddr  <= cur_addr;
        m_axi_arlen   <= this_len;
        m_axi_arsize  <= 3'd4;         // 16 bytes per beat, 128-bit
        m_axi_arburst <= 2'b01;
        m_axi_arid    <= {gr_ten, gr_cls, 2'b00};
        cur_addr      <= cur_addr + this_chunk[AW-1:0];
        cur_rem       <= cur_rem - this_chunk;
        if (cur_rem <= this_chunk) busy <= 1'b0;
      end else if (m_axi_arready) begin
        m_axi_arvalid <= 1'b0;
      end
    end
  end

  // ---------------- counters ----------------
  reg [31:0] c_off, c_adm, c_cmp, c_ont, c_rej;
  always @(posedge clk) begin
    if (!rst_n) begin
      c_off <= 0; c_adm <= 0; c_cmp <= 0; c_ont <= 0; c_rej <= 0;
    end else begin
      if (|i_req_valid)  c_off <= c_off + 32'd1;
      if (admit)         c_adm <= c_adm + 32'd1;
      if (reject)        c_rej <= c_rej + 32'd1;
      if (i_cmpl_valid) begin
        c_cmp <= c_cmp + 32'd1;
        if (!gr_rel[31]) c_ont <= c_ont + 32'd1;
      end
    end
  end

  assign o_cnt_offered   = c_off;
  assign o_cnt_admitted  = c_adm;
  assign o_cnt_completed = c_cmp;
  assign o_cnt_ontime    = c_ont;
  assign o_cnt_rejected  = c_rej;

  // ---------------- nine trigger conditions + probe bundle ----------------
  assign o_trigger = { v_evict,          // 1 eviction while ref/inflight/fill nonzero
                       v_ten,            // 2 cross-tenant hit
                       v_gen,            // 3 stale-generation completion
                       v_sat,            // 4 refcount saturation
                       viol_spec,        // 5 speculative ceiling breach
                       viol_fb,          // 6 fallback reserve broken
                       gr_rel[31],       // 7 deadline missed (rel went negative)
                       reject,           // 8 admission rejection
                       (fb_exh & gr_v) };// 9 mandatory blocked with no fallback desc

  assign o_probe = { 23'd0,
                     o_trigger,          //  9
                     gr_rel,             // 32
                     spec_out,           // 32
                     c_adm,              // 32
                     c_rej,              // 32
                     desc_free, fb_free, // 16
                     pg_phys,            // 20
                     pg_ref, pg_gen,     // 16
                     pg_ifl,             //  6
                     pg_state,           //  4
                     pg_fill, pg_rsv,    //  2
                     pg_hit, pg_miss,    //  2
                     gr_idx,             //  5
                     gr_cls, gr_ten,     //  4
                     gr_v, admit, busy, m_axi_arvalid }; // 4  -> 256
endmodule

`default_nettype wire
