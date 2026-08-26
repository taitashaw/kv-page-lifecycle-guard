// tb_lifecycle_guard_top.sv
// Directed verification of the CRITICAL SAFETY CONSTRAINT and the AXI-Lite
// control plane. This exists so the scratch-window claim is DEMONSTRATED
// rather than asserted.
//
// The central property, checked continuously and not merely at the end:
//   whenever ARVALID is high, ARADDR lies inside [base, limit) and the burst
//   neither leaves that window nor crosses a 4 KiB boundary.
// The monitor below re-derives that from the AXI pins alone, independently of
// the DUT's own counters, so a broken gate cannot hide behind a broken
// counter.

`include "lifecycle_pkg.sv"

module tb_lifecycle_guard_top;
  import lifecycle_pkg::*;

  localparam int AW = 40;
  localparam int DW = 128;

  // ---------------------------------------------------------- register map
  localparam logic [11:0] R_ID          = 12'h000;
  localparam logic [11:0] R_CTRL        = 12'h008;
  localparam logic [11:0] R_STATUS      = 12'h00C;
  localparam logic [11:0] R_BASE_LO     = 12'h014;
  localparam logic [11:0] R_BASE_HI     = 12'h018;
  localparam logic [11:0] R_LIMIT_LO    = 12'h01C;
  localparam logic [11:0] R_LIMIT_HI    = 12'h020;
  localparam logic [11:0] R_WIN_LOCK    = 12'h024;
  localparam logic [11:0] R_CMD_DESC    = 12'h030;
  localparam logic [11:0] R_CMD_CFG     = 12'h034;
  localparam logic [11:0] R_CMD_ADDR_LO = 12'h038;
  localparam logic [11:0] R_CMD_ADDR_HI = 12'h03C;
  localparam logic [11:0] R_CMD_SIG     = 12'h040;
  localparam logic [11:0] R_CMD_GO      = 12'h044;
  localparam logic [11:0] R_REUSE_CFG   = 12'h050;
  localparam logic [11:0] R_REUSE_GO    = 12'h054;
  localparam logic [11:0] R_C_REUSE_REF = 12'h060;
  localparam logic [11:0] R_C_STALE     = 12'h064;
  localparam logic [11:0] R_C_UNSAFE    = 12'h068;
  localparam logic [11:0] R_C_PAY_MM    = 12'h06C;
  localparam logic [11:0] R_C_COMPLETE  = 12'h074;
  localparam logic [11:0] R_C_WIN_REF   = 12'h078;
  localparam logic [11:0] R_C_BND_REF   = 12'h07C;
  localparam logic [11:0] R_C_ALN_REF   = 12'h080;
  localparam logic [11:0] R_C_TAG_CONF  = 12'h084;
  localparam logic [11:0] R_C_DISPATCH  = 12'h088;
  localparam logic [11:0] R_C_ACCEPT    = 12'h08C;
  localparam logic [11:0] R_SCRATCH0    = 12'h0C0;

  localparam logic [39:0] WIN_BASE  = 40'h00_8000_0000;
  localparam logic [39:0] WIN_LIMIT = 40'h00_8001_0000;   // 64 KiB
  localparam logic [31:0] LOCK_MAGIC = 32'h5AFE_10C4;
  localparam logic [31:0] SIG_GOOD   = 32'hCAFE_BABE;

  logic clk = 0, rst_n = 0;
  always #2.5 clk = ~clk;                       // 200 MHz

  // ------------------------------------------------------------ AXI4-Lite
  logic [11:0] awaddr;  logic awvalid;  wire awready;
  logic [31:0] wdata;   logic [3:0] wstrb; logic wvalid; wire wready;
  wire  [1:0]  bresp;   wire bvalid;    logic bready;
  logic [11:0] araddr;  logic arvalid;  wire arready;
  wire  [31:0] rdata;   wire [1:0] rresp; wire rvalid; logic rready;

  // ------------------------------------------------------------- AXI4 read
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

  int errors = 0, checks = 0;

  lifecycle_guard_top #(
    .AXI_ADDR_W (AW),
    .AXI_DATA_W (DW)
  ) dut (
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

  // =====================================================================
  // INDEPENDENT SAFETY MONITOR.
  // Re-derives the window property from the AXI pins and the values the TB
  // itself programmed. It never reads a DUT counter, so a gate failure
  // cannot be masked by a counter failure.
  // =====================================================================
  logic [39:0] mon_base  = '0;
  logic [39:0] mon_limit = '0;
  logic        mon_armed = 1'b0;
  int          ar_seen   = 0;

  task automatic ck(input string n, input bit c);
    checks++;
    if (c) $display("  PASS  %s", n);
    else begin errors++; $display("  FAIL  %s", n); end
  endtask

  always @(posedge clk) begin
    if (rst_n && m_arvalid) begin
      automatic logic [40:0] burst = ({33'd0, m_arlen} + 41'd1) << m_arsize;
      automatic logic [40:0] aend  = {1'b0, m_araddr} + burst;
      if (mon_armed) begin
        if (m_araddr < mon_base) begin
          errors++;
          $display("  FAIL  MONITOR: AR 0x%010h below window base 0x%010h",
                   m_araddr, mon_base);
        end
        if (aend > {1'b0, mon_limit}) begin
          errors++;
          $display("  FAIL  MONITOR: AR 0x%010h + %0d exceeds limit 0x%010h",
                   m_araddr, burst, mon_limit);
        end
      end else begin
        errors++;
        $display("  FAIL  MONITOR: AR issued with no window programmed");
      end
      if (({29'd0, m_araddr[11:0]} + burst) > 41'd4096) begin
        errors++;
        $display("  FAIL  MONITOR: AR 0x%010h crosses a 4 KiB boundary",
                 m_araddr);
      end
      if (m_arburst != 2'b01) begin
        errors++; $display("  FAIL  MONITOR: ARBURST is not INCR");
      end
      if (m_arvalid && m_arready) ar_seen++;
    end
  end

  // =====================================================================
  // AXI4 read-slave BFM. Queues AR, returns beats with RID = ARID.
  // =====================================================================
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
        repeat (3) @(posedge clk);              // service latency
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

  // =====================================================================
  // AXI4-Lite master BFM. Race-free: every valid is driven and retired on
  // the negedge, and every ready is sampled on the negedge before the
  // posedge at which the handshake takes effect.
  // =====================================================================
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
        @(posedge clk);
        @(negedge clk);
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
        if (rvalid) begin
          d = rdata;
          @(posedge clk); @(negedge clk);
          break;
        end
        @(posedge clk); @(negedge clk);
      end
      rready = 1'b0;
    end
  endtask

  task automatic ck_reg(input string n, input logic [11:0] a,
                        input logic [31:0] exp);
    logic [31:0] got;
    begin
      axil_read(a, got);
      checks++;
      if (got === exp) $display("  PASS  %s (0x%08h)", n, got);
      else begin
        errors++;
        $display("  FAIL  %s: got 0x%08h expected 0x%08h", n, got, exp);
      end
    end
  endtask

  // ------------------------------------------------------------- helpers
  function automatic logic [31:0] mk_desc(input logic [5:0] slot,
                                          input logic [5:0] phys,
                                          input logic [7:0] gen,
                                          input logic [3:0] tag,
                                          input logic [3:0] tenant);
    mk_desc = {tenant, tag, gen, 2'd0, phys, 2'd0, slot};
  endfunction

  // is_read=1 at bit 4, sig_check at bit 5, arlen at [15:8]
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

  // lifecycle op, raw slot mode (use_desc = 0)
  task automatic lc_op(input lc_event_e ev, input logic [5:0] slot);
    begin
      axil_write(R_CMD_DESC, mk_desc(slot, 6'd9, 8'd0, 4'd0, 4'd1));
      axil_write(R_CMD_CFG,  {29'd0, ev});
      axil_write(R_CMD_GO,   32'h1);
    end
  endtask

  task automatic do_reuse(input logic [5:0] slot, input logic [5:0] phys);
    begin
      axil_write(R_REUSE_CFG, {12'd0, 4'd1, 2'd0, phys, 2'd0, slot});
      axil_write(R_REUSE_GO,  32'h1);
      repeat (4) @(posedge clk);
    end
  endtask

  logic [31:0] v;

  initial begin
    awaddr='0; awvalid=0; wdata='0; wstrb=0; wvalid=0; bready=0;
    araddr='0; arvalid=0; rready=0;

    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    $display("\n=== 1. AXI4-Lite control plane ===");
    ck_reg("ID magic", R_ID, 32'h4C47_5031);
    axil_write(R_SCRATCH0, 32'hDEAD_BEEF);
    ck_reg("scratch register read/write", R_SCRATCH0, 32'hDEAD_BEEF);

    $display("\n=== 2. DEFAULT DENY: no window programmed ===");
    axil_write(R_CTRL, (32'h1) | 32'h10);   // bit 4 = sig_check_en                       // start
    issue_read(40'h00_8000_0000, 8'd3, 4'd0);
    repeat (20) @(posedge clk);
    ck_reg("unprogrammed window refuses the read", R_C_WIN_REF, 32'd1);
    ck_reg("no AR was ever accepted",              R_C_ACCEPT,  32'd0);
    ck("monitor saw zero AR handshakes", ar_seen == 0);

    $display("\n=== 3. Program the scratch window ===");
    axil_write(R_BASE_LO,  WIN_BASE[31:0]);
    axil_write(R_BASE_HI,  {24'd0, WIN_BASE[39:32]});
    axil_write(R_LIMIT_LO, WIN_LIMIT[31:0]);
    axil_write(R_LIMIT_HI, {24'd0, WIN_LIMIT[39:32]});
    mon_base  = WIN_BASE;
    mon_limit = WIN_LIMIT;
    mon_armed = 1'b1;
    axil_read(R_STATUS, v);
    ck("STATUS.window_valid is set", v[19] === 1'b1);

    $display("\n=== 4. In-window read completes ===");
    issue_read(WIN_BASE, 8'd3, 4'd1, 1'b1, SIG_GOOD);   // 4 beats x 16 B
    repeat (60) @(posedge clk);
    ck_reg("dispatch counted",  R_C_DISPATCH, 32'd1);
    ck_reg("AR accepted",       R_C_ACCEPT,   32'd1);
    ck_reg("RLAST completed",   R_C_COMPLETE, 32'd1);
    ck_reg("no payload mismatch on a matching signature", R_C_PAY_MM, 32'd0);
    ck("monitor saw exactly one AR handshake", ar_seen == 1);

    $display("\n=== 5. Payload mismatch is detected ===");
    issue_read(WIN_BASE + 40'h100, 8'd0, 4'd2, 1'b1, 32'hDEAD_0000);
    repeat (60) @(posedge clk);
    ck_reg("payload mismatch counted", R_C_PAY_MM, 32'd1);

    $display("\n=== 6. OUT OF WINDOW below base is refused ===");
    issue_read(WIN_BASE - 40'h10, 8'd0, 4'd3);
    repeat (30) @(posedge clk);
    ck_reg("below-base read refused", R_C_WIN_REF, 32'd2);
    ck("monitor still saw only two AR handshakes", ar_seen == 2);

    $display("\n=== 7. OUT OF WINDOW above limit is refused ===");
    issue_read(WIN_LIMIT - 40'h10, 8'd3, 4'd4);        // 64 B from limit-16
    repeat (30) @(posedge clk);
    ck_reg("above-limit read refused", R_C_WIN_REF, 32'd3);

    $display("\n=== 8. A 4 KiB-crossing burst is refused ===");
    issue_read(WIN_BASE + 40'h0FF0, 8'd3, 4'd5);       // 64 B from ...FF0
    repeat (30) @(posedge clk);
    ck_reg("4 KiB crossing refused", R_C_BND_REF, 32'd1);

    $display("\n=== 9. A misaligned address is refused ===");
    issue_read(WIN_BASE + 40'h8, 8'd0, 4'd6);
    repeat (30) @(posedge clk);
    ck_reg("misaligned read refused", R_C_ALN_REF, 32'd1);

    $display("\n=== 10. UNSAFE MODES CANNOT WIDEN THE WINDOW ===");
    // both deliberately unsafe bits on: unsafe_bypass and no_generation_check
    axil_write(R_CTRL, (32'h1 | 32'h4 | 32'h8) | 32'h10);   // bit 4 = sig_check_en
    issue_read(40'h00_0000_1000, 8'd0, 4'd7);          // low DDR, Linux country
    repeat (30) @(posedge clk);
    ck_reg("unsafe mode STILL refuses an out-of-window read",
           R_C_WIN_REF, 32'd4);
    issue_read(40'h00_7FFF_0000, 8'd0, 4'd8);
    repeat (30) @(posedge clk);
    ck_reg("unsafe mode refuses a second out-of-window read",
           R_C_WIN_REF, 32'd5);
    ck("monitor saw no extra AR handshake in unsafe mode", ar_seen == 2);
    axil_write(R_CTRL, (32'h1) | 32'h10);   // bit 4 = sig_check_en

    $display("\n=== 11. WINDOW_LOCK freezes base and limit ===");
    axil_write(R_WIN_LOCK, LOCK_MAGIC);
    axil_write(R_BASE_LO,  32'h0000_0000);
    axil_write(R_LIMIT_LO, 32'hFFFF_FFFF);
    ck_reg("base survived a post-lock write",  R_BASE_LO,  WIN_BASE[31:0]);
    ck_reg("limit survived a post-lock write", R_LIMIT_LO, WIN_LIMIT[31:0]);

    $display("\n=== 12. Tag uniqueness ===");
    // tag 9 issued twice; the second must be refused while the first is live
    axil_write(R_CMD_DESC,    mk_desc(6'd5, 6'd9, 8'd0, 4'd9, 4'd1));
    axil_write(R_CMD_ADDR_LO, WIN_BASE[31:0]);
    axil_write(R_CMD_ADDR_HI, 32'd0);
    axil_write(R_CMD_CFG,     mk_read_cfg(8'd15, 1'b0));  // 16 beats, slow
    axil_write(R_CMD_GO,      32'h1);
    axil_write(R_CMD_GO,      32'h1);                     // same tag again
    repeat (80) @(posedge clk);
    ck_reg("duplicate live tag refused", R_C_TAG_CONF, 32'd1);

    $display("\n=== 13. The lifecycle interlock, through the register path ===");
    do_reuse(6'd20, 6'd30);                     // fresh slot, grant expected
    lc_op(LC_ACQUIRE, 6'd20);
    lc_op(LC_ADMIT,   6'd20);
    lc_op(LC_ISSUE,   6'd20);                   // inflight = 1
    repeat (6) @(posedge clk);
    do_reuse(6'd20, 6'd31);                     // must be REFUSED
    ck_reg("reuse refused while inflight > 0", R_C_REUSE_REF, 32'd1);

    axil_write(R_CTRL, (32'h1 | 32'h4) | 32'h10);   // bit 4 = sig_check_en          // unsafe_bypass on
    do_reuse(6'd20, 6'd31);                     // now commits, and is counted
    ck_reg("unsafe reuse committed and counted", R_C_UNSAFE, 32'd1);
    axil_write(R_CTRL, (32'h1) | 32'h10);   // bit 4 = sig_check_en

    repeat (40) @(posedge clk);
    $display("\n%0d checks, %0d failures", checks, errors);
    // NOT a ternary inside $display: XSim packs it into an integer and
    // prints a number, which is how a FAIL once read as a pass.
    if (errors == 0) $display("TB PASS"); else $display("TB FAIL");
    $finish;
  end

  initial begin
    #500000;
    $display("TIMEOUT");
    $display("TB FAIL");
    $finish;
  end
endmodule
