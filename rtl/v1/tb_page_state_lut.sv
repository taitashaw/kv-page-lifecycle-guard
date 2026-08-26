// tb_page_state_lut.sv
// Self-checking testbench for the lifecycle interlock.
//
// Reproduces the required sequence exactly:
//   refcount = 1, inflight = 1
//   RELEASE        -> refcount = 0
//   REUSE_REQUEST  -> rejected            <-- the interlock
//   COMPLETE       -> inflight = 0
//   REUSE_REQUEST  -> permitted, generation advances
//   stale completion -> rejected
//
// Then runs the IDENTICAL sequence with i_unsafe_bypass = 1 to show the
// corruption the interlock prevents. Both runs are captured for the ILA.

`include "lifecycle_pkg.sv"

module tb_page_state_lut;
  import lifecycle_pkg::*;

  logic clk = 0, rst_n = 0, unsafe = 0;
  always #5 clk = ~clk;

  lc_cmd_t            cmd;
  logic [SLOT_W-1:0]  slot;
  logic               reuse_req;
  logic [PHYS_W-1:0]  reuse_phys;
  lc_rsp_t            rsp;
  logic               grant, refused;
  logic [GEN_W-1:0]   new_gen;
  logic               blocked, committed, stale;
  logic [31:0]        c_ref, c_stale, c_unsafe;

  int errors = 0, checks = 0;

  page_state_lut #(.UNSAFE_BYPASS_SUPPORTED(1), .NAIVE_NO_GEN_SUPPORTED(1)) dut (
    .clk(clk), .rst_n(rst_n), .i_unsafe_bypass(unsafe),
    .i_no_generation_check(1'b0),   // generation tagging stays ON in this TB
    .i_cmd(cmd), .i_slot(slot),
    .i_reuse_req(reuse_req), .i_reuse_slot(slot),
    .i_reuse_phys(reuse_phys), .i_reuse_tenant(4'd1),
    .o_rsp(rsp), .o_reuse_grant(grant), .o_reuse_refused(refused),
    .o_reuse_new_gen(new_gen),
    .o_unsafe_reuse_blocked(blocked), .o_unsafe_reuse_committed(committed),
    .o_stale_descriptor(stale),
    .o_cnt_refused(c_ref), .o_cnt_stale(c_stale), .o_cnt_unsafe_commit(c_unsafe)
  );

  task automatic ck(input string name, input bit cond);
    checks++;
    if (cond) $display("  PASS  %s", name);
    else begin errors++; $display("  FAIL  %s", name); end
  endtask

  task automatic do_cmd(input lc_event_e ev, input bit use_desc = 0,
                        input logic [GEN_W-1:0] exp_gen = 0);
    @(negedge clk);
    cmd.valid    = 1'b1;
    cmd.ev       = ev;
    cmd.use_desc = use_desc;
    cmd.desc     = '{lifecycle_slot: slot, phys_idx: reuse_phys,
                     expected_generation: exp_gen, transaction_tag: 4'd0,
                     tenant: 4'd1};
    @(negedge clk);
    cmd.valid = 1'b0;
    @(posedge clk);
  endtask

  task automatic do_reuse();
    @(negedge clk);
    reuse_req = 1'b1;
    @(negedge clk);
    reuse_req = 1'b0;
    @(posedge clk);
  endtask

  initial begin
    cmd = '0; slot = 5'd7; reuse_phys = 6'd3; reuse_req = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    $display("\n=== SAFE RUN: the interlock is enabled ===");
    unsafe = 0;

    do_reuse();                       // install the object at slot 7
    ck("install: first reuse on an empty slot is granted", grant);

    do_cmd(LC_ACQUIRE);               // refcount 1
    ck("ACQUIRE: refcount == 1", dut.ram[7].refcount == 1);
    do_cmd(LC_ADMIT);                 // reservation 1
    do_cmd(LC_ISSUE);                 // reservation 0, inflight 1
    ck("ISSUE: inflight == 1", dut.ram[7].inflight == 1);
    ck("ISSUE: reservation back to 0", dut.ram[7].reservation == 0);

    ck("state is refcount=1, inflight=1 as required",
       dut.ram[7].refcount == 1 && dut.ram[7].inflight == 1);

    do_cmd(LC_RELEASE);               // refcount 0, inflight still 1
    ck("RELEASE: refcount == 0", dut.ram[7].refcount == 0);
    ck("RELEASE: inflight STILL 1, the page is DRAINING",
       dut.ram[7].inflight == 1);
    ck("draining predicate is true", is_draining(dut.ram[7]));
    ck("evictable predicate is FALSE despite refcount 0",
       !is_evictable(dut.ram[7]));

    do_reuse();
    ck("REUSE_REQUEST is REFUSED while inflight > 0", refused && !grant);
    ck("refusal counter incremented", c_ref == 1);
    ck("generation did NOT advance on a refused reuse",
       dut.ram[7].generation == 1);

    do_cmd(LC_COMPLETE);              // inflight 0
    ck("COMPLETE: inflight == 0", dut.ram[7].inflight == 0);
    ck("evictable is NOW true", is_evictable(dut.ram[7]));

    do_reuse();
    ck("REUSE_REQUEST is PERMITTED once quiescent", grant && !refused);
    ck("generation ADVANCED on the granted reuse",
       dut.ram[7].generation == 2);

    do_cmd(LC_COMPLETE, 1'b1, 8'd1);  // stale: descriptor expects generation 1
    ck("stale completion is REJECTED", rsp.err == ERR_STALE_DESC);
    ck("stale counter incremented", c_stale == 1);
    ck("stale completion did NOT touch inflight", dut.ram[7].inflight == 0);

    $display("\n=== UNSAFE RUN: identical sequence, interlock bypassed ===");
    unsafe = 1;
    slot = 5'd9;
    do_reuse();
    do_cmd(LC_ACQUIRE); do_cmd(LC_ADMIT); do_cmd(LC_ISSUE);
    do_cmd(LC_RELEASE);
    ck("unsafe: same draining state reached, refcount 0 inflight 1",
       dut.ram[9].refcount == 0 && dut.ram[9].inflight == 1);
    do_reuse();
    ck("unsafe: reuse is COMMITTED instead of refused", committed && grant);
    ck("unsafe: replacement inherits NON-ZERO inflight, old transfer will land on it",
       dut.ram[9].inflight == 1);
    ck("unsafe-commit counter incremented", c_unsafe == 1);

    $display("\n%0d checks, %0d failures", checks, errors);
    if (errors == 0) $display("TB PASS");
    else             $display("TB FAIL");
    $finish;
  end

  initial begin
    #20000;
    $display("TIMEOUT"); $finish;
  end
endmodule
