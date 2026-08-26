// tb_payload_corruption.sv
// Converts "a dangerous condition occurred" into "the dangerous condition
// produced a concrete correctness failure".
//
// A frame buffer holds one 32-bit signature per physical frame. A tagged
// transfer carries the signature it will deposit and the generation it expects.
// The frame buffer writes ONLY when the interlock validates the descriptor.
//
//   old page signature : 0xA5A5A5A5
//   new page signature : 0x5A5A5A5A
//
// THE CENTRAL FINDING, which these three scenarios exist to separate:
// the evictable interlock and generation tagging are TWO INDEPENDENT
// protections. Removing only the interlock does NOT corrupt anything, because
// generation tagging still rejects the stale completion. The naive design being
// argued against has NEITHER, and only that design actually loses data.
//
//   1. SAFE               interlock ON,  generation ON  -> reuse refused,
//                                                          payload 0x5A5A5A5A
//   2. UNSAFE_NO_INTERLOCK interlock OFF, generation ON  -> reuse commits, but
//                                                          the stale completion
//                                                          is STILL rejected;
//                                                          payload SURVIVES
//   3. UNSAFE_NAIVE       interlock OFF, generation OFF -> reuse commits, the
//                                                          stale completion
//                                                          LANDS, payload is
//                                                          overwritten with
//                                                          0xA5A5A5A5
//
// Every scenario uses a distinct lifecycle slot and a distinct physical frame,
// so no scenario can influence another's state or its frame buffer word.

