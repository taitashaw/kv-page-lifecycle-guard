// axi_lite_regs.sv
// AXI4-Lite control plane for the lifecycle-safety artifact (V1).
//
// 32-bit data, 4 KiB aperture, 64 defined 32-bit registers at 0x00..0xFC.
//
// HANDSHAKE RULE HELD HERE: AWREADY, WREADY and ARREADY are functions of
// FLIP-FLOP STATE ONLY. There is no combinational path from AWVALID to
// AWREADY, from WVALID to WREADY, or from ARVALID to ARREADY.
//
// SAFETY: this block owns the scratch-window base/limit pair. It does NOT
// own the gate. The gate lives in axi_read_manager, which has no bypass
// input of any kind, so no control bit written here can widen the window.
// WINDOW_LOCK makes base/limit read-only until the next hard reset.
//
// Register map (word index = addr[7:2]):
//   0x00 ID                   RO   magic
//   0x04 VERSION              RO
//   0x08 CTRL                 RW   b0 start, b1 soft_reset (one-shot),
//                                  b2 unsafe_bypass, b3 no_generation_check,
//                                  b4 sig_check_en, b5 evt_capture_en
//
//        b2 and b3 are the TWO INDEPENDENT unsafe modes of page_state_lut.
//        b2 removes the evictable interlock; b3 removes generation tagging.
//        Neither can widen the AXI address window: that gate lives in
//        axi_read_manager, which has no bypass input at all.
//   0x0C STATUS               RO   see ST_* localparams
//   0x10 STATUS_CLR           W1C  write 1 to clear the matching sticky bit
//   0x14 SCRATCH_BASE_LO      RW
//   0x18 SCRATCH_BASE_HI      RW
//   0x1C SCRATCH_LIMIT_LO     RW   exclusive upper bound
//   0x20 SCRATCH_LIMIT_HI     RW
//   0x24 WINDOW_LOCK          RW   write LOCK_MAGIC to freeze base/limit
//   0x28 WINDOW_INFO          RO   b0 locked, b1 window_valid
//   0x2C reserved
//   0x30 CMD_DESC             RW   [5:0] slot [13:8] phys [23:16] exp_gen
//                                  [27:24] tag [31:28] tenant
//   0x34 CMD_CFG              RW   [2:0] lc event, [3] use_desc, [4] is_read,
//                                  [5] sig_check, [15:8] arlen
//   0x38 CMD_ADDR_LO          RW
//   0x3C CMD_ADDR_HI          RW
//   0x40 CMD_SIG              RW   expected first-beat signature
//   0x44 CMD_GO               WO   b0 -> push one request
//   0x48 reserved
//   0x4C reserved
//   0x50 REUSE_CFG            RW   [5:0] slot [13:8] phys [19:16] tenant
//   0x54 REUSE_GO             WO   b0 -> one reuse-request pulse
//   0x58 REUSE_STATUS         RO   b0 grant, b1 refused, [15:8] new generation
//   0x5C reserved
//   0x60 CNT_REUSE_REFUSED    RO
//   0x64 CNT_STALE_DESC       RO
//   0x68 CNT_UNSAFE_COMMIT    RO
//   0x6C CNT_PAYLOAD_MISMATCH RO
//   0x70 CNT_AXI_ERR          RO
//   0x74 CNT_COMPLETE         RO
//   0x78 CNT_WINDOW_REFUSED   RO
//   0x7C CNT_BOUNDARY_REFUSED RO
//   0x80 CNT_ALIGN_REFUSED    RO
//   0x84 CNT_TAG_CONFLICT     RO
//   0x88 CNT_DISPATCH         RO
//   0x8C CNT_ACCEPT           RO
//   0x90 CNT_FIRST_DATA       RO
//   0x94 CNT_REQ_DROP         RO
//   0x98 CNT_EVT_DROP         RO
//   0x9C CNT_LC_ERR           RO
//   0xA0 CNT_REUSE_GRANT      RO
//   0xA4 CNT_ILLEGAL_ACCESS   RO
//   0xA8 EVT_LAST             RO
//   0xAC EVT_COUNT            RO
//   0xB0 LC_ENTRY0            RO
//   0xB4 LC_ENTRY1            RO
//   0xB8 AXI_LAST             RO
//   0xBC OUTSTANDING          RO
//   0xC0 SCRATCH0             RW   software scratch, proves the register path
//   0xC4 SCRATCH1             RW
//   0xC8..0xFC reserved       RO   reads 0
//
// Every response is OKAY. A rejected access is reported through STATUS and
// CNT_ILLEGAL_ACCESS, never through SLVERR, because a SLVERR returned to a
// Linux userspace poke on this part surfaces as a synchronous external abort.

