// lifecycle_guard_top.sv
// Synthesizable top level for the FPGA lifecycle-safety artifact (V1).
//
//   AXI4-Lite slave  ->  request FIFO  ->  { page_state_lut | axi_read_manager }
//   axi_read_manager <-> tag_tracker   ->  page_state_lut (LC_COMPLETE)
//   axi_read_manager ->  event FIFO    ->  register view + ILA probe
//
// SCOPE. The tagged lifecycle interlock and nothing else. There is no EDF
// arbiter, no deficit counter and no credit accountant anywhere in this
// hierarchy. Sweep B closed that branch; it is not coming back.
//
// SAFETY, structural rather than asserted:
//   * axi_read_manager has no write channel, so no write can be emitted.
//   * axi_read_manager has no bypass input, so the scratch-window gate has
//     no software override. BOTH unsafe modes, CTRL.unsafe_bypass and
//     CTRL.no_generation_check, reach page_state_lut ONLY. They are the two
//     independent protections the artifact exists to separate: the evictable
//     interlock and generation tagging. Either or both can be removed to
//     demonstrate corruption, and in every case the damage is confined to
//     the artifact's own scratch buffer. Neither can read Linux memory or
//     arbitrary DDR, because neither is wired to the address gate.
//   * base==limit==0 out of reset means default deny.
//   * MAX_WINDOW_LOG2 caps the window at synthesis time regardless of what
//     software programs.
//
// CLOCKING AND RESET. Single clock. rst_n is an active-low reset that this
// file and its two new children treat SYNCHRONOUSLY. page_state_lut and
// tag_tracker are frozen and use an asynchronous-assert reset; driving them
// from a synchronously generated reset is safe and does not change their
// semantics. Deassert rst_n synchronously at the board level.
//
// SOFT RESET. CTRL.soft_reset is deferred until the read manager is idle
// with no outstanding transaction, so a soft reset can never abandon an AXI
// burst mid-flight. The register block itself is NOT soft-reset, so the host
// keeps its window programming and its counters' provenance.

