// tb_wedge_poll.sv
// Drive the design until it stops making progress, then ask the ONLY question
// that matters for the claim under test: with the core wedged, does the
// host-visible register surface differ from the healthy quiescent surface?

`include "lifecycle_pkg.sv"

module tb_wedge_poll;
  import lifecycle_pkg::*;

  localparam int AW = 40;
  localparam int DW = 128;

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
  localparam logic [11:0] R_C_COMPLETE  = 12'h074;
  localparam logic [11:0] R_C_DISPATCH  = 12'h088;
  localparam logic [11:0] R_C_ACCEPT    = 12'h08C;
  localparam logic [11:0] R_C_REQ_DROP  = 12'h094;
  localparam logic [11:0] R_C_LC_ERR    = 12'h09C;
  localparam logic [11:0] R_OUTSTANDING = 12'h0BC;

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

  wire [TAG_W-1:0] m_arid;  wire [AW-1:0] m_araddr;  wire [7:0] m_arlen;
  wire [2:0] m_arsize; wire [1:0] m_arburst; wire m_arlock;
  wire [3:0] m_arcache; wire [2:0] m_arprot; wire [3:0] m_arqos;
  wire m_arvalid;  logic m_arready;
  logic [TAG_W-1:0] m_rid; logic [DW-1:0] m_rdata; logic [1:0] m_rresp;
  logic m_rlast; logic m_rvalid; wire m_rready;
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
  logic [TAG_W-1:0] q_id [$];
  logic [7:0]       q_len[$];
  int               svc_lat = 3;      // knob: cycles from AR to first beat

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
        repeat (svc_lat) @(posedge clk);
        for (int b = 0; b <= int'(len); b++) begin
          @(negedge clk);
          m_rvalid = 1'b1; m_rid = id;
          m_rdata  = {96'd0, (b == 0) ? SIG_GOOD : 32'h0};
          m_rlast  = (b == int'(len)); m_rresp = 2'b00;
          @(posedge clk);
          while (!m_rready) @(posedge clk);
        end
        @(negedge clk);
        m_rvalid = 1'b0; m_rlast = 1'b0;
      end
    end
  end

  task automatic axil_write(input logic [11:0] a, input logic [31:0] d);
    bit aw_go, w_go;
    begin
      @(negedge clk);
      awaddr = a; awvalid = 1'b1; wdata = d; wstrb = 4'hF; wvalid = 1'b1;
      bready = 1'b1;
      forever begin
        aw_go = awvalid & awready; w_go = wvalid & wready;
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
                            input logic [3:0] tag);
    begin
      axil_write(R_CMD_DESC,    mk_desc(6'd5, 6'd9, 8'd0, tag, 4'd1));
      axil_write(R_CMD_ADDR_LO, a[31:0]);
      axil_write(R_CMD_ADDR_HI, {24'd0, a[39:32]});
      axil_write(R_CMD_SIG,     SIG_GOOD);
      axil_write(R_CMD_CFG,     mk_read_cfg(len, 1'b0));
      axil_write(R_CMD_GO,      32'h1);
    end
  endtask

  logic [31:0] st, disp, acc, comp, outst, reqdrop, lcerr;
  logic [31:0] healthy_status, healthy_outst;

  task automatic poll(input string tag);
    begin
      axil_read(R_STATUS,      st);
      axil_read(R_C_DISPATCH,  disp);
      axil_read(R_C_ACCEPT,    acc);
      axil_read(R_C_COMPLETE,  comp);
      axil_read(R_OUTSTANDING, outst);
      axil_read(R_C_REQ_DROP,  reqdrop);
      axil_read(R_C_LC_ERR,    lcerr);
      $display("  %-26s STATUS=0x%08h  IDLE=%0b BUSY=%0b REQ_EMPTY=%0b REQ_FULL=%0b OUTST=%0d | disp=%0d acc=%0d comp=%0d reqdrop=%0d lcerr=%0d",
               tag, st, st[0], st[1], st[3], st[2], st[31:24],
               disp, acc, comp, reqdrop, lcerr);
    end
  endtask

  task automatic program_and_start;
    begin
      axil_write(R_CTRL, 32'h1);
      axil_write(R_BASE_LO,  WIN_BASE[31:0]);
      axil_write(R_BASE_HI,  {24'd0, WIN_BASE[39:32]});
      axil_write(R_LIMIT_LO, WIN_LIMIT[31:0]);
      axil_write(R_LIMIT_HI, {24'd0, WIN_LIMIT[39:32]});
    end
  endtask

  int  prev_comp;
  bit  wedged;

  initial begin
    awaddr='0; awvalid=0; wdata='0; wstrb=0; wvalid=0; bready=0;
    araddr='0; arvalid=0; rready=0;

    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);
    program_and_start();

    // -------------------------------------------------------------- healthy
    $display("\n=== EXP 0: healthy reference ===");
    for (int i = 0; i < 4; i++) begin
      issue_read(WIN_BASE + (i*40'h40), 8'd1, i[3:0]);
      repeat (40) @(posedge clk);
    end
    repeat (200) @(posedge clk);
    poll("healthy quiescent");
    healthy_status = st;
    healthy_outst  = st[31:24];

    // ---------------------------------------- EXP 1: latency sweep for wedge
    $display("\n=== EXP 1: sweep slave latency, look for loss of progress ===");
    wedged = 0;
    for (int L = 0; L <= 6 && !wedged; L++) begin
      svc_lat = L;
      axil_read(R_C_COMPLETE, comp);
      prev_comp = comp;
      for (int i = 0; i < 6; i++) begin
        issue_read(WIN_BASE + 40'h800 + (i*40'h40), 8'd1, i[3:0]);
      end
      repeat (400) @(posedge clk);
      axil_read(R_C_COMPLETE, comp);
      $display("  svc_lat=%0d  completes advanced %0d -> %0d", L, prev_comp, comp);
      if (comp == prev_comp) wedged = 1;
    end

    // ------------------------------- EXP 2: forced wedge via permanent stall
    // Model the wedged state: transactions accepted, completions never
    // arrive, further host requests pile in the request FIFO.
    $display("\n=== EXP 2: forced wedge (slave never returns R) ===");
    svc_lat = 1000000;                      // effectively never
    for (int i = 0; i < 4; i++) begin
      issue_read(WIN_BASE + 40'h1000 + (i*40'h40), 8'd1, i[3:0]);
      repeat (20) @(posedge clk);
    end
    repeat (400) @(posedge clk);
    poll("wedged (t0)");
    repeat (4000) @(posedge clk);
    poll("wedged (t0 + 4000 clk)");

    $display("\n=== EXP 3: is the wedged word distinguishable by polling? ===");
    $display("  healthy STATUS = 0x%08h", healthy_status);
    $display("  wedged  STATUS = 0x%08h", st);
    $display("  differ?          %0s", (healthy_status !== st) ? "YES" : "NO");
    $display("  bits that changed: 0x%08h", healthy_status ^ st);
    $display("  IDLE      %0b -> %0b", healthy_status[0],     st[0]);
    $display("  BUSY      %0b -> %0b", healthy_status[1],     st[1]);
    $display("  REQ_EMPTY %0b -> %0b", healthy_status[3],     st[3]);
    $display("  OUTST     %0d -> %0d", healthy_outst,         st[31:24]);
    $display("  sticky error bits [17:6] healthy=0x%03h wedged=0x%03h",
             healthy_status[17:6], st[17:6]);

    $display("\n=== EXP 4: ILA probe content at the wedge ===");
    $display("  ILA_OUTST(b79:78)=%0d  ILA_ARVALID(b58)=%0b ILA_ARREADY(b59)=%0b ILA_RVALID(b60)=%0b",
             ila[79:78], ila[58], ila[59], ila[60]);
    $display("  ILA_C_COMP(b191:176)=%0d", ila[191:176]);

    $display("\nDONE");
    $finish;
  end

  initial begin
    #4000000;
    $display("TIMEOUT (harness)");
    $finish;
  end
endmodule