`include "lifecycle_pkg.sv"

module axi_lite_regs
  import lifecycle_pkg::*;
#(
  parameter int unsigned C_ADDR_W   = 12,
  parameter int unsigned AXI_ADDR_W = 40,
  parameter logic [31:0] ID_MAGIC   = 32'h4C47_5031,   // "LGP1"
  parameter logic [31:0] VERSION_ID = 32'h0001_0000,
  parameter logic [31:0] LOCK_MAGIC = 32'h5AFE_10C4
)(
  input  wire                    clk,
  input  wire                    rst_n,

  // ------------------------------------------------------ AXI4-Lite slave
  input  wire [C_ADDR_W-1:0]     s_axi_awaddr,
  input  wire [2:0]              s_axi_awprot,
  input  wire                    s_axi_awvalid,
  output wire                    s_axi_awready,
  input  wire [31:0]             s_axi_wdata,
  input  wire [3:0]              s_axi_wstrb,
  input  wire                    s_axi_wvalid,
  output wire                    s_axi_wready,
  output wire [1:0]              s_axi_bresp,
  output wire                    s_axi_bvalid,
  input  wire                    s_axi_bready,
  input  wire [C_ADDR_W-1:0]     s_axi_araddr,
  input  wire [2:0]              s_axi_arprot,
  input  wire                    s_axi_arvalid,
  output wire                    s_axi_arready,
  output wire [31:0]             s_axi_rdata,
  output wire [1:0]              s_axi_rresp,
  output wire                    s_axi_rvalid,
  input  wire                    s_axi_rready,

  // ---------------------------------------------------------- control out
  output wire                    o_start,
  output wire                    o_soft_reset_req,
  output wire                    o_unsafe_bypass,
  output wire                    o_no_gen_check,
  output wire                    o_evt_capture_en,

  // scratch window. The ONLY memory the AXI manager may ever touch.
  output wire [AXI_ADDR_W-1:0]   o_scratch_base,
  output wire [AXI_ADDR_W-1:0]   o_scratch_limit,
  output wire                    o_window_locked,

  // ----------------------------------------- command-issue window -> FIFO
  output logic                   o_req_valid,
  input  wire                    i_req_ready,
  output logic                   o_req_is_read,
  output logic [2:0]             o_req_ev,
  output logic                   o_req_use_desc,
  output descriptor_t            o_req_desc,
  output wire  [AXI_ADDR_W-1:0]  o_req_addr,
  output wire  [7:0]             o_req_len,
  output wire  [31:0]            o_req_sig,
  output wire                    o_req_sig_check,

  // ------------------------------------------------- reuse-request window
  output logic                   o_reuse_req,
  output wire [SLOT_W-1:0]       o_reuse_slot,
  output wire [PHYS_W-1:0]       o_reuse_phys,
  output wire [TENANT_W-1:0]     o_reuse_tenant,

  // ---------------------------------------------------- status / counters
  input  wire                    i_core_idle,
  input  wire                    i_core_busy,
  input  wire                    i_soft_reset_active,
  input  wire                    i_window_valid,
  input  wire [7:0]              i_outstanding,
  input  wire                    i_req_fifo_full,
  input  wire                    i_req_fifo_empty,
  input  wire                    i_evt_fifo_full,
  input  wire                    i_evt_fifo_empty,

  input  wire                    i_p_window_refused,
  input  wire                    i_p_boundary_refused,
  input  wire                    i_p_align_refused,
  input  wire                    i_p_tag_conflict,
  input  wire                    i_p_axi_err,
  input  wire                    i_p_payload_mismatch,
  input  wire                    i_p_stale_desc,
  input  wire                    i_p_unsafe_commit,
  input  wire                    i_p_reuse_refused,
  input  wire                    i_p_reuse_grant,
  input  wire                    i_p_lc_err,
  input  wire                    i_p_evt_drop,

  input  wire [31:0]             i_cnt_reuse_refused,
  input  wire [31:0]             i_cnt_stale,
  input  wire [31:0]             i_cnt_unsafe_commit,
  input  wire [31:0]             i_cnt_payload_mismatch,
  input  wire [31:0]             i_cnt_axi_err,
  input  wire [31:0]             i_cnt_complete,
  input  wire [31:0]             i_cnt_window_refused,
  input  wire [31:0]             i_cnt_boundary_refused,
  input  wire [31:0]             i_cnt_align_refused,
  input  wire [31:0]             i_cnt_tag_conflict,
  input  wire [31:0]             i_cnt_dispatch,
  input  wire [31:0]             i_cnt_accept,
  input  wire [31:0]             i_cnt_first_data,
  input  wire [31:0]             i_cnt_evt_drop,
  input  wire [31:0]             i_cnt_lc_err,
  input  wire [31:0]             i_cnt_reuse_grant,

  input  wire [GEN_W-1:0]        i_reuse_new_gen,
  input  wire [2:0]              i_evt_code,
  input  descriptor_t            i_evt_desc,
  input  wire [31:0]             i_evt_count,
  input  lc_entry_t              i_lc_entry,
  input  wire                    i_lc_ok,
  input  wire [3:0]              i_lc_err,
  input  wire                    i_lc_evictable,
  input  wire [1:0]              i_last_rresp,
  input  wire [AXI_ADDR_W-1:0]   i_last_araddr
);

  // ------------------------------------------------------ status bit index
  localparam int ST_IDLE        = 0;
  localparam int ST_BUSY        = 1;
  localparam int ST_REQ_FULL    = 2;
  localparam int ST_REQ_EMPTY   = 3;
  localparam int ST_EVT_FULL    = 4;
  localparam int ST_EVT_EMPTY   = 5;
  localparam int ST_S_REQ_DROP  = 6;
  localparam int ST_S_EVT_DROP  = 7;
  localparam int ST_S_WIN_REF   = 8;
  localparam int ST_S_BND_REF   = 9;
  localparam int ST_S_ALN_REF   = 10;
  localparam int ST_S_TAG_CONF  = 11;
  localparam int ST_S_AXI_ERR   = 12;
  localparam int ST_S_PAY_MM    = 13;
  localparam int ST_S_STALE     = 14;
  localparam int ST_S_UNSAFE    = 15;
  localparam int ST_S_REUSE_REF = 16;
  localparam int ST_S_LC_ERR    = 17;
  localparam int ST_WIN_LOCKED  = 18;
  localparam int ST_WIN_VALID   = 19;
  localparam int ST_SRST_ACT    = 20;

  // ============================================================== registers
  logic                  aw_pend, w_pend, b_pend;
  logic [C_ADDR_W-1:0]   aw_addr_q;
  logic [31:0]           w_data_q;
  logic [3:0]            w_strb_q;

  logic                  ar_pend, r_pend;
  logic [C_ADDR_W-1:0]   ar_addr_q;
  logic [31:0]           r_data_q;

  logic        ctrl_start, ctrl_srst, ctrl_unsafe, ctrl_nogen;
  logic        ctrl_sigchk, ctrl_evten;
  logic [31:0] base_lo, base_hi, limit_lo, limit_hi;
  logic        win_locked;
  logic [31:0] cmd_desc_r, cmd_cfg_r, cmd_addr_lo, cmd_addr_hi, cmd_sig_r;
  logic [31:0] reuse_cfg_r;
  logic [31:0] scratch0, scratch1;
  logic [31:0] sticky;                 // indexed by ST_S_*
  logic [31:0] cnt_req_drop, cnt_illegal;
  logic        grant_q, refused_q;
  logic [GEN_W-1:0] new_gen_q;

  logic [31:0] status_w;
  logic [31:0] rd_mux;

  // ================================================================ AXI-Lite
  // Address and data are captured independently; the register update commits
  // when both are held and the previous B response has been taken. Every
  // ready is a pure function of flops.
  assign s_axi_awready = ~aw_pend & ~b_pend;
  assign s_axi_wready  = ~w_pend  & ~b_pend;
  assign s_axi_bvalid  = b_pend;
  assign s_axi_bresp   = 2'b00;

  assign s_axi_arready = ~ar_pend & ~r_pend;
  assign s_axi_rvalid  = r_pend;
  assign s_axi_rdata   = r_data_q;
  assign s_axi_rresp   = 2'b00;

  wire aw_hs     = s_axi_awvalid & s_axi_awready;
  wire w_hs      = s_axi_wvalid  & s_axi_wready;
  wire wr_commit = aw_pend & w_pend & ~b_pend;
  wire ar_hs     = s_axi_arvalid & s_axi_arready;

  wire [5:0] wr_idx      = aw_addr_q[7:2];
  wire       wr_in_range = (aw_addr_q[C_ADDR_W-1:8] == '0);
  wire [5:0] rd_idx      = ar_addr_q[7:2];
  wire       rd_in_range = (ar_addr_q[C_ADDR_W-1:8] == '0);

  function automatic logic [31:0] bwrite(input logic [31:0] cur,
                                         input logic [31:0] nxt,
                                         input logic [3:0]  strb);
    bwrite = cur;
    if (strb[0]) bwrite[7:0]   = nxt[7:0];
    if (strb[1]) bwrite[15:8]  = nxt[15:8];
    if (strb[2]) bwrite[23:16] = nxt[23:16];
    if (strb[3]) bwrite[31:24] = nxt[31:24];
  endfunction

  wire cmd_go_wr   = wr_commit & wr_in_range & (wr_idx == 6'd17) &
                     w_strb_q[0] & w_data_q[0];
  wire reuse_go_wr = wr_commit & wr_in_range & (wr_idx == 6'd21) &
                     w_strb_q[0] & w_data_q[0];

  // A write is legal if it lands on a writable register inside the aperture.
  logic wr_legal;
  always_comb begin
    wr_legal = 1'b0;
    if (wr_in_range) begin
      case (wr_idx)
        6'd2, 6'd4, 6'd5, 6'd6, 6'd7, 6'd8, 6'd9,
        6'd12, 6'd13, 6'd14, 6'd15, 6'd16, 6'd17,
        6'd20, 6'd21, 6'd48, 6'd49: wr_legal = 1'b1;
        default:                    wr_legal = 1'b0;
      endcase
    end
  end

  // The window registers are frozen once WINDOW_LOCK has taken.
  wire win_wr_ok = ~win_locked;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_pend <= 1'b0; w_pend <= 1'b0; b_pend <= 1'b0;
      aw_addr_q <= '0; w_data_q <= '0; w_strb_q <= '0;
      ar_pend <= 1'b0; r_pend <= 1'b0; ar_addr_q <= '0; r_data_q <= '0;

      ctrl_start <= 1'b0; ctrl_srst <= 1'b0; ctrl_unsafe <= 1'b0;
      ctrl_nogen <= 1'b0; ctrl_sigchk <= 1'b0; ctrl_evten <= 1'b1;
      base_lo <= '0; base_hi <= '0; limit_lo <= '0; limit_hi <= '0;
      win_locked <= 1'b0;
      cmd_desc_r <= '0; cmd_cfg_r <= '0; cmd_addr_lo <= '0;
      cmd_addr_hi <= '0; cmd_sig_r <= '0;
      reuse_cfg_r <= '0;
      scratch0 <= '0; scratch1 <= '0;
      sticky <= '0;
      cnt_req_drop <= '0; cnt_illegal <= '0;
      grant_q <= 1'b0; refused_q <= 1'b0; new_gen_q <= '0;
      o_req_valid <= 1'b0; o_reuse_req <= 1'b0;
    end else begin
      o_req_valid <= 1'b0;
      o_reuse_req <= 1'b0;
      ctrl_srst   <= 1'b0;            // one-shot

      // ---------------------------------------------------- write channel
      if (aw_hs) begin aw_pend <= 1'b1; aw_addr_q <= s_axi_awaddr; end
      if (w_hs)  begin w_pend  <= 1'b1; w_data_q <= s_axi_wdata;
                       w_strb_q <= s_axi_wstrb; end
      if (wr_commit) begin
        aw_pend <= 1'b0;
        w_pend  <= 1'b0;
        b_pend  <= 1'b1;
        if (!wr_legal) cnt_illegal <= cnt_illegal + 32'd1;
        if (wr_in_range) begin
          case (wr_idx)
            6'd2: begin                                   // CTRL
              if (w_strb_q[0]) begin
                ctrl_start  <= w_data_q[0];
                ctrl_srst   <= w_data_q[1];
                ctrl_unsafe <= w_data_q[2];
                ctrl_nogen  <= w_data_q[3];
                ctrl_sigchk <= w_data_q[4];
                ctrl_evten  <= w_data_q[5];
              end
            end
            6'd4: begin                                   // STATUS_CLR, W1C
              for (int b = ST_S_REQ_DROP; b <= ST_S_LC_ERR; b++)
                if (w_data_q[b]) sticky[b] <= 1'b0;
            end
            6'd5: if (win_wr_ok) base_lo  <= bwrite(base_lo,  w_data_q, w_strb_q);
            6'd6: if (win_wr_ok) base_hi  <= bwrite(base_hi,  w_data_q, w_strb_q);
            6'd7: if (win_wr_ok) limit_lo <= bwrite(limit_lo, w_data_q, w_strb_q);
            6'd8: if (win_wr_ok) limit_hi <= bwrite(limit_hi, w_data_q, w_strb_q);
            6'd9: if (w_data_q == LOCK_MAGIC) win_locked <= 1'b1;
            6'd12: cmd_desc_r  <= bwrite(cmd_desc_r,  w_data_q, w_strb_q);
            6'd13: cmd_cfg_r   <= bwrite(cmd_cfg_r,   w_data_q, w_strb_q);
            6'd14: cmd_addr_lo <= bwrite(cmd_addr_lo, w_data_q, w_strb_q);
            6'd15: cmd_addr_hi <= bwrite(cmd_addr_hi, w_data_q, w_strb_q);
            6'd16: cmd_sig_r   <= bwrite(cmd_sig_r,   w_data_q, w_strb_q);
            6'd20: reuse_cfg_r <= bwrite(reuse_cfg_r, w_data_q, w_strb_q);
            6'd48: scratch0    <= bwrite(scratch0,    w_data_q, w_strb_q);
            6'd49: scratch1    <= bwrite(scratch1,    w_data_q, w_strb_q);
            default: ;
          endcase
        end

        // command issue. A full request FIFO drops the command and says so.
        if (cmd_go_wr) begin
          if (i_req_ready) begin
            o_req_valid <= 1'b1;
          end else begin
            cnt_req_drop          <= cnt_req_drop + 32'd1;
            sticky[ST_S_REQ_DROP] <= 1'b1;
          end
        end
        if (reuse_go_wr) o_reuse_req <= 1'b1;
      end
      if (b_pend && s_axi_bready) b_pend <= 1'b0;

      // ----------------------------------------------------- read channel
      if (ar_hs) begin ar_pend <= 1'b1; ar_addr_q <= s_axi_araddr; end
      if (ar_pend) begin
        ar_pend  <= 1'b0;
        r_pend   <= 1'b1;
        r_data_q <= rd_mux;
      end
      if (r_pend && s_axi_rready) r_pend <= 1'b0;

      // -------------------------------------------------------- observers
      grant_q   <= i_p_reuse_grant;
      refused_q <= i_p_reuse_refused;
      if (i_p_reuse_grant) new_gen_q <= i_reuse_new_gen;

      if (i_p_window_refused)   sticky[ST_S_WIN_REF]   <= 1'b1;
      if (i_p_boundary_refused) sticky[ST_S_BND_REF]   <= 1'b1;
      if (i_p_align_refused)    sticky[ST_S_ALN_REF]   <= 1'b1;
      if (i_p_tag_conflict)     sticky[ST_S_TAG_CONF]  <= 1'b1;
      if (i_p_axi_err)          sticky[ST_S_AXI_ERR]   <= 1'b1;
      if (i_p_payload_mismatch) sticky[ST_S_PAY_MM]    <= 1'b1;
      if (i_p_stale_desc)       sticky[ST_S_STALE]     <= 1'b1;
      if (i_p_unsafe_commit)    sticky[ST_S_UNSAFE]    <= 1'b1;
      if (i_p_reuse_refused)    sticky[ST_S_REUSE_REF] <= 1'b1;
      if (i_p_lc_err)           sticky[ST_S_LC_ERR]    <= 1'b1;
      if (i_p_evt_drop)         sticky[ST_S_EVT_DROP]  <= 1'b1;
    end
  end

  // ------------------------------------------------------- control fan-out
  wire [63:0] base_full  = {base_hi,     base_lo};
  wire [63:0] limit_full = {limit_hi,    limit_lo};
  wire [63:0] addr_full  = {cmd_addr_hi, cmd_addr_lo};

  assign o_start          = ctrl_start;
  assign o_soft_reset_req = ctrl_srst;
  assign o_unsafe_bypass  = ctrl_unsafe;
  assign o_no_gen_check   = ctrl_nogen;
  assign o_evt_capture_en = ctrl_evten;
  assign o_window_locked  = win_locked;

  assign o_scratch_base  = base_full [AXI_ADDR_W-1:0];
  assign o_scratch_limit = limit_full[AXI_ADDR_W-1:0];

  assign o_req_addr      = addr_full[AXI_ADDR_W-1:0];
  assign o_req_len       = cmd_cfg_r[15:8];
  assign o_req_sig       = cmd_sig_r;
  assign o_req_sig_check = cmd_cfg_r[5] & ctrl_sigchk;

  always_comb begin
    o_req_is_read  = cmd_cfg_r[4];
    o_req_ev       = cmd_cfg_r[2:0];
    // use_desc stays exactly as the host asked. CTRL.no_generation_check is
    // NOT folded in here: it is a separate hardware input to page_state_lut
    // which degrades desc_valid to slot + frame identity. Folding it into
    // use_desc would disable the descriptor check entirely and destroy the
    // distinction the artifact exists to demonstrate.
    o_req_use_desc = cmd_cfg_r[3];

    o_req_desc.lifecycle_slot      = cmd_desc_r[SLOT_W-1:0];
    o_req_desc.phys_idx            = cmd_desc_r[8  +: PHYS_W];
    o_req_desc.expected_generation = cmd_desc_r[16 +: GEN_W];
    o_req_desc.transaction_tag     = cmd_desc_r[24 +: TAG_W];
    o_req_desc.tenant              = cmd_desc_r[28 +: TENANT_W];
  end

  assign o_reuse_slot   = reuse_cfg_r[SLOT_W-1:0];
  assign o_reuse_phys   = reuse_cfg_r[8  +: PHYS_W];
  assign o_reuse_tenant = reuse_cfg_r[16 +: TENANT_W];

  // ------------------------------------------------------------- read mux
  always_comb begin
    status_w                  = sticky;
    status_w[ST_IDLE]         = i_core_idle;
    status_w[ST_BUSY]         = i_core_busy;
    status_w[ST_REQ_FULL]     = i_req_fifo_full;
    status_w[ST_REQ_EMPTY]    = i_req_fifo_empty;
    status_w[ST_EVT_FULL]     = i_evt_fifo_full;
    status_w[ST_EVT_EMPTY]    = i_evt_fifo_empty;
    status_w[ST_WIN_LOCKED]   = win_locked;
    status_w[ST_WIN_VALID]    = i_window_valid;
    status_w[ST_SRST_ACT]     = i_soft_reset_active;
    status_w[23:21]           = 3'b000;
    status_w[31:24]           = i_outstanding;
  end

  always_comb begin
    rd_mux = 32'h0000_0000;
    if (rd_in_range) begin
      case (rd_idx)
        6'd0 : rd_mux = ID_MAGIC;
        6'd1 : rd_mux = VERSION_ID;
        6'd2 : rd_mux = {26'd0, ctrl_evten, ctrl_sigchk, ctrl_nogen,
                         ctrl_unsafe, 1'b0, ctrl_start};
        6'd3 : rd_mux = status_w;
        6'd5 : rd_mux = base_lo;
        6'd6 : rd_mux = base_hi;
        6'd7 : rd_mux = limit_lo;
        6'd8 : rd_mux = limit_hi;
        6'd9 : rd_mux = {31'd0, win_locked};
        6'd10: rd_mux = {30'd0, i_window_valid, win_locked};
        6'd12: rd_mux = cmd_desc_r;
        6'd13: rd_mux = cmd_cfg_r;
        6'd14: rd_mux = cmd_addr_lo;
        6'd15: rd_mux = cmd_addr_hi;
        6'd16: rd_mux = cmd_sig_r;
        6'd20: rd_mux = reuse_cfg_r;
        6'd22: rd_mux = {16'd0, new_gen_q, 6'd0, refused_q, grant_q};
        6'd24: rd_mux = i_cnt_reuse_refused;
        6'd25: rd_mux = i_cnt_stale;
        6'd26: rd_mux = i_cnt_unsafe_commit;
        6'd27: rd_mux = i_cnt_payload_mismatch;
        6'd28: rd_mux = i_cnt_axi_err;
        6'd29: rd_mux = i_cnt_complete;
        6'd30: rd_mux = i_cnt_window_refused;
        6'd31: rd_mux = i_cnt_boundary_refused;
        6'd32: rd_mux = i_cnt_align_refused;
        6'd33: rd_mux = i_cnt_tag_conflict;
        6'd34: rd_mux = i_cnt_dispatch;
        6'd35: rd_mux = i_cnt_accept;
        6'd36: rd_mux = i_cnt_first_data;
        6'd37: rd_mux = cnt_req_drop;
        6'd38: rd_mux = i_cnt_evt_drop;
        6'd39: rd_mux = i_cnt_lc_err;
        6'd40: rd_mux = i_cnt_reuse_grant;
        6'd41: rd_mux = cnt_illegal;
        6'd42: rd_mux = {i_evt_desc.expected_generation,
                         i_evt_desc.phys_idx,
                         i_evt_desc.lifecycle_slot,
                         i_evt_desc.tenant,
                         i_evt_desc.transaction_tag,
                         1'b0, i_evt_code};
        6'd43: rd_mux = i_evt_count;
        6'd44: rd_mux = {2'd0, i_lc_evictable, i_lc_entry.valid,
                         i_lc_entry.fill_pending, 2'd0, i_lc_entry.inflight,
                         i_lc_entry.reservation, i_lc_entry.refcount};
        6'd45: rd_mux = {3'd0, i_lc_ok, i_lc_err, 4'd0, i_lc_entry.tenant,
                         2'd0, i_lc_entry.phys_idx, i_lc_entry.generation};
        6'd46: rd_mux = {i_last_araddr[31:12], 10'd0, i_last_rresp};
        6'd47: rd_mux = {24'd0, i_outstanding};
        6'd48: rd_mux = scratch0;
        6'd49: rd_mux = scratch1;
        default: rd_mux = 32'h0000_0000;
      endcase
    end
  end

endmodule
