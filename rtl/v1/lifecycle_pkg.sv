// lifecycle_pkg.sv
// Frozen synthesizable interface for the lifecycle-safety artifact (V1).
//
// This package is the RTL expression of the contract in
// model/SWEEP_B_ANALYSIS_PLAN_004.json and model/gm/types.py.
//
// V1 SCOPE: the tagged lifecycle interlock only. The EDF/deficit arbiter and
// the credit accountant are DELIBERATELY EXCLUDED: Sweep B closed the C+D
// performance branch, so they carry no claim and are unnecessary here.
//
// DDR_SERVICE_START is MODEL-ONLY. PL logic behind SmartConnect and the Zynq
// memory controller cannot observe when the DDR controller begins servicing a
// request, so the RTL/HIL contract uses AXI_FIRST_DATA instead.

`ifndef LIFECYCLE_PKG_SV
`define LIFECYCLE_PKG_SV

package lifecycle_pkg;

  parameter int unsigned SLOTS      = 64;
  parameter int unsigned FRAMES     = 64;
  parameter int unsigned TAGS       = 16;

  parameter int unsigned SLOT_W     = $clog2(SLOTS);
  parameter int unsigned PHYS_W     = $clog2(FRAMES);
  parameter int unsigned TAG_W      = $clog2(TAGS);
  parameter int unsigned GEN_W      = 8;
  parameter int unsigned REF_W      = 8;
  parameter int unsigned RSV_W      = 8;
  parameter int unsigned INF_W      = 6;
  parameter int unsigned FILL_W     = 4;
  parameter int unsigned TENANT_W   = 4;

  // ---------------------------------------------------------------- events
  // The four OBSERVABLE transaction events. DDR_SERVICE_START is absent by
  // design: it is not observable in hardware.
  typedef enum logic [2:0] {
    TXN_DISPATCH       = 3'd0,
    TXN_AXI_ACCEPT     = 3'd1,   // AR/AW handshake; outstanding increments HERE
    TXN_AXI_FIRST_DATA = 3'd2,   // first R beat, where relevant
    TXN_AXI_COMPLETE   = 3'd3,   // RLAST or B handshake
    TXN_CANCEL         = 3'd4    // pre-issue only
  } txn_event_e;

  // The six lifecycle events. ADMIT does NOT create a logical reference.
  typedef enum logic [2:0] {
    LC_ACQUIRE  = 3'd0,   // logical_refcount +1
    LC_ADMIT    = 3'd1,   // reservation      +1
    LC_ISSUE    = 3'd2,   // reservation -1, inflight +1
    LC_COMPLETE = 3'd3,   // inflight         -1
    LC_RELEASE  = 3'd4,   // logical_refcount -1
    LC_CANCEL   = 3'd5,   // reservation      -1  (pre-issue only)
    LC_FILL_ST  = 3'd6,   // fill_pending     +1
    LC_FILL_DN  = 3'd7    // fill_pending     -1
  } lc_event_e;

  // ------------------------------------------------------------ error codes
  typedef enum logic [3:0] {
    ERR_NONE            = 4'd0,
    ERR_UNDERFLOW       = 4'd1,
    ERR_OVERFLOW        = 4'd2,
    ERR_STALE_DESC      = 4'd3,   // expected_generation mismatch
    ERR_UNSAFE_REUSE    = 4'd4,   // reuse attempted while not evictable
    ERR_CROSS_TENANT    = 4'd5,
    ERR_SLOT_INVALID    = 4'd6,
    ERR_TAG_REUSE       = 4'd7,   // tag already outstanding
    ERR_TAG_UNKNOWN     = 4'd8,   // completion for a tag never accepted
    ERR_CANCEL_AFTER_ACC= 4'd9
  } err_e;

  // ------------------------------------------------------ lifecycle entry
  typedef struct packed {
    logic                valid;
    logic [PHYS_W-1:0]   phys_idx;
    logic [GEN_W-1:0]    generation;
    logic [REF_W-1:0]    refcount;      // ACQUIRE / RELEASE
    logic [RSV_W-1:0]    reservation;   // ADMIT   / ISSUE or CANCEL
    logic [INF_W-1:0]    inflight;      // ISSUE   / COMPLETE
    logic [FILL_W-1:0]   fill_pending;  // FILL_START / FILL_DONE
    logic [TENANT_W-1:0] tenant;
  } lc_entry_t;

  // ------------------------------------------------- bounded descriptor
  // A descriptor NEVER carries a pointer. Resolution is exactly:
  //   entry = lifecycle_ram[lifecycle_slot]
  //   valid = entry.phys_idx == d.phys_idx && entry.generation == d.expected_generation
  typedef struct packed {
    logic [SLOT_W-1:0]   lifecycle_slot;
    logic [PHYS_W-1:0]   phys_idx;
    logic [GEN_W-1:0]    expected_generation;
    logic [TAG_W-1:0]    transaction_tag;
    logic [TENANT_W-1:0] tenant;
  } descriptor_t;

  // ------------------------------------------------------------- commands
  typedef struct packed {
    logic                valid;
    lc_event_e           ev;
    descriptor_t         desc;
    logic                use_desc;   // 1: validate generation, 0: raw slot op
  } lc_cmd_t;

  typedef struct packed {
    logic                valid;
    logic                ok;
    err_e                err;
    logic                evictable;  // safe-reuse predicate AFTER the update
    lc_entry_t           entry;
  } lc_rsp_t;

  // ------------------------------------------------- safe-reuse predicate
  // Generation is NOT part of this. Generation validates a DESCRIPTOR; this
  // predicate governs FRAME REUSE.
  function automatic logic is_evictable(input lc_entry_t e);
    return (e.refcount == '0) && (e.reservation == '0)
        && (e.inflight == '0) && (e.fill_pending == '0);
  endfunction

  function automatic logic is_draining(input lc_entry_t e);
    return (e.refcount == '0) && (e.inflight != '0);
  endfunction

  function automatic logic desc_valid(input lc_entry_t e, input descriptor_t d);
    return e.valid && (e.phys_idx == d.phys_idx)
        && (e.generation == d.expected_generation);
  endfunction

  // ------------------------------------------- NAIVE descriptor resolution
  // The real-world implementation this artifact argues against: a design with
  // NO generation tag at all, which resolves a completion on slot + frame
  // identity alone. Present ONLY as the unsafe baseline for the side-by-side
  // demonstration; never used on the safe path.
  //
  // Note carefully: desc_valid() and is_evictable() are TWO INDEPENDENT
  // protections. Removing the evictable interlock alone does NOT corrupt a
  // payload, because the generation comparison below still rejects the stale
  // completion. Both must be removed before the payload is actually clobbered.
  function automatic logic desc_valid_no_gen(input lc_entry_t e,
                                             input descriptor_t d);
    return e.valid && (e.phys_idx == d.phys_idx);
  endfunction

endpackage

`endif