`include "lifecycle_pkg.sv"

module tb_payload_corruption;
  import lifecycle_pkg::*;

  localparam logic [31:0] SIG_OLD = 32'hA5A5_A5A5;
  localparam logic [31:0] SIG_NEW = 32'h5A5A_5A5A;

  // scenario selectors
  localparam int MODE_SAFE          = 0;   // interlock ON,  generation ON
  localparam int MODE_NO_INTERLOCK  = 1;   // interlock OFF, generation ON
  localparam int MODE_NAIVE         = 2;   // interlock OFF, generation OFF

  logic clk = 0, rst_n = 0;

  // the two independent bypass controls
  logic unsafe = 0;   // i_unsafe_bypass       : removes the evictable interlock
  logic no_gen = 0;   // i_no_generation_check : removes generation tagging

  always #5 clk = ~clk;

  lc_cmd_t            cmd;
  logic [SLOT_W-1:0]  slot = 6'd7;
  logic [PHYS_W-1:0]  phys = 6'd3;
  logic               reuse_req = 0;
  lc_rsp_t            rsp;
  logic               grant, refused, blocked, committed, stale;
  logic [GEN_W-1:0]   new_gen;
  logic [31:0]        c_ref, c_stale, c_unsafe;

  // the frame buffer: the thing that actually gets corrupted
  logic [31:0] frame_buf [FRAMES];
  logic        payload_mismatch;
  int          errors = 0, checks = 0;

  page_state_lut #(.UNSAFE_BYPASS_SUPPORTED(1), .NAIVE_NO_GEN_SUPPORTED(1)) dut (
    .clk(clk), .rst_n(rst_n),
    .i_unsafe_bypass(unsafe), .i_no_generation_check(no_gen),
    .i_cmd(cmd), .i_slot(slot),
    .i_reuse_req(reuse_req), .i_reuse_slot(slot),
    .i_reuse_phys(phys), .i_reuse_tenant(4'd1),
    .o_rsp(rsp), .o_reuse_grant(grant), .o_reuse_refused(refused),
    .o_reuse_new_gen(new_gen),
    .o_unsafe_reuse_blocked(blocked), .o_unsafe_reuse_committed(committed),
    .o_stale_descriptor(stale),
    .o_cnt_refused(c_ref), .o_cnt_stale(c_stale), .o_cnt_unsafe_commit(c_unsafe)
  );

  task automatic ck(input string n, input bit c);
    checks++;
    if (c) $display("  PASS  %s", n);
    else begin errors++; $display("  FAIL  %s", n); end
  endtask

  task automatic lc(input lc_event_e ev, input bit ud = 0,
                    input logic [GEN_W-1:0] g = 0);
    @(negedge clk);
    cmd.valid = 1; cmd.ev = ev; cmd.use_desc = ud;
    cmd.desc  = '{lifecycle_slot: slot, phys_idx: phys,
                  expected_generation: g, transaction_tag: 4'd0, tenant: 4'd1};
    @(negedge clk); cmd.valid = 0; @(posedge clk);
  endtask

  // A tagged completion carrying a payload. The frame buffer writes ONLY if
  // the interlock accepted the descriptor.
  task automatic complete_with_payload(input logic [GEN_W-1:0] exp_gen,
                                       input logic [31:0] sig);
    lc(LC_COMPLETE, 1'b1, exp_gen);
    if (rsp.ok) frame_buf[phys] = sig;
  endtask

  task automatic reuse();
    @(negedge clk); reuse_req = 1; @(negedge clk); reuse_req = 0; @(posedge clk);
  endtask

  // ------------------------------------------------------------------------
  // Common preamble: install an owner, drive it to the DRAINING state
  //   refcount == 0 (logically released) but inflight == 1 (transfer in air).
  // ------------------------------------------------------------------------
  task automatic drive_to_draining(input string tag);
    reuse();                                   // install OLD owner, generation 1
    ck($sformatf("%s: owner installed, generation 1", tag),
       grant && dut.ram[slot].generation == 1);
    frame_buf[phys] = SIG_OLD;
    lc(LC_ACQUIRE); lc(LC_ADMIT); lc(LC_ISSUE); // OLD transfer outstanding
    ck($sformatf("%s: old owner holds A5A5A5A5", tag),
       frame_buf[phys] == SIG_OLD);

    lc(LC_RELEASE);                            // refcount 0, inflight 1
    ck($sformatf("%s: DRAINING, refcount 0 inflight 1", tag),
       dut.ram[slot].refcount == 0 && dut.ram[slot].inflight == 1);
  endtask

  task automatic scenario(input int mode, input string tag,
                          input logic [SLOT_W-1:0] s,
                          input logic [PHYS_W-1:0] p);
    $display("\n=== %s ===", tag);

    // distinct slot and frame per scenario: no cross-scenario interference
    slot   = s;
    phys   = p;
    unsafe = (mode != MODE_SAFE);
    no_gen = (mode == MODE_NAIVE);
    @(negedge clk);                            // let the controls settle

    drive_to_draining(tag);

    reuse();                                   // the decisive moment

    if (mode == MODE_SAFE) begin
      // ------------------------------------------------ 1. both protections
      ck($sformatf("%s: reuse REFUSED while inflight > 0", tag),
         refused && !grant);
      ck($sformatf("%s: generation did NOT advance on the refused reuse", tag),
         dut.ram[slot].generation == 1);

      complete_with_payload(8'd1, SIG_OLD);    // old transfer drains legitimately
      ck($sformatf("%s: legitimate completion accepted, inflight 0", tag),
         dut.ram[slot].inflight == 0);

      reuse();                                 // now safe
      ck($sformatf("%s: reuse permitted after quiescence", tag),
         grant && dut.ram[slot].generation == 2);
      frame_buf[phys] = SIG_NEW;               // new owner installs its data

      // a LATE duplicate of the old transfer arrives, still expecting gen 1
      complete_with_payload(8'd1, SIG_OLD);
      payload_mismatch = (frame_buf[phys] != SIG_NEW);
      ck($sformatf("%s: stale completion REJECTED by generation", tag),
         stale && rsp.err == ERR_STALE_DESC);
      ck($sformatf("%s: PAYLOAD INTACT, new owner still reads 5A5A5A5A", tag),
         !payload_mismatch && frame_buf[phys] == SIG_NEW);

    end else if (mode == MODE_NO_INTERLOCK) begin
      // ------------------------------ 2. interlock removed, generation kept
      // This is the scenario that proves the two protections are INDEPENDENT.
      ck($sformatf("%s: reuse COMMITTED while inflight > 0", tag),
         committed && grant);
      ck($sformatf("%s: replacement inherits NON-ZERO inflight", tag),
         dut.ram[slot].inflight == 1);
      ck($sformatf("%s: generation ADVANCED to 2 on the unsafe commit", tag),
         dut.ram[slot].generation == 2);

      frame_buf[phys] = SIG_NEW;               // new owner installs its data
      // the OLD transfer now lands, still expecting generation 1
      complete_with_payload(8'd1, SIG_OLD);
      payload_mismatch = (frame_buf[phys] != SIG_NEW);

      ck($sformatf("%s: stale completion STILL REJECTED, by generation alone", tag),
         stale && rsp.err == ERR_STALE_DESC);
      ck($sformatf("%s: PAYLOAD SURVIVES without the interlock, reads 5A5A5A5A", tag),
         !payload_mismatch && frame_buf[phys] == SIG_NEW);
      ck($sformatf("%s: rejected completion did not touch inflight", tag),
         dut.ram[slot].inflight == 1);
      $display("  NOTE  %s: generation tagging is an INDEPENDENT SECOND LINE", tag);
      $display("        OF DEFENCE. The evictable interlock was bypassed and the");
      $display("        payload was still not corrupted.");

    end else begin
      // ---------------------------------- 3. the genuinely naive design
      // No evictable interlock AND no generation tags. This is the real-world
      // implementation the artifact argues against.
      ck($sformatf("%s: reuse COMMITTED while inflight > 0", tag),
         committed && grant);
      ck($sformatf("%s: replacement inherits NON-ZERO inflight", tag),
         dut.ram[slot].inflight == 1);

      frame_buf[phys] = SIG_NEW;               // new owner installs its data
      ck($sformatf("%s: new owner installed 5A5A5A5A", tag),
         frame_buf[phys] == SIG_NEW);

      // the OLD transfer now lands. With no generation tag there is nothing
      // left to reject it: it resolves on slot + frame identity and writes.
      complete_with_payload(8'd1, SIG_OLD);
      payload_mismatch = (frame_buf[phys] != SIG_NEW);

      ck($sformatf("%s: stale completion ACCEPTED, nothing left to reject it", tag),
         !stale && rsp.ok && rsp.err == ERR_NONE);
      ck($sformatf("%s: payload_mismatch == 1", tag),
         payload_mismatch == 1'b1);
      ck($sformatf("%s: PAYLOAD CORRUPTED, frame_buf[%0d] == A5A5A5A5", tag, phys),
         frame_buf[phys] == SIG_OLD);
      ck($sformatf("%s: stale completion also decremented the NEW owner's inflight", tag),
         dut.ram[slot].inflight == 0);
    end
  endtask

  initial begin
    cmd = '0; payload_mismatch = 0;
    for (int i = 0; i < FRAMES; i++) frame_buf[i] = 32'h0;
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

    scenario(MODE_SAFE,         "SAFE",                6'd7,  6'd3);
    scenario(MODE_NO_INTERLOCK, "UNSAFE_NO_INTERLOCK", 6'd9,  6'd11);
    scenario(MODE_NAIVE,        "UNSAFE_NAIVE",        6'd12, 6'd20);

    // cross-scenario isolation: each frame still holds its own scenario's value
    $display("\n=== ISOLATION ===");
    ck("SAFE frame 3 untouched by later scenarios",
       frame_buf[6'd3] == SIG_NEW);
    ck("UNSAFE_NO_INTERLOCK frame 11 untouched by later scenarios",
       frame_buf[6'd11] == SIG_NEW);
    ck("UNSAFE_NAIVE frame 20 is the only corrupted frame",
       frame_buf[6'd20] == SIG_OLD);

    $display("\n%0d checks, %0d failures", checks, errors);
    // NOTE: a ternary between two string literals is packed to an integer by
    // XSim, so branch explicitly rather than $display'ing the ternary.
    if (errors == 0) $display("TB PASS");
    else             $display("TB FAIL");
    $finish;
  end

  initial begin #20000; $display("TIMEOUT"); $finish; end
endmodule