`include "lifecycle_pkg.sv"

module lifecycle_guard_top
  import lifecycle_pkg::*;
#(
  parameter int unsigned C_ADDR_W        = 12,     // AXI-Lite aperture bits
  parameter int unsigned AXI_ADDR_W      = 40,
  parameter int unsigned AXI_DATA_W      = 128,
  parameter int unsigned MAX_OUTSTANDING = 2,
  parameter int unsigned REQ_FIFO_DEPTH  = 8,      // power of two
  parameter int unsigned EVT_FIFO_DEPTH  = 16,     // power of two
  parameter int unsigned MAX_WINDOW_LOG2 = 20,     // hard cap, 1 MiB
  parameter int unsigned ILA_W           = 196     // fixed; do not override
)(
  input  wire                     clk,
  input  wire                     rst_n,

  // ------------------------------------------------------ AXI4-Lite slave
  input  wire [C_ADDR_W-1:0]      s_axi_awaddr,
  input  wire [2:0]               s_axi_awprot,
  input  wire                     s_axi_awvalid,
  output wire                     s_axi_awready,
  input  wire [31:0]              s_axi_wdata,
  input  wire [3:0]               s_axi_wstrb,
  input  wire                     s_axi_wvalid,
  output wire                     s_axi_wready,
  output wire [1:0]               s_axi_bresp,
  output wire                     s_axi_bvalid,
  input  wire                     s_axi_bready,
  input  wire [C_ADDR_W-1:0]      s_axi_araddr,
  input  wire [2:0]               s_axi_arprot,
  input  wire                     s_axi_arvalid,
  output wire                     s_axi_arready,
  output wire [31:0]              s_axi_rdata,
  output wire [1:0]               s_axi_rresp,
  output wire                     s_axi_rvalid,
  input  wire                     s_axi_rready,

  // -------------------------------------------- AXI4 manager, READ ONLY
  output wire [TAG_W-1:0]         m_axi_arid,
  output wire [AXI_ADDR_W-1:0]    m_axi_araddr,
  output wire [7:0]               m_axi_arlen,
  output wire [2:0]               m_axi_arsize,
  output wire [1:0]               m_axi_arburst,
  output wire                     m_axi_arlock,
  output wire [3:0]               m_axi_arcache,
  output wire [2:0]               m_axi_arprot,
  output wire [3:0]               m_axi_arqos,
  output wire                     m_axi_arvalid,
  input  wire                     m_axi_arready,
  input  wire [TAG_W-1:0]         m_axi_rid,
  input  wire [AXI_DATA_W-1:0]    m_axi_rdata,
  input  wire [1:0]               m_axi_rresp,
  input  wire                     m_axi_rlast,
  input  wire                     m_axi_rvalid,
  output wire                     m_axi_rready,

  // ==================================================================== DEBUG
  // Named per-field debug outputs, one ILA probe each. Designed against the
  // four things an ILA is actually for, rather than dumping internal state
  // into one wide bus that reads as a single unnamed signal in Hardware
  // Manager and cannot be triggered on field by field.
  //
  //  BRING-UP                dbg_rstn, dbg_heartbeat
  //  SAFETY PREDICATE        refcount / reservation / inflight / fill_pending
  //  DECISIONS               reuse_req / grant / refused, stale, payload_mm
  //  WHAT SIM CANNOT PRODUCE real AR backpressure and real DDR read latency
  //  RARE FAILURES           dbg_sticky, latched until explicitly cleared
  //  PERFORMANCE             ar_wait, rd_latency, rd_latency_max, outstanding
  //
  // Adding a signal here costs a full rebuild, so the list is deliberate.
  output logic                    dbg_rstn,
  output logic [15:0]             dbg_heartbeat,
  output logic [7:0]              dbg_refcount,
  output logic [7:0]              dbg_reservation,
  output logic [5:0]              dbg_inflight,
  output logic [3:0]              dbg_fill_pending,
  output logic [7:0]              dbg_generation,
  output logic [7:0]              dbg_exp_generation,
  output logic [5:0]              dbg_slot,
  output logic [5:0]              dbg_phys,
  output logic                    dbg_reuse_req,
  output logic                    dbg_reuse_grant,
  output logic                    dbg_reuse_refused,
  output logic                    dbg_stale,
  output logic                    dbg_payload_mm,
  output logic                    dbg_evictable,
  output logic [1:0]              dbg_outstanding,
  output logic [15:0]             dbg_ar_wait,
  output logic [15:0]             dbg_rd_latency,
  output logic [15:0]             dbg_rd_latency_max,
  output logic [7:0]              dbg_sticky,

  // ------------------------------------------------------------ ILA probe
  output logic [ILA_W-1:0]        o_ila_probe
);

  localparam int unsigned DESC_W  = $bits(descriptor_t);          // 28
  localparam int unsigned OUTST_W = $clog2(MAX_OUTSTANDING+1);    // 2

  // ------------------------------------------------ request FIFO packing
  localparam int RQ_IS_READ = 0;
  localparam int RQ_EV      = RQ_IS_READ + 1;
  localparam int RQ_USEDESC = RQ_EV      + 3;
  localparam int RQ_DESC    = RQ_USEDESC + 1;
  localparam int RQ_ADDR    = RQ_DESC    + DESC_W;
  localparam int RQ_LEN     = RQ_ADDR    + AXI_ADDR_W;
  localparam int RQ_SIG     = RQ_LEN     + 8;
  localparam int RQ_SIGCHK  = RQ_SIG     + 32;
  localparam int REQ_W      = RQ_SIGCHK  + 1;

  // -------------------------------------------------- event FIFO packing
  localparam int EV_A_VALID = 0;
  localparam int EV_A_CODE  = EV_A_VALID + 1;
  localparam int EV_A_DESC  = EV_A_CODE  + 3;
  localparam int EV_R_VALID = EV_A_DESC  + DESC_W;
  localparam int EV_R_FIRST = EV_R_VALID + 1;
  localparam int EV_R_LAST  = EV_R_FIRST + 1;
  localparam int EV_R_RESP  = EV_R_LAST  + 1;
  localparam int EV_R_DESC  = EV_R_RESP  + 2;
  localparam int EVT_W      = EV_R_DESC  + DESC_W;

  // ---------------------------------------------------------- ILA packing
  localparam int ILA_REFCNT   = 0;     // 8
  localparam int ILA_RSV      = 8;     // 8
  localparam int ILA_INF      = 16;    // 6
  localparam int ILA_FILL     = 22;    // 4
  localparam int ILA_GEN      = 26;    // 8
  localparam int ILA_EGEN     = 34;    // 8
  localparam int ILA_SLOT     = 42;    // 6
  localparam int ILA_PHYS     = 48;    // 6
  localparam int ILA_TAG      = 54;    // 4
  localparam int ILA_ARVALID  = 58;
  localparam int ILA_ARREADY  = 59;
  localparam int ILA_RVALID   = 60;
  localparam int ILA_RREADY   = 61;
  localparam int ILA_RLAST    = 62;
  localparam int ILA_RRESP    = 63;    // 2
  localparam int ILA_REUSEREQ = 65;
  localparam int ILA_REUSEGNT = 66;
  localparam int ILA_REUSEREF = 67;
  localparam int ILA_UNSAFE   = 68;
  localparam int ILA_STALE    = 69;
  localparam int ILA_PAYMM    = 70;
  localparam int ILA_NOGEN    = 71;
  localparam int ILA_WINOK    = 72;
  localparam int ILA_WINREF   = 73;
  localparam int ILA_EVICT    = 74;
  localparam int ILA_EVCODE   = 75;    // 3
  localparam int ILA_OUTST    = 78;    // 2
  localparam int ILA_C_REF    = 80;    // 16
  localparam int ILA_C_STALE  = 96;    // 16
  localparam int ILA_C_UNSAFE = 112;   // 16
  localparam int ILA_C_PAY    = 128;   // 16
  // DIAGNOSTIC FIELDS, bits 144.. (previously unused; ILA_W stays 196).
  // Without these the probe cannot distinguish "held in reset" from "running
  // and idle": every state bit reads 0 in both cases. That ambiguity cost a
  // long hardware bring-up.
  //   ILA_RESETN    the actual rst_n seen by the guard
  //   ILA_HEARTBEAT free-running counter. Incrementing => clock AND reset live.
  //                 Frozen => the guard is in reset. One glance, no inference.
  localparam int ILA_RESETN    = 144;  // 1
  localparam int ILA_HEARTBEAT = 145;  // 16
  localparam int ILA_C_AXIERR = 144;   // 16
  localparam int ILA_C_WINREF = 160;   // 16
  localparam int ILA_C_COMP   = 176;   // 16
  localparam int ILA_TENANT   = 192;   // 4, cross-tenant reuse is an err_e code
  localparam int ILA_USED     = 196;

  // =========================================================== control net
  wire                    ctrl_start;
  wire                    ctrl_srst_req;
  wire                    ctrl_unsafe;
  wire                    ctrl_nogen;
  wire                    ctrl_evten;
  wire [AXI_ADDR_W-1:0]   win_base, win_limit;
  wire                    win_locked, win_valid;

  // ---------------------------------------------------------- soft reset
  logic       srst_pend;
  logic [4:0] srst_cnt;
  wire        rdm_idle;
  wire        core_rst_n   = rst_n & (srst_cnt == 5'd0);
  wire        srst_active  = srst_pend | (srst_cnt != 5'd0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      srst_pend <= 1'b0;
      srst_cnt  <= 5'd0;
    end else begin
      if (srst_cnt != 5'd0) srst_cnt <= srst_cnt - 5'd1;
      if (ctrl_srst_req) begin
        srst_pend <= 1'b1;
      end else if (srst_pend && rdm_idle && (srst_cnt == 5'd0)) begin
        srst_pend <= 1'b0;
        srst_cnt  <= 5'd16;          // hold the datapath reset 16 cycles
      end
    end
  end

  // ======================================================= register block
  wire                    rg_req_valid;
  wire                    rg_req_is_read;
  wire [2:0]              rg_req_ev;
  wire                    rg_req_use_desc;
  descriptor_t            rg_req_desc;
  wire [AXI_ADDR_W-1:0]   rg_req_addr;
  wire [7:0]              rg_req_len;
  wire [31:0]             rg_req_sig;
  wire                    rg_req_sig_check;
  wire                    rg_reuse_req;
  wire [SLOT_W-1:0]       rg_reuse_slot;
  wire [PHYS_W-1:0]       rg_reuse_phys;
  wire [TENANT_W-1:0]     rg_reuse_tenant;

  // ============================================================== FIFOs
  wire               req_full, req_empty;
  wire [REQ_W-1:0]   req_q;
  wire               req_pop;
  wire [REQ_W-1:0]   req_d;

  assign req_d[RQ_IS_READ]              = rg_req_is_read;
  assign req_d[RQ_EV      +: 3]         = rg_req_ev;
  assign req_d[RQ_USEDESC]              = rg_req_use_desc;
  assign req_d[RQ_DESC    +: DESC_W]    = rg_req_desc;
  assign req_d[RQ_ADDR +: AXI_ADDR_W]   = rg_req_addr;
  assign req_d[RQ_LEN     +: 8]         = rg_req_len;
  assign req_d[RQ_SIG     +: 32]        = rg_req_sig;
  assign req_d[RQ_SIGCHK]               = rg_req_sig_check;

  wire         rq_is_read = req_q[RQ_IS_READ];
  wire [2:0]   rq_ev      = req_q[RQ_EV      +: 3];
  wire         rq_usedesc = req_q[RQ_USEDESC];
  descriptor_t rq_desc;
  assign       rq_desc    = req_q[RQ_DESC    +: DESC_W];
  wire [AXI_ADDR_W-1:0] rq_addr = req_q[RQ_ADDR +: AXI_ADDR_W];
  wire [7:0]   rq_len     = req_q[RQ_LEN     +: 8];
  wire [31:0]  rq_sig     = req_q[RQ_SIG     +: 32];
  wire         rq_sigchk  = req_q[RQ_SIGCHK];

  guard_sync_fifo #(.W(REQ_W), .DEPTH(REQ_FIFO_DEPTH)) u_req_fifo (
    .clk    (clk),
    .rst_n  (core_rst_n),
    .i_push (rg_req_valid & core_rst_n),
    .i_data (req_d),
    .o_full (req_full),
    .i_pop  (req_pop),
    .o_data (req_q),
    .o_empty(req_empty)
  );

  // =================================================== read manager wiring
  wire                    rdm_req_ready;
  wire                    rdm_tt_accept;
  descriptor_t            rdm_tt_accept_desc;
  wire                    rdm_tt_complete;
  wire [TAG_W-1:0]        rdm_tt_complete_tag;
  wire                    rdm_evt_a_valid;
  wire [2:0]              rdm_evt_a_code;
  descriptor_t            rdm_evt_a_desc;
  wire                    rdm_evt_r_valid;
  wire                    rdm_evt_r_first;
  wire                    rdm_evt_r_last;
  wire [1:0]              rdm_evt_r_resp;
  descriptor_t            rdm_evt_r_desc;
  wire                    rdm_busy;
  wire                    p_window_refused, p_boundary_refused;
  wire                    p_align_refused,  p_tag_conflict;
  wire                    p_axi_err,        p_payload_mismatch;
  wire [1:0]              rdm_last_rresp;
  wire [AXI_ADDR_W-1:0]   rdm_last_araddr;
  wire [31:0]             c_dispatch, c_accept, c_first_data, c_complete;
  wire [31:0]             c_axi_err, c_payload_mismatch;
  wire [31:0]             c_window_refused, c_boundary_refused;
  wire [31:0]             c_align_refused, c_tag_conflict;

  wire                    tt_accept_ready;
  wire [OUTST_W-1:0]      tt_outstanding;

  // Only read dispatches leave once start is set. Lifecycle bookkeeping is
  // free to run before start so a slot can be set up first.
  wire rd_req_valid = ~req_empty &  rq_is_read & ctrl_start;

  axi_read_manager #(
    .AXI_ADDR_W      (AXI_ADDR_W),
    .AXI_DATA_W      (AXI_DATA_W),
    .MAX_OUTSTANDING (MAX_OUTSTANDING),
    .MAX_WINDOW_LOG2 (MAX_WINDOW_LOG2)
  ) u_rdm (
    .clk                    (clk),
    .rst_n                  (core_rst_n),
    .i_win_base             (win_base),
    .i_win_limit            (win_limit),
    .o_win_valid            (win_valid),
    .i_req_valid            (rd_req_valid),
    .o_req_ready            (rdm_req_ready),
    .i_req_desc             (rq_desc),
    .i_req_addr             (rq_addr),
    .i_req_len              (rq_len),
    .i_req_sig              (rq_sig),
    .i_req_sig_check        (rq_sigchk),
    .o_tt_accept            (rdm_tt_accept),
    .o_tt_accept_desc       (rdm_tt_accept_desc),
    .o_tt_complete          (rdm_tt_complete),
    .o_tt_complete_tag      (rdm_tt_complete_tag),
    .i_tt_accept_ready      (tt_accept_ready),
    .m_axi_arid             (m_axi_arid),
    .m_axi_araddr           (m_axi_araddr),
    .m_axi_arlen            (m_axi_arlen),
    .m_axi_arsize           (m_axi_arsize),
    .m_axi_arburst          (m_axi_arburst),
    .m_axi_arlock           (m_axi_arlock),
    .m_axi_arcache          (m_axi_arcache),
    .m_axi_arprot           (m_axi_arprot),
    .m_axi_arqos            (m_axi_arqos),
    .m_axi_arvalid          (m_axi_arvalid),
    .m_axi_arready          (m_axi_arready),
    .m_axi_rid              (m_axi_rid),
    .m_axi_rdata            (m_axi_rdata),
    .m_axi_rresp            (m_axi_rresp),
    .m_axi_rlast            (m_axi_rlast),
    .m_axi_rvalid           (m_axi_rvalid),
    .m_axi_rready           (m_axi_rready),
    .o_evt_a_valid          (rdm_evt_a_valid),
    .o_evt_a_code           (rdm_evt_a_code),
    .o_evt_a_desc           (rdm_evt_a_desc),
    .o_evt_r_valid          (rdm_evt_r_valid),
    .o_evt_r_first          (rdm_evt_r_first),
    .o_evt_r_last           (rdm_evt_r_last),
    .o_evt_r_resp           (rdm_evt_r_resp),
    .o_evt_r_desc           (rdm_evt_r_desc),
    .o_idle                 (rdm_idle),
    .o_busy                 (rdm_busy),
    .o_p_window_refused     (p_window_refused),
    .o_p_boundary_refused   (p_boundary_refused),
    .o_p_align_refused      (p_align_refused),
    .o_p_tag_conflict       (p_tag_conflict),
    .o_p_axi_err            (p_axi_err),
    .o_p_payload_mismatch   (p_payload_mismatch),
    .o_last_rresp           (rdm_last_rresp),
    .o_last_araddr          (rdm_last_araddr),
    .o_cnt_dispatch         (c_dispatch),
    .o_cnt_accept           (c_accept),
    .o_cnt_first_data       (c_first_data),
    .o_cnt_complete         (c_complete),
    .o_cnt_axi_err          (c_axi_err),
    .o_cnt_payload_mismatch (c_payload_mismatch),
    .o_cnt_window_refused   (c_window_refused),
    .o_cnt_boundary_refused (c_boundary_refused),
    .o_cnt_align_refused    (c_align_refused),
    .o_cnt_tag_conflict     (c_tag_conflict)
  );

  // ============================================================ tag_tracker
  wire            tt_lookup_valid;
  descriptor_t    tt_lookup_desc;
  wire            tt_err_valid;
  err_e           tt_err;

  tag_tracker #(
    .MAX_OUTSTANDING (MAX_OUTSTANDING)
  ) u_tags (
    .clk            (clk),
    .rst_n          (core_rst_n),
    .i_accept       (rdm_tt_accept),
    .i_accept_desc  (rdm_tt_accept_desc),
    .i_complete     (rdm_tt_complete),
    .i_complete_tag (rdm_tt_complete_tag),
    .i_cancel       (1'b0),
    .i_cancel_tag   ('0),
    .o_lookup_valid (tt_lookup_valid),
    .o_lookup_desc  (tt_lookup_desc),
    .o_err_valid    (tt_err_valid),
    .o_err          (tt_err),
    .o_outstanding  (tt_outstanding),
    .o_accept_ready (tt_accept_ready)
  );

  // ========================================================= page_state_lut
  // Command arbitration. A completion lookup is a one-cycle pulse out of
  // tag_tracker and cannot be stalled, so it always wins. Host commands wait
  // one cycle. Completions are bounded by MAX_OUTSTANDING so they cannot
  // starve the host.
  lc_cmd_t            lut_cmd;
  logic [SLOT_W-1:0]  lut_slot;
  lc_rsp_t            lut_rsp;
  wire                lut_reuse_grant, lut_reuse_refused;
  wire [GEN_W-1:0]    lut_reuse_new_gen;
  wire                lut_unsafe_blocked, lut_unsafe_committed;
  wire                lut_stale;
  wire [31:0]         c_reuse_refused, c_stale, c_unsafe_commit;

  wire lc_req_valid = ~req_empty & ~rq_is_read;
  wire lc_req_ready = ~tt_lookup_valid;

  assign req_pop = rq_is_read ? (rd_req_valid & rdm_req_ready)
                              : (lc_req_valid & lc_req_ready);

  always_comb begin
    lut_cmd  = '0;
    lut_slot = '0;
    if (tt_lookup_valid) begin
      lut_cmd.valid    = 1'b1;
      lut_cmd.ev       = LC_COMPLETE;
      lut_cmd.desc     = tt_lookup_desc;
      // A completion ALWAYS resolves through its descriptor. Whether that
      // resolution carries a generation is page_state_lut's decision, taken
      // from i_no_generation_check. Safe mode rejects the stale completion
      // by generation; naive mode accepts it on slot + frame identity, and
      // only naive mode combined with unsafe_bypass clobbers a payload.
      lut_cmd.use_desc = 1'b1;
      lut_slot         = tt_lookup_desc.lifecycle_slot;
    end else if (lc_req_valid) begin
      lut_cmd.valid    = 1'b1;
      lut_cmd.ev       = lc_event_e'(rq_ev);
      lut_cmd.desc     = rq_desc;
      lut_cmd.use_desc = rq_usedesc;
      lut_slot         = rq_desc.lifecycle_slot;
    end
  end

  wire lut_reuse_req = rg_reuse_req & core_rst_n;

  page_state_lut #(
    .UNSAFE_BYPASS_SUPPORTED (1),
    .NAIVE_NO_GEN_SUPPORTED  (1)
  ) u_lut (
    .clk                      (clk),
    .rst_n                    (core_rst_n),
    .i_unsafe_bypass          (ctrl_unsafe),
    .i_no_generation_check    (ctrl_nogen),
    .i_cmd                    (lut_cmd),
    .i_slot                   (lut_slot),
    .i_reuse_req              (lut_reuse_req),
    .i_reuse_slot             (rg_reuse_slot),
    .i_reuse_phys             (rg_reuse_phys),
    .i_reuse_tenant           (rg_reuse_tenant),
    .o_rsp                    (lut_rsp),
    .o_reuse_grant            (lut_reuse_grant),
    .o_reuse_refused          (lut_reuse_refused),
    .o_reuse_new_gen          (lut_reuse_new_gen),
    .o_unsafe_reuse_blocked   (lut_unsafe_blocked),
    .o_unsafe_reuse_committed (lut_unsafe_committed),
    .o_stale_descriptor       (lut_stale),
    .o_cnt_refused            (c_reuse_refused),
    .o_cnt_stale              (c_stale),
    .o_cnt_unsafe_commit      (c_unsafe_commit)
  );

  // ============================================================ event FIFO
  wire [EVT_W-1:0] evt_d;
  wire [EVT_W-1:0] evt_q;
  wire             evt_full, evt_empty;

  assign evt_d[EV_A_VALID]           = rdm_evt_a_valid;
  assign evt_d[EV_A_CODE  +: 3]      = rdm_evt_a_code;
  assign evt_d[EV_A_DESC  +: DESC_W] = rdm_evt_a_desc;
  assign evt_d[EV_R_VALID]           = rdm_evt_r_valid;
  assign evt_d[EV_R_FIRST]           = rdm_evt_r_first;
  assign evt_d[EV_R_LAST]            = rdm_evt_r_last;
  assign evt_d[EV_R_RESP  +: 2]      = rdm_evt_r_resp;
  assign evt_d[EV_R_DESC  +: DESC_W] = rdm_evt_r_desc;

  wire evt_push_req = (rdm_evt_a_valid | rdm_evt_r_valid) & ctrl_evten;
  wire evt_push     = evt_push_req & ~evt_full;
  wire evt_drop     = evt_push_req &  evt_full;
  wire evt_pop      = ~evt_empty;

  guard_sync_fifo #(.W(EVT_W), .DEPTH(EVT_FIFO_DEPTH)) u_evt_fifo (
    .clk    (clk),
    .rst_n  (core_rst_n),
    .i_push (evt_push),
    .i_data (evt_d),
    .o_full (evt_full),
    .i_pop  (evt_pop),
    .o_data (evt_q),
    .o_empty(evt_empty)
  );

  wire         eq_a_valid = evt_q[EV_A_VALID];
  wire [2:0]   eq_a_code  = evt_q[EV_A_CODE +: 3];
  descriptor_t eq_a_desc;
  assign       eq_a_desc  = evt_q[EV_A_DESC +: DESC_W];
  wire         eq_r_valid = evt_q[EV_R_VALID];
  wire         eq_r_last  = evt_q[EV_R_LAST];
  descriptor_t eq_r_desc;
  assign       eq_r_desc  = evt_q[EV_R_DESC +: DESC_W];

  // ============================================== top-level counters/views
  logic [31:0]  c_evt_drop, c_lc_err, c_reuse_grant, evt_count;
  logic [2:0]   evt_last_code;
  descriptor_t  evt_last_desc;
  descriptor_t  lc_view_desc;
  logic         p_lc_err;

  always_ff @(posedge clk) begin
    if (!core_rst_n) begin
      c_evt_drop    <= '0;
      c_lc_err      <= '0;
      c_reuse_grant <= '0;
      evt_count     <= '0;
      evt_last_code <= 3'd0;
      evt_last_desc <= '0;
      lc_view_desc  <= '0;
      p_lc_err      <= 1'b0;
    end else begin
      p_lc_err <= lut_rsp.valid & ~lut_rsp.ok;
      if (lut_rsp.valid && !lut_rsp.ok) c_lc_err <= c_lc_err + 32'd1;
      if (lut_reuse_grant)  c_reuse_grant <= c_reuse_grant + 32'd1;
      if (evt_drop)         c_evt_drop    <= c_evt_drop    + 32'd1;
      if (lut_cmd.valid)    lc_view_desc  <= lut_cmd.desc;

      if (evt_pop) begin
        evt_count <= evt_count + 32'd1;
        if (eq_r_valid) begin
          evt_last_code <= eq_r_last ? 3'(TXN_AXI_COMPLETE)
                                     : 3'(TXN_AXI_FIRST_DATA);
          evt_last_desc <= eq_r_desc;
        end else if (eq_a_valid) begin
          evt_last_code <= eq_a_code;
          evt_last_desc <= eq_a_desc;
        end
      end
    end
  end

  // ========================================================= AXI-Lite regs
  axi_lite_regs #(
    .C_ADDR_W   (C_ADDR_W),
    .AXI_ADDR_W (AXI_ADDR_W)
  ) u_regs (
    .clk   (clk),
    .rst_n (rst_n),

    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awprot  (s_axi_awprot),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arprot  (s_axi_arprot),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),

    .o_start          (ctrl_start),
    .o_soft_reset_req (ctrl_srst_req),
    .o_unsafe_bypass  (ctrl_unsafe),
    .o_no_gen_check   (ctrl_nogen),
    .o_evt_capture_en (ctrl_evten),
    .o_scratch_base   (win_base),
    .o_scratch_limit  (win_limit),
    .o_window_locked  (win_locked),

    .o_req_valid      (rg_req_valid),
    .i_req_ready      (~req_full),
    .o_req_is_read    (rg_req_is_read),
    .o_req_ev         (rg_req_ev),
    .o_req_use_desc   (rg_req_use_desc),
    .o_req_desc       (rg_req_desc),
    .o_req_addr       (rg_req_addr),
    .o_req_len        (rg_req_len),
    .o_req_sig        (rg_req_sig),
    .o_req_sig_check  (rg_req_sig_check),

    .o_reuse_req      (rg_reuse_req),
    .o_reuse_slot     (rg_reuse_slot),
    .o_reuse_phys     (rg_reuse_phys),
    .o_reuse_tenant   (rg_reuse_tenant),

    .i_core_idle          (rdm_idle & req_empty),
    .i_core_busy          (rdm_busy),
    .i_soft_reset_active  (srst_active),
    .i_window_valid       (win_valid),
    .i_outstanding        ({{(8-OUTST_W){1'b0}}, tt_outstanding}),
    .i_req_fifo_full      (req_full),
    .i_req_fifo_empty     (req_empty),
    .i_evt_fifo_full      (evt_full),
    .i_evt_fifo_empty     (evt_empty),

    .i_p_window_refused   (p_window_refused),
    .i_p_boundary_refused (p_boundary_refused),
    .i_p_align_refused    (p_align_refused),
    .i_p_tag_conflict     (p_tag_conflict),
    .i_p_axi_err          (p_axi_err),
    .i_p_payload_mismatch (p_payload_mismatch),
    .i_p_stale_desc       (lut_stale),
    .i_p_unsafe_commit    (lut_unsafe_committed),
    .i_p_reuse_refused    (lut_reuse_refused),
    .i_p_reuse_grant      (lut_reuse_grant),
    .i_p_lc_err           (p_lc_err),
    .i_p_evt_drop         (evt_drop),

    .i_cnt_reuse_refused    (c_reuse_refused),
    .i_cnt_stale            (c_stale),
    .i_cnt_unsafe_commit    (c_unsafe_commit),
    .i_cnt_payload_mismatch (c_payload_mismatch),
    .i_cnt_axi_err          (c_axi_err),
    .i_cnt_complete         (c_complete),
    .i_cnt_window_refused   (c_window_refused),
    .i_cnt_boundary_refused (c_boundary_refused),
    .i_cnt_align_refused    (c_align_refused),
    .i_cnt_tag_conflict     (c_tag_conflict),
    .i_cnt_dispatch         (c_dispatch),
    .i_cnt_accept           (c_accept),
    .i_cnt_first_data       (c_first_data),
    .i_cnt_evt_drop         (c_evt_drop),
    .i_cnt_lc_err           (c_lc_err),
    .i_cnt_reuse_grant      (c_reuse_grant),

    .i_reuse_new_gen  (lut_reuse_new_gen),
    .i_evt_code       (evt_last_code),
    .i_evt_desc       (evt_last_desc),
    .i_evt_count      (evt_count),
    .i_lc_entry       (lut_rsp.entry),
    .i_lc_ok          (lut_rsp.ok),
    .i_lc_err         (lut_rsp.err),
    .i_lc_evictable   (lut_rsp.evictable),
    .i_last_rresp     (rdm_last_rresp),
    .i_last_araddr    (rdm_last_araddr)
  );


  // =================================================== debug instrumentation
  // Free-running, deliberately NOT reset. A frozen value proves the clock
  // stopped; a counting value with dbg_rstn low proves reset is the fault and
  // not the clock. This single field removes the ambiguity that makes every
  // other state bit read zero in both conditions.
  logic [15:0] hb_cnt;
  always_ff @(posedge clk) hb_cnt <= hb_cnt + 16'd1;

  // AR backpressure: cycles arvalid is asserted before arready. Simulation
  // uses a model of the interconnect; this measures the real one.
  logic [15:0] ar_wait_q;
  always_ff @(posedge clk) begin
    if (!rst_n)                            ar_wait_q <= '0;
    else if (m_axi_arvalid & ~m_axi_arready) ar_wait_q <= ar_wait_q + 16'd1;
    else if (m_axi_arvalid &  m_axi_arready) ar_wait_q <= '0;
  end

  // Real DDR read latency: AR handshake to RLAST, in cycles. Held after RLAST
  // so it can be read back, plus a running maximum for worst-case evidence.
  logic [15:0] rd_lat_q, rd_lat_hold_q, rd_lat_max_q;
  logic        rd_busy_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_lat_q <= '0; rd_lat_hold_q <= '0; rd_lat_max_q <= '0; rd_busy_q <= 1'b0;
    end else begin
      if (m_axi_arvalid & m_axi_arready) begin
        rd_busy_q <= 1'b1; rd_lat_q <= '0;
      end else if (rd_busy_q) begin
        rd_lat_q <= rd_lat_q + 16'd1;
        if (m_axi_rvalid & m_axi_rready & m_axi_rlast) begin
          rd_busy_q     <= 1'b0;
          rd_lat_hold_q <= rd_lat_q;
          if (rd_lat_q > rd_lat_max_q) rd_lat_max_q <= rd_lat_q;
        end
      end
    end
  end

  // Sticky flags for rare events. An intermittent fault that happens once
  // between two captures would otherwise be invisible; these latch until reset.
  logic [7:0] sticky_q;
  always_ff @(posedge clk) begin
    if (!rst_n) sticky_q <= '0;
    else begin
      if (lut_reuse_refused)                    sticky_q[0] <= 1'b1;
      if (lut_stale)                            sticky_q[1] <= 1'b1;
      if (p_payload_mismatch)                   sticky_q[2] <= 1'b1;
      if (p_window_refused)                     sticky_q[3] <= 1'b1;
      if (m_axi_rvalid & m_axi_rready &
          (m_axi_rresp != 2'b00))               sticky_q[4] <= 1'b1;
      // the violation trap: a grant while the predicate is not satisfied
      if (lut_reuse_grant &&
          ((lut_rsp.entry.refcount    != '0) ||
           (lut_rsp.entry.reservation != '0) ||
           (lut_rsp.entry.inflight    != '0) ||
           (lut_rsp.entry.fill_pending!= '0))) sticky_q[7] <= 1'b1;
    end
  end

  always_comb begin
    dbg_rstn           = rst_n;
    dbg_heartbeat      = hb_cnt;
    dbg_refcount       = 8'(lut_rsp.entry.refcount);
    dbg_reservation    = 8'(lut_rsp.entry.reservation);
    dbg_inflight       = 6'(lut_rsp.entry.inflight);
    dbg_fill_pending   = 4'(lut_rsp.entry.fill_pending);
    dbg_generation     = 8'(lut_rsp.entry.generation);
    dbg_exp_generation = 8'(lc_view_desc.expected_generation);
    dbg_slot           = 6'(lc_view_desc.lifecycle_slot);
    dbg_phys           = 6'(lc_view_desc.phys_idx);
    dbg_reuse_req      = lut_reuse_req;
    dbg_reuse_grant    = lut_reuse_grant;
    dbg_reuse_refused  = lut_reuse_refused;
    dbg_stale          = lut_stale;
    dbg_payload_mm     = p_payload_mismatch;
    dbg_evictable      = lut_rsp.evictable;
    dbg_outstanding    = tt_outstanding[1:0];
    dbg_ar_wait        = ar_wait_q;
    dbg_rd_latency     = rd_lat_hold_q;
    dbg_rd_latency_max = rd_lat_max_q;
    dbg_sticky         = sticky_q;
  end

  // ============================================================ ILA probe
  always_comb begin
    o_ila_probe = '0;
    o_ila_probe[ILA_REFCNT +: REF_W]  = lut_rsp.entry.refcount;
    o_ila_probe[ILA_RSV    +: RSV_W]  = lut_rsp.entry.reservation;
    o_ila_probe[ILA_INF    +: INF_W]  = lut_rsp.entry.inflight;
    o_ila_probe[ILA_FILL   +: FILL_W] = lut_rsp.entry.fill_pending;
    o_ila_probe[ILA_GEN    +: GEN_W]  = lut_rsp.entry.generation;
    o_ila_probe[ILA_EGEN   +: GEN_W]  = lc_view_desc.expected_generation;
    o_ila_probe[ILA_SLOT   +: SLOT_W] = lc_view_desc.lifecycle_slot;
    o_ila_probe[ILA_PHYS   +: PHYS_W] = lc_view_desc.phys_idx;
    o_ila_probe[ILA_TAG    +: TAG_W]  = lc_view_desc.transaction_tag;
    o_ila_probe[ILA_ARVALID]          = m_axi_arvalid;
    o_ila_probe[ILA_ARREADY]          = m_axi_arready;
    o_ila_probe[ILA_RVALID]           = m_axi_rvalid;
    o_ila_probe[ILA_RREADY]           = m_axi_rready;
    o_ila_probe[ILA_RLAST]            = m_axi_rlast;
    o_ila_probe[ILA_RRESP  +: 2]      = m_axi_rresp;
    o_ila_probe[ILA_REUSEREQ]         = lut_reuse_req;
    o_ila_probe[ILA_REUSEGNT]         = lut_reuse_grant;
    o_ila_probe[ILA_REUSEREF]         = lut_reuse_refused;
    o_ila_probe[ILA_UNSAFE]           = ctrl_unsafe;
    o_ila_probe[ILA_STALE]            = lut_stale;
    o_ila_probe[ILA_PAYMM]            = p_payload_mismatch;
    o_ila_probe[ILA_NOGEN]            = ctrl_nogen;
    o_ila_probe[ILA_WINOK]            = win_valid;
    o_ila_probe[ILA_WINREF]           = p_window_refused;
    o_ila_probe[ILA_EVICT]            = lut_rsp.evictable;
    o_ila_probe[ILA_EVCODE +: 3]      = evt_last_code;
    o_ila_probe[ILA_OUTST  +: 2]      = tt_outstanding[1:0];
    o_ila_probe[ILA_C_REF    +: 16]   = c_reuse_refused[15:0];
    o_ila_probe[ILA_C_STALE  +: 16]   = c_stale[15:0];
    o_ila_probe[ILA_C_UNSAFE +: 16]   = c_unsafe_commit[15:0];
    o_ila_probe[ILA_C_PAY    +: 16]   = c_payload_mismatch[15:0];
    o_ila_probe[ILA_RESETN]           = rst_n;
    o_ila_probe[ILA_HEARTBEAT +: 16]  = hb_cnt;
    o_ila_probe[ILA_C_AXIERR +: 16]   = c_axi_err[15:0];
    o_ila_probe[ILA_C_WINREF +: 16]   = c_window_refused[15:0];
    o_ila_probe[ILA_C_COMP   +: 16]   = c_complete[15:0];
    o_ila_probe[ILA_TENANT +: TENANT_W] = lc_view_desc.tenant;
  end

`ifndef SYNTHESIS
  initial begin
    if (ILA_USED > ILA_W)
      $error("ILA probe bus too narrow: need %0d, have %0d", ILA_USED, ILA_W);
    if ((REQ_FIFO_DEPTH & (REQ_FIFO_DEPTH-1)) != 0)
      $error("REQ_FIFO_DEPTH must be a power of two");
    if ((EVT_FIFO_DEPTH & (EVT_FIFO_DEPTH-1)) != 0)
      $error("EVT_FIFO_DEPTH must be a power of two");
  end
