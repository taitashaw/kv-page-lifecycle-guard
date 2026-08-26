// tb_refute_silent.sv
// Purpose: test the claim "the wedged state raises no error bit, so a host has
// nothing to poll". Snapshots the ENTIRE host-visible register surface at a
// healthy quiescent point and again after the alleged wedge, and diffs them.

`include "lifecycle_pkg.sv"

module tb_refute_silent;
  import lifecycle_pkg::*;

  localparam int AW = 40;
  localparam int DW = 128;

  localparam logic [11:0] R_ID          = 12'h000;
  localparam logic [11:0] R_CTRL        = 12'h008;
  localparam logic [11:0] R_STATUS      = 12'h00C;
  localparam logic [11:0] R_BASE_LO     = 12'h014;
  localparam logic [11:0] R_BASE_HI     = 12'h018;
  localparam logic [11:0] R_LIMIT_LO    = 12'h01C;
  localparam logic [11:0] R_LIMIT_HI    = 12'h020;
  localparam logic [11:0] R_CMD_DESC    = 12'h030;
  localparam logic [11:0] R_CMD_CFG     = 12'h034;
  localparam logic [11:0] R_CMD_ADDR_LO = 12'h038;
  localparam logic [11:0] R_CMD_ADDR_HI = 12'h03C;
  localparam logic [11:0] R_CMD_SIG     = 12'h040;
  localparam logic [11:0] R_CMD_GO      = 12'h044;
  localparam logic [11:0] R_C_PAY_MM    = 12'h06C;
  localparam logic [11:0] R_C_COMPLETE  = 12'h074;
  localparam logic [11:0] R_C_DISPATCH  = 12'h088;
  localparam logic [11:0] R_C_ACCEPT    = 12'h08C;
  localparam logic [11:0] R_C_FIRSTDAT  = 12'h090;
  localparam logic [11:0] R_C_REQ_DROP  = 12'h094;   // idx 37
  localparam logic [11:0] R_C_LC_ERR    = 12'h09C;   // idx 39
  localparam logic [11:0] R_C_ILLEGAL   = 12'h0A4;   // idx 41
  localparam logic [11:0] R_OUTSTANDING = 12'h0BC;   // idx 47

  localparam logic [39:0] WIN_BASE  = 40'h00_8000_0000;
  localparam logic [39:0] WIN_LIMIT = 40'h00_8001_0000;
  localparam logic [31:0] SIG_GOOD  = 32'hCAFE_BABE;

  logic clk = 0, rst_n = 0;
  always #2.5 clk = ~clk;

  logic [11:0] awaddr;  logic awvalid;  wire awready;
  logic [31:0] wdata;   logic [3:0] wstrb; logic wvalid; wire wready;
  wire  [1:0]  bresp;   wire bvalid;    logic bready;
  logic [11:0] araddr;  logic arvalid;  wire arready;
  wire  [31:0] rdata;   wire [1:0] rresp; wire rvalid; logic rready;

  wire [TAG_W-1:0] m_arid;
  wire [AW-1:0]    m_araddr;
  wire [7:0]       m_arlen;
  wire [2:0]       m_arsize;
  wire [1:0]       m_arburst;
  wire             m_arlock;
  wire [3:0]       m_arcache;
  wire [2:0]       m_arprot;
  wire [3:0]       m_arqos;
  wire             m_arvalid;
  logic            m_arready;
  logic [TAG_W-1:0] m_rid;
  logic [DW-1:0]   m_rdata;
  logic [1:0]      m_rresp;
  logic            m_rlast;
  logic            m_rvalid;
  wire             m_rready;
  wire [195:0] ila;

  lifecycle_guard_top #(.AXI_ADDR_W(AW), .AXI_DATA_W(DW)) dut (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid),
    .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
    .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
    .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst), .m_axi_arlock(m_arlock),
    .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot), .m_axi_arqos(m_arqos),
    .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
    .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
    .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
    .o_ila_probe(ila)
  );

  // ------------------------------------------------ AXI4 read-slave BFM
  logic [TAG_W-1:0] q_id   [$];
  logic [7:0]       q_len  [$];
  logic [31:0]      rsp_sig = SIG_GOOD;

  initial m_arready = 1'b1;

  always @(posedge clk) begin
    if (rst_n && m_arvalid && m_arready) begin
      q_id.push_back(m_arid);
      q_len.push_back(m_arlen);
    end
  end

  initial begin
    m_rvalid = 0; m_rlast = 0; m_rresp = 2'b00; m_rid = '0; m_rdata = '0;
    forever begin
      @(posedge clk);
      if (q_id.size() > 0) begin
        automatic logic [TAG_W-1:0] id = q_id.pop_front();
        automatic logic [7:0] len = q_len.pop_front();
        repeat (3) @(posedge clk);
        for (int b = 0; b <= int'(len); b++) begin
          @(negedge clk);
          m_rvalid = 1'b1;
          m_rid    = id;
          m_rdata  = {96'd0, (b == 0) ? rsp_sig : 32'h0000_0000};
          m_rlast  = (b == int'(len));
          m_rresp  = 2'b00;
          @(posedge clk);
          while (!m_rready) @(posedge clk);
        end
        @(negedge clk);
        m_rvalid = 1'b0;
        m_rlast  = 1'b0;
      end
    end
  end

  // ------------------------------------------------ AXI4-Lite master BFM
  task automatic axil_write(input logic [11:0] a, input logic [31:0] d);
    bit aw_go, w_go;
    begin
      @(negedge clk);
      awaddr = a; awvalid = 1'b1;
      wdata  = d; wstrb = 4'hF; wvalid = 1'b1;
      bready = 1'b1;
      forever begin
        aw_go = awvalid & awready;
        w_go  = wvalid  & wready;
        @(posedge clk); @(negedge clk);
        if (aw_go) awvalid = 1'b0;
        if (w_go)  wvalid  = 1'b0;
        if (!awvalid && !wvalid) break;
      end
      forever begin
        if (bvalid) begin @(posedge clk); @(negedge clk); break; end
        @(posedge clk); @(negedge clk);
      end
      bready = 1'b0;
    end
  endtask

  task automatic axil_read(input logic [11:0] a, output logic [31:0] d);
    bit ar_go;
    begin
      @(negedge clk);
      araddr = a; arvalid = 1'b1; rready = 1'b1;
      forever begin
        ar_go = arvalid & arready;
        @(posedge clk); @(negedge clk);
        if (ar_go) begin arvalid = 1'b0; break; end
      end
      forever begin
        if (rvalid) begin d = rdata; @(posedge clk); @(negedge clk); break; end
        @(posedge clk); @(negedge clk);
      end
      rready = 1'b0;
    end
  endtask

  function automatic logic [31:0] mk_desc(input logic [5:0] slot,
                                          input logic [5:0] phys,
                                          input logic [7:0] gen,
                                          input logic [3:0] tag,
                                          input logic [3:0] tenant);
    mk_desc = {tenant, tag, gen, 2'd0, phys, 2'd0, slot};
  endfunction

  function automatic logic [31:0] mk_read_cfg(input logic [7:0] len,
                                              input bit sigchk);
    mk_read_cfg = {16'd0, len, 2'd0, sigchk, 1'b1, 1'b0, 3'd0};
  endfunction

  task automatic issue_read(input logic [39:0] a, input logic [7:0] len,
                            input logic [3:0] tag, input bit sigchk = 0,
                            input logic [31:0] sig = SIG_GOOD);
    begin
      axil_write(R_CMD_DESC,    mk_desc(6'd5, 6'd9, 8'd0, tag, 4'd1));
      axil_write(R_CMD_ADDR_LO, a[31:0]);
      axil_write(R_CMD_ADDR_HI, {24'd0, a[39:32]});
      axil_write(R_CMD_SIG,     sig);
      axil_write(R_CMD_CFG,     mk_read_cfg(len, sigchk));
      axil_write(R_CMD_GO,      32'h1);
    end
  endtask

  // ------------------------------------------------------------ snapshot
  logic [31:0] s_status, s_disp, s_acc, s_comp, s_fd, s_paymm;
  logic [31:0] s_reqdrop, s_lcerr, s_illegal, s_outst;

  task automatic snap(input string label);
    begin
      axil_read(R_STATUS,      s_status);
      axil_read(R_C_DISPATCH,  s_disp);
      axil_read(R_C_ACCEPT,    s_acc);
      axil_read(R_C_COMPLETE,  s_comp);
      axil_read(R_C_FIRSTDAT,  s_fd);
      axil_read(R_C_PAY_MM,    s_paymm);
      axil_read(R_C_REQ_DROP,  s_reqdrop);
      axil_read(R_C_LC_ERR,    s_lcerr);
      axil_read(R_C_ILLEGAL,   s_illegal);
      axil_read(R_OUTSTANDING, s_outst);
      $display("[%s] t=%0t", label, $time);
      $display("   STATUS      = 0x%08h", s_status);
      $display("     b0 IDLE=%0b  b1 BUSY=%0b  b2 REQ_FULL=%0b  b3 REQ_EMPTY=%0b",
               s_status[0], s_status[1], s_status[2], s_status[3]);
      $display("     b4 EVT_FULL=%0b b5 EVT_EMPTY=%0b b18 WIN_LOCK=%0b b19 WIN_VALID=%0b",
               s_status[4], s_status[5], s_status[18], s_status[19]);
      $display("     sticky: reqdrop=%0b evtdrop=%0b win=%0b bnd=%0b aln=%0b tagc=%0b axierr=%0b paymm=%0b stale=%0b unsafe=%0b reuseref=%0b lcerr=%0b",
               s_status[6], s_status[7], s_status[8], s_status[9], s_status[10],
               s_status[11], s_status[12], s_status[13], s_status[14],
               s_status[15], s_status[16], s_status[17]);
      $display("     OUTSTANDING(b31:24) = %0d", s_status[31:24]);
      $display("   CNT dispatch=%0d accept=%0d first_data=%0d complete=%0d paymm=%0d",
               s_disp, s_acc, s_fd, s_comp, s_paymm);
      $display("   CNT req_drop=%0d lc_err=%0d illegal=%0d   OUTSTANDING_REG=%0d",
               s_reqdrop, s_lcerr, s_illegal, s_outst);
    end
  endtask

  logic [31:0] v;
  logic [31:0] st_a, st_b, st_c, st_d;

  initial begin
    awaddr='0; awvalid=0; wdata='0; wstrb=0; wvalid=0; bready=0;
    araddr='0; arvalid=0; rready=0;

    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    $display("\n=== A. program window + start ===");
    axil_write(R_CTRL, 32'h1);
    axil_write(R_BASE_LO,  WIN_BASE[31:0]);
    axil_write(R_BASE_HI,  {24'd0, WIN_BASE[39:32]});
    axil_write(R_LIMIT_LO, WIN_LIMIT[31:0]);
    axil_write(R_LIMIT_HI, {24'd0, WIN_LIMIT[39:32]});
    snap("A: armed, idle");
    st_a = s_status;

    $display("\n=== B. healthy in-window read (tb test 4) ===");
    issue_read(WIN_BASE, 8'd3, 4'd1, 1'b1, SIG_GOOD);
    repeat (60) @(posedge clk);
    snap("B: after healthy read");
    st_b = s_status;

    $display("\n=== C. the tb test-5 stimulus (payload mismatch case) ===");
    issue_read(WIN_BASE + 40'h100, 8'd0, 4'd2, 1'b1, 32'hDEAD_0000);
    repeat (60) @(posedge clk);
    snap("C: 60 clk after test-5 read");
    st_c = s_status;

    $display("\n=== D. let it sit for 2000 more clocks, nothing else driven ===");
    repeat (2000) @(posedge clk);
    snap("D: +2000 clk, quiescent");
    st_d = s_status;

    $display("\n=== E. does STATUS distinguish healthy-quiescent from state D? ===");
    $display("   STATUS A (armed idle)      = 0x%08h", st_a);
    $display("   STATUS B (healthy settled) = 0x%08h", st_b);
    $display("   STATUS D (alleged wedge)   = 0x%08h", st_d);
    $display("   B != D ? %0s", (st_b !== st_d) ? "YES - host CAN poll a difference"
                                                : "NO  - indistinguishable");
    $display("   B[3] REQ_EMPTY=%0b   D[3] REQ_EMPTY=%0b", st_b[3], st_d[3]);
    $display("   B[0] IDLE=%0b        D[0] IDLE=%0b",      st_b[0], st_d[0]);
    $display("   B[31:24] OUTST=%0d   D[31:24] OUTST=%0d", st_b[31:24], st_d[31:24]);

    $display("\n=== F. host-side invariant checks available by polling ===");
    $display("   inv1  (OUTSTANDING != 0 && BUSY == 0)            -> %0s",
             ((s_status[31:24] != 0) && (s_status[1] == 0)) ? "VIOLATED (detectable)" : "clean");
    $display("   inv2  (REQ_EMPTY == 0 && BUSY == 0 && IDLE == 0) -> %0s",
             ((s_status[3] == 0) && (s_status[1] == 0) && (s_status[0] == 0)) ? "VIOLATED (detectable)" : "clean");
    $display("   inv3  (CNT_ACCEPT != CNT_COMPLETE)               -> %0s",
             (s_acc !== s_comp) ? "VIOLATED (detectable)" : "clean");
    $display("   inv4  (OUTSTANDING != ACCEPT-COMPLETE)           -> %0s",
             (s_status[31:24] !== (s_acc - s_comp)) ? "VIOLATED (detectable)" : "clean");
    $display("   inv5  (CNT_DISPATCH != CNT_ACCEPT + refusals)     dispatch=%0d accept=%0d",
             s_disp, s_acc);

    $display("\n=== G. can a further read still be dispatched? ===");
    issue_read(WIN_BASE + 40'h200, 8'd0, 4'd3, 1'b0, SIG_GOOD);
    repeat (200) @(posedge clk);
    snap("G: after one more read");

    $display("\n=== H. ILA probe visibility at the wedge ===");
    $display("   ila[ILA_OUTST +:2] region and AR handshake pins are on o_ila_probe");
    $display("   m_arvalid=%0b m_arready=%0b   ila=0x%049h", m_arvalid, m_arready, ila);

    $display("\nDONE");
    $finish;
  end

  initial begin
    #900000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
