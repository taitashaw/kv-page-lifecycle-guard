// axi_read_manager.sv
// READ-ONLY AXI4 manager for the lifecycle-safety artifact (V1).
//
// READ-ONLY IS STRUCTURAL, NOT A CONVENTION. This module has no AW, W or B
// ports at all. There is nothing to disable and nothing to get wrong: it
// physically cannot emit a write.
//
// THE SCRATCH-WINDOW GATE. Every AR issue is gated on
//     base <= addr  and  addr + burst_bytes <= limit
// with base/limit supplied by the register block and, additionally, with the
// window size hard-capped at 2**MAX_WINDOW_LOG2 bytes by a synthesis-time
// parameter. This module has NO unsafe_bypass input, so no software bit can
// widen the window. An out-of-window request is consumed, counted and never
// issued. base==limit==0 out of reset means default deny: nothing can be
// fetched until software programs a window.
//
// Other invariants enforced here, not asserted elsewhere:
//   * a burst NEVER crosses a 4 KiB boundary. A request that would cross is
//     refused and counted rather than split.
//   * the address is naturally aligned to the data width, else refused.
//   * a tag is unique among active transactions. A request whose tag is still
//     outstanding is refused and counted.
//   * outstanding transactions are bounded by tag_tracker's accept_ready,
//     which is MAX_OUTSTANDING (default 2).
//
// OBSERVABLE EVENTS ONLY. DISPATCH, AXI_ACCEPT (AR handshake),
// AXI_FIRST_DATA (first R beat of a transaction) and AXI_COMPLETE (RLAST).
// There is no DDR_SERVICE_START: PL logic behind SmartConnect and the Zynq
// memory controller cannot observe it, so it does not exist here.
//
// The event port carries two independent slots per cycle, an AR-side slot
// and an R-side slot, because an AR handshake and an R beat of a different
// transaction can land in the same cycle. FIRST_DATA and COMPLETE of a
// single-beat burst share the R slot through the first/last flags.
//
// The event path is OBSERVATIONAL. Losing an event never loses safety: the
// functional completion path runs straight into tag_tracker, not through the
// event FIFO.

