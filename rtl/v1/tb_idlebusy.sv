// tb_idlebusy.sv
// Is IDLE=0 && BUSY=0 really "a state the register map has no name for"?
// Reach it deliberately and read what the map says alongside it.

`include "lifecycle_pkg.sv"

module tb_idlebusy;
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
  localparam logic [11:0] R_C_REQ_DROP  = 12'h094;
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

  initial begin
    m_arready = 1'b1; m_rvalid = 0; m_rlast = 0; m_rresp = 2'b00;
    m_rid = '0; m_rdata = '0;
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

  logic [31:0] st, outst, reqdrop;

  task automatic poll(input string tag);
    begin
      axil_read(R_STATUS,      st);
      axil_read(R_OUTSTANDING, outst);
      axil_read(R_C_REQ_DROP,  reqdrop);
      $display("  %-30s STATUS=0x%08h IDLE=%0b BUSY=%0b REQ_FULL=%0b REQ_EMPTY=%0b OUTST_field=%0d OUTST_reg(0x0BC)=%0d REQ_DROP=%0d",
               tag, st, st[0], st[1], st[2], st[3], st[31:24], outst, reqdrop);
    end
  endtask

  initial begin
    awaddr='0; awvalid=0; wdata='0; wstrb=0; wvalid=0; bready=0;
    araddr='0; arvalid=0; rready=0;
    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    axil_write(R_BASE_LO,  WIN_BASE[31:0]);
    axil_write(R_BASE_HI,  {24'd0, WIN_BASE[39:32]});
    axil_write(R_LIMIT_LO, WIN_LIMIT[31:0]);
    axil_write(R_LIMIT_HI, {24'd0, WIN_LIMIT[39:32]});

    $display("\n=== window armed, CTRL.start = 0, no requests ===");
    poll("start=0, fifo empty");

    $display("\n=== queue one read request while start = 0 ===");
    // rd_req_valid = ~req_empty & rq_is_read & ctrl_start -> never dispatches
    axil_write(R_CMD_DESC,    mk_desc(6'd5, 6'd9, 8'd0, 4'd1, 4'd1));
    axil_write(R_CMD_ADDR_LO, WIN_BASE[31:0]);
    axil_write(R_CMD_ADDR_HI, 32'd0);
    axil_write(R_CMD_SIG,     SIG_GOOD);
    axil_write(R_CMD_CFG,     {16'd0, 8'd1, 2'd0, 1'b0, 1'b1, 1'b0, 3'd0});
    axil_write(R_CMD_GO,      32'h1);
    repeat (200) @(posedge clk);
    poll("1 req queued, undispatched");

    $display("\n=== push CMD_GO repeatedly to see REQ_FULL and REQ_DROP ===");
    for (int i = 0; i < 12; i++) begin
      axil_write(R_CMD_GO, 32'h1);
      poll($sformatf("after CMD_GO #%0d", i+2));
    end

    $display("\nDONE");
    $finish;
  end

  initial begin #900000; $display("TIMEOUT"); $finish; end
endmodule