`endif

endmodule


// ---------------------------------------------------------------------------
// guard_sync_fifo
// Bounded single-clock FIFO, first-word-fall-through. DEPTH must be a power
// of two. The storage array is deliberately not reset so it can infer LUTRAM
// or BRAM; only the pointers are reset, which is what makes the FIFO empty.
// ---------------------------------------------------------------------------
module guard_sync_fifo #(
  parameter int unsigned W     = 32,
  parameter int unsigned DEPTH = 8
)(
  input  wire          clk,
  input  wire          rst_n,
  input  wire          i_push,
  input  wire [W-1:0]  i_data,
  output wire          o_full,
  input  wire          i_pop,
  output wire [W-1:0]  o_data,
  output wire          o_empty
);
  localparam int unsigned AW = $clog2(DEPTH);

  logic [W-1:0] mem [DEPTH];
  logic [AW:0]  wptr, rptr;

  assign o_empty = (wptr == rptr);
  assign o_full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
  assign o_data  = mem[rptr[AW-1:0]];

  wire do_push = i_push & ~o_full;
  wire do_pop  = i_pop  & ~o_empty;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr <= '0;
      rptr <= '0;
    end else begin
      if (do_push) wptr <= wptr + 1'b1;
      if (do_pop)  rptr <= rptr + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (do_push) mem[wptr[AW-1:0]] <= i_data;
  end
endmodule