`include "lifecycle_pkg.sv"

module axi_read_manager
  import lifecycle_pkg::*;
#(
  parameter int unsigned AXI_ADDR_W      = 40,
  parameter int unsigned AXI_DATA_W      = 128,
  parameter int unsigned MAX_OUTSTANDING = 2,
  parameter int unsigned MAX_WINDOW_LOG2 = 20,        // hard cap 1 MiB
  parameter logic [3:0]  ARCACHE         = 4'b0011,
  parameter logic [2:0]  ARPROT          = 3'b010
)(
  input  wire                     clk,
  input  wire                     rst_n,

  // ------------------------------------------------- scratch window (gate)
  input  wire [AXI_ADDR_W-1:0]    i_win_base,
  input  wire [AXI_ADDR_W-1:0]    i_win_limit,        // exclusive
  output wire                     o_win_valid,

  // ----------------------------------------------------------- request in
  input  wire                     i_req_valid,
  output wire                     o_req_ready,
  input  descriptor_t             i_req_desc,
  input  wire [AXI_ADDR_W-1:0]    i_req_addr,
  input  wire [7:0]               i_req_len,          // ARLEN, beats-1
  input  wire [31:0]              i_req_sig,
  input  wire                     i_req_sig_check,

  // ---------------------------------------------------------- tag_tracker
  output wire                     o_tt_accept,
  output descriptor_t             o_tt_accept_desc,
  output wire                     o_tt_complete,
  output wire [TAG_W-1:0]         o_tt_complete_tag,
  input  wire                     i_tt_accept_ready,

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

  // --------------------------------------------------------------- events
  output logic                    o_evt_a_valid,
  output logic [2:0]              o_evt_a_code,       // txn_event_e
  output descriptor_t             o_evt_a_desc,
  output logic                    o_evt_r_valid,
  output logic                    o_evt_r_first,
  output logic                    o_evt_r_last,
  output logic [1:0]              o_evt_r_resp,
  output descriptor_t             o_evt_r_desc,

  // -------------------------------------------------------- observability
  output wire                     o_idle,
  output wire                     o_busy,
  output logic                    o_p_window_refused,
  output logic                    o_p_boundary_refused,
  output logic                    o_p_align_refused,
  output logic                    o_p_tag_conflict,
  output logic                    o_p_axi_err,
  output logic                    o_p_payload_mismatch,
  output logic [1:0]              o_last_rresp,
  output logic [AXI_ADDR_W-1:0]   o_last_araddr,

  output logic [31:0]             o_cnt_dispatch,
  output logic [31:0]             o_cnt_accept,
  output logic [31:0]             o_cnt_first_data,
  output logic [31:0]             o_cnt_complete,
  output logic [31:0]             o_cnt_axi_err,
  output logic [31:0]             o_cnt_payload_mismatch,
  output logic [31:0]             o_cnt_window_refused,
  output logic [31:0]             o_cnt_boundary_refused,
  output logic [31:0]             o_cnt_align_refused,
  output logic [31:0]             o_cnt_tag_conflict
);

  localparam int unsigned BEAT_BYTES = AXI_DATA_W/8;
  localparam int unsigned SIZE_CODE  = $clog2(BEAT_BYTES);

  // -------------------------------------------------------------- request
  // Bytes moved by this burst. ARLEN is beats-1, so the worst case is
  // 256 beats * BEAT_BYTES. 14 bits holds 256*16 = 4096 with room to spare.
  wire [13:0] burst_bytes = ({6'd0, i_req_len} + 14'd1) << SIZE_CODE;

  // ------------------------------------------- gate 1: the scratch window
  wire [AXI_ADDR_W-1:0] win_size = i_win_limit - i_win_base;
  wire win_prog_ok = (i_win_limit > i_win_base) &&
                     (win_size[AXI_ADDR_W-1:MAX_WINDOW_LOG2] == '0);

  logic [AXI_ADDR_W:0] req_end;        // one extra bit catches wrap
  always_comb req_end = {1'b0, i_req_addr} + burst_bytes;

  wire g_window = win_prog_ok &&
                  (i_req_addr >= i_win_base) &&
                  (req_end    <= {1'b0, i_win_limit});

  assign o_win_valid = win_prog_ok;

  // ------------------------------------------ gate 2: the 4 KiB boundary
  wire [13:0] page_off = {2'd0, i_req_addr[11:0]};
  wire g_bound = ((page_off + burst_bytes) <= 14'd4096);

  // ------------------------------------------------ gate 3: the alignment
  wire g_align = (i_req_addr[SIZE_CODE-1:0] == '0);

  // ------------------------------------------- gate 4: tag not outstanding
  logic [TAGS-1:0] tag_busy_sh;        // shadow of tag_tracker's busy vector
  logic [TAGS-1:0] tag_seen_sh;        // a beat has already arrived for this tag
  wire g_tag = ~tag_busy_sh[i_req_desc.transaction_tag];

  // per-tag context, written on AR handshake, read on R beats
  descriptor_t tag_desc_sh [TAGS];
  logic [31:0] tag_sig     [TAGS];
  logic        tag_sigchk  [TAGS];

  // ----------------------------------------------------------------- FSM
  // S_IDLE evaluates the head request. S_DISP emits DISPATCH one cycle
  // BEFORE ARVALID rises, which guarantees DISPATCH and AXI_ACCEPT never
  // land in the same cycle and puts every AR output straight on a flop.
  typedef enum logic [1:0] {S_IDLE = 2'd0, S_DISP = 2'd1, S_AR = 2'd2} state_e;
  state_e state;

  descriptor_t          issue_desc;
  logic [AXI_ADDR_W-1:0] issue_addr;
  logic [7:0]           issue_len;
  logic [31:0]          issue_sig;
  logic                 issue_sigchk;
  logic                 arvalid_q;

  wire refuse_any = ~g_window | ~g_bound | ~g_align | ~g_tag;
  wire issue_ok   = g_window &  g_bound &  g_align &  g_tag & i_tt_accept_ready;

  assign o_req_ready = (state == S_IDLE) & (refuse_any | issue_ok);

  wire req_fire = i_req_valid & o_req_ready;
  wire ar_hs    = m_axi_arvalid & m_axi_arready;

  // The manager always sinks read data. It keeps nothing but the first-beat
  // signature comparison, so RREADY can be unconditional and no deadlock is
  // reachable from the R channel.
  assign m_axi_rready = 1'b1;
  wire r_hs    = m_axi_rvalid & m_axi_rready;
  wire r_first = r_hs & ~tag_seen_sh[m_axi_rid];
  wire r_last  = r_hs &  m_axi_rlast;

  wire pay_mm  = r_first & tag_sigchk[m_axi_rid] &
                 (m_axi_rdata[31:0] != tag_sig[m_axi_rid]);

  // ----------------------------------------------------------- AXI4 AR out
  assign m_axi_arid    = issue_desc.transaction_tag;
  assign m_axi_araddr  = issue_addr;
  assign m_axi_arlen   = issue_len;
  assign m_axi_arsize  = SIZE_CODE[2:0];
  assign m_axi_arburst = 2'b01;                 // INCR
  assign m_axi_arlock  = 1'b0;
  assign m_axi_arcache = ARCACHE;
  assign m_axi_arprot  = ARPROT;
  assign m_axi_arqos   = 4'b0000;
  assign m_axi_arvalid = arvalid_q;

  // ---------------------------------------------------------- tag_tracker
  assign o_tt_accept       = ar_hs;
  assign o_tt_accept_desc  = issue_desc;
  assign o_tt_complete     = r_last;
  assign o_tt_complete_tag = m_axi_rid;

  assign o_idle = (state == S_IDLE) & (tag_busy_sh == '0);
  assign o_busy = (state != S_IDLE) | (tag_busy_sh != '0);

  integer t;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= S_IDLE;
      arvalid_q    <= 1'b0;
      issue_desc   <= '0;
      issue_addr   <= '0;
      issue_len    <= '0;
      issue_sig    <= '0;
      issue_sigchk <= 1'b0;
      tag_busy_sh  <= '0;
      tag_seen_sh  <= '0;
      for (t = 0; t < TAGS; t = t + 1) begin
        tag_desc_sh[t] <= '0;
        tag_sig[t]     <= '0;
        tag_sigchk[t]  <= 1'b0;
      end

      o_evt_a_valid <= 1'b0; o_evt_a_code <= 3'd0; o_evt_a_desc <= '0;
      o_evt_r_valid <= 1'b0; o_evt_r_first <= 1'b0; o_evt_r_last <= 1'b0;
      o_evt_r_resp  <= 2'b00; o_evt_r_desc <= '0;

      o_p_window_refused   <= 1'b0;
      o_p_boundary_refused <= 1'b0;
      o_p_align_refused    <= 1'b0;
      o_p_tag_conflict     <= 1'b0;
      o_p_axi_err          <= 1'b0;
      o_p_payload_mismatch <= 1'b0;
      o_last_rresp         <= 2'b00;
      o_last_araddr        <= '0;

      o_cnt_dispatch         <= '0;
      o_cnt_accept           <= '0;
      o_cnt_first_data       <= '0;
      o_cnt_complete         <= '0;
      o_cnt_axi_err          <= '0;
      o_cnt_payload_mismatch <= '0;
      o_cnt_window_refused   <= '0;
      o_cnt_boundary_refused <= '0;
      o_cnt_align_refused    <= '0;
      o_cnt_tag_conflict     <= '0;
    end else begin
      o_p_window_refused   <= 1'b0;
      o_p_boundary_refused <= 1'b0;
      o_p_align_refused    <= 1'b0;
      o_p_tag_conflict     <= 1'b0;
      o_p_axi_err          <= 1'b0;
      o_p_payload_mismatch <= 1'b0;

      // ------------------------------------------------------------- FSM
      case (state)
        S_IDLE: begin
          if (req_fire) begin
            if (refuse_any) begin
              // REFUSED. Never issued. Counted once, by highest-priority
              // failing gate, so one bad request is one increment.
              if (!g_window) begin
                o_p_window_refused   <= 1'b1;
                o_cnt_window_refused <= o_cnt_window_refused + 32'd1;
              end else if (!g_bound) begin
                o_p_boundary_refused   <= 1'b1;
                o_cnt_boundary_refused <= o_cnt_boundary_refused + 32'd1;
              end else if (!g_align) begin
                o_p_align_refused   <= 1'b1;
                o_cnt_align_refused <= o_cnt_align_refused + 32'd1;
              end else begin
                o_p_tag_conflict   <= 1'b1;
                o_cnt_tag_conflict <= o_cnt_tag_conflict + 32'd1;
              end
            end else begin
              issue_desc   <= i_req_desc;
              issue_addr   <= i_req_addr;
              issue_len    <= i_req_len;
              issue_sig    <= i_req_sig;
              issue_sigchk <= i_req_sig_check;
              state        <= S_DISP;
            end
          end
        end

        S_DISP: begin
          arvalid_q      <= 1'b1;
          o_cnt_dispatch <= o_cnt_dispatch + 32'd1;
          state          <= S_AR;
        end

        S_AR: begin
          if (m_axi_arready) begin
            arvalid_q     <= 1'b0;
            state         <= S_IDLE;
            o_last_araddr <= issue_addr;
            o_cnt_accept  <= o_cnt_accept + 32'd1;
          end
        end

        default: state <= S_IDLE;
      endcase

      // -------------------------------------------- per-tag shadow state
      // The clear is written first so a set always wins. The two cannot
      // collide anyway: a tag is only re-issued after its RLAST cleared it.
      if (r_last) tag_busy_sh[m_axi_rid] <= 1'b0;
      if (r_hs)   tag_seen_sh[m_axi_rid] <= 1'b1;
      if (ar_hs) begin
        tag_busy_sh[issue_desc.transaction_tag] <= 1'b1;
        tag_seen_sh[issue_desc.transaction_tag] <= 1'b0;
        tag_desc_sh[issue_desc.transaction_tag] <= issue_desc;
        tag_sig    [issue_desc.transaction_tag] <= issue_sig;
        tag_sigchk [issue_desc.transaction_tag] <= issue_sigchk;
      end

      // ------------------------------------------------------- R channel
      if (r_hs) begin
        o_last_rresp <= m_axi_rresp;
        if (m_axi_rresp != 2'b00) begin
          o_p_axi_err   <= 1'b1;
          o_cnt_axi_err <= o_cnt_axi_err + 32'd1;
        end
      end
      if (r_first) o_cnt_first_data <= o_cnt_first_data + 32'd1;
      if (r_last)  o_cnt_complete   <= o_cnt_complete   + 32'd1;
      if (pay_mm) begin
        o_p_payload_mismatch   <= 1'b1;
        o_cnt_payload_mismatch <= o_cnt_payload_mismatch + 32'd1;
      end

      // --------------------------------------------------------- events
      // Registered, so the AR-slot pulses for DISPATCH and AXI_ACCEPT land
      // one and at least two cycles after S_DISP respectively: never the
      // same cycle, so one AR slot per cycle is always enough.
      o_evt_a_valid <= (state == S_DISP) | ar_hs;
      o_evt_a_code  <= (state == S_DISP) ? 3'(TXN_DISPATCH)
                                         : 3'(TXN_AXI_ACCEPT);
      o_evt_a_desc  <= issue_desc;

      // Only the observable events are emitted. A middle beat is not one of
      // them, so it is not pushed.
      o_evt_r_valid <= r_first | r_last;
      o_evt_r_first <= r_first;
      o_evt_r_last  <= r_last;
      o_evt_r_resp  <= m_axi_rresp;
      o_evt_r_desc  <= tag_desc_sh[m_axi_rid];
    end
  end

`ifndef SYNTHESIS
  // The window gate, checked every cycle rather than merely documented.
  a_never_out_of_window: assert property (@(posedge clk) disable iff (!rst_n)
    (m_axi_arvalid |-> (win_prog_ok
                        && (issue_addr >= i_win_base)
                        && (issue_addr <  i_win_limit))))
    else $error("SAFETY: AR issued outside the scratch window");

  a_never_cross_4k: assert property (@(posedge clk) disable iff (!rst_n)
    (m_axi_arvalid |-> (({2'd0, issue_addr[11:0]} +
                         (({6'd0, issue_len} + 14'd1) << SIZE_CODE))
                        <= 14'd4096)))
    else $error("SAFETY: AR would cross a 4 KiB boundary");

  a_tag_unique: assert property (@(posedge clk) disable iff (!rst_n)
    (ar_hs |-> !$past(tag_busy_sh[issue_desc.transaction_tag])))
    else $error("SAFETY: AR issued on a tag already outstanding");
`endif

endmodule
