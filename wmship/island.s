// island.s — the near page: every entry stub, and nothing else.
//
// Round 27 changes two things about the round-25 stub set:
//
//  1. the site patch is ONE word, a *direct* `b` to a stub in this page (4 bytes, not 12), and
//     the rejoin is a *direct* `b` back to `site+12`. Both are only encodable if this page is
//     within +-128 MB of the patched site, which is what `p27install.py` enforces before it
//     writes anything. No `br` into __TEXT is involved anywhere.
//  2. the page is *relocated* after assembly (link offset -> an address inside the WM), so it
//     must contain no `adrp`. Literals are reached with `adr` (PC-relative, +-1 MB) and every
//     absolute transfer is a 4-byte word the installer fills in:
//        `bl <callee>`  (replay of the instruction(s) the patch overwrote)
//        `b  <rejoin>`  (back into __TEXT)
//        `.quad <body>` (the far half of the payload, called with `blr` — the only indirect
//                        transfer in the design, and the one round 26 proved works)
//
// `pacibsp` is never *called* from here: for a prologue site the stub replays it inline at the
// original SP and jumps to `entry+4`, so the rest of the WM's own prologue — including any
// `bl` whose LR must be `entry+12` — runs at its own address. That is the fix for the
// `_drvE_c0/_c1` bug (round 26 §4): there are no slots 0 and 1 to mis-wire.
//
// Assembled as *arm64*, not arm64e: the body and this page are raw code we copy into the WM,
// and arm64e C would emit `blraaz` for every indirect call, authenticating a raw pointer with
// the *calling process's* key IA — a guaranteed EXC_ARM_PAC_FAIL (measured: first install of
// this round died in `_wid_cgid` at `blraaz x9`). Plain arm64 `blr`/`ret` interoperate with the
// WM's arm64e functions because their own `pacibsp`/`retab` pair still signs and authenticates
// the LR they receive.
    .text
    .section __TEXT,__island,regular,pure_instructions
    .p2align 4

    .macro SAVEALL
    sub     sp, sp, #0xa0
    stp     x0, x1, [sp, #0x00]
    stp     x2, x3, [sp, #0x10]
    stp     x4, x5, [sp, #0x20]
    stp     x6, x7, [sp, #0x30]
    stp     x8, x9, [sp, #0x40]
    stp     x10, x11, [sp, #0x50]
    stp     x12, x13, [sp, #0x60]
    stp     x14, x15, [sp, #0x70]
    stp     x29, x30, [sp, #0x80]
    .endm

    .macro RESTOREALL
    ldp     x0, x1, [sp, #0x00]
    ldp     x2, x3, [sp, #0x10]
    ldp     x4, x5, [sp, #0x20]
    ldp     x6, x7, [sp, #0x30]
    ldp     x8, x9, [sp, #0x40]
    ldp     x10, x11, [sp, #0x50]
    ldp     x12, x13, [sp, #0x60]
    ldp     x14, x15, [sp, #0x70]
    ldp     x29, x30, [sp, #0x80]
    .endm

    .macro LOADLIT reg, lbl
    adr     \reg, \lbl
    ldr     \reg, [\reg]
    .endm

// ---------------------------------------------------------------- 1. birth site 0x1002ac2ac
// overwritten: bl driver   (one word; +4/+8 are left in place, we replay them here and rejoin
// at +12, exactly like the original three-call sequence)
    .globl  _i_drv
    .p2align 4
_i_drv:
    .long   0xD503245F             // bti c (arm64e word; assembled for arm64)
    SAVEALL
    mov     x1, x20
    mov     x2, x30
    LOADLIT x16, _i_drv_body
    blr     x16
    str     x0, [sp, #0x90]
    RESTOREALL
    ldr     x9, [sp, #0x90]
    add     sp, sp, #0xa0
    mov     x0, x9
    .globl  _i_drv_c0
_i_drv_c0:  .long 0                 // bl driver      (installer)
    .globl  _i_drv_c1
_i_drv_c1:  .long 0                 // bl site+4      (installer)
    .globl  _i_drv_c2
_i_drv_c2:  .long 0                 // bl site+8      (installer)
    .globl  _i_drv_ret
_i_drv_ret: .long 0                 // b  site+12     (installer)
    .p2align 3
    .globl  _i_drv_body
_i_drv_body: .quad 0                // absolute address of _p_drv (installer)

// ---------------------------------------------------------------- 2. second birth site 0x10029c1a8
    .globl  _i_drv2
    .p2align 4
_i_drv2:
    .long   0xD503245F             // bti c (arm64e word; assembled for arm64)
    SAVEALL
    mov     x1, x20
    mov     x2, x30
    LOADLIT x16, _i_drv2_body
    blr     x16
    str     x0, [sp, #0x90]
    RESTOREALL
    ldr     x9, [sp, #0x90]
    add     sp, sp, #0xa0
    mov     x0, x9
    .globl  _i_drv2_c0
_i_drv2_c0:  .long 0
    .globl  _i_drv2_c1
_i_drv2_c1:  .long 0
    .globl  _i_drv2_c2
_i_drv2_c2:  .long 0
    .globl  _i_drv2_ret
_i_drv2_ret: .long 0
    .p2align 3
    .globl  _i_drv2_body
_i_drv2_body: .quad 0

// ---------------------------------------------------------------- 3. driver entry 0x1002a6970
// pacibsp; mov x1,x30; bl X   ->  replay pacibsp inline, then run the rest at entry+4
    .globl  _i_drvE
    .p2align 4
_i_drvE:
    .long   0xD503245F             // bti c (arm64e word; assembled for arm64)
    SAVEALL
    mov     x1, x20
    mov     x2, x30
    LOADLIT x16, _i_drvE_body
    blr     x16
    str     x0, [sp, #0x90]
    RESTOREALL
    ldr     x9, [sp, #0x90]
    add     sp, sp, #0xa0
    mov     x0, x9
    .long   0xD503237F             // pacibsp, replayed at the original SP
    .globl  _i_drvE_ret
_i_drvE_ret: .long 0                // b entry+4      (installer)
    .p2align 3
    .globl  _i_drvE_body
_i_drvE_body: .quad 0

// ---------------------------------------------------------------- 4. compute site 0x1002a6f3c
// overwritten: bl Compute; +4 mov x19,x0; +8 sub x8,x29,#0x100 (both replayed inline)
    .globl  _i_cmp
    .p2align 4
_i_cmp:
    .long   0xD503245F             // bti c (arm64e word; assembled for arm64)
    SAVEALL
    mov     x0, x20
    LOADLIT x16, _i_cmp_body
    blr     x16
    RESTOREALL
    add     sp, sp, #0xa0
    .globl  _i_cmp_c0
_i_cmp_c0:  .long 0                 // bl Compute     (installer)
    mov     x19, x0
    sub     x8, x29, #0x100
    .globl  _i_cmp_ret
_i_cmp_ret: .long 0                 // b  site+12     (installer)
    .p2align 3
    .globl  _i_cmp_body
_i_cmp_body: .quad 0

// ---------------------------------------------------------------- 5/6. SkyLight keeper entries
// These two sites live in the dyld shared cache at 0x18c…, and the only region containing them
// is a 1.6 GB `res=1` reservation with no allocatable page within +-128 MB (measured: `vmmap`
// and a fixed-allocation sweep). So the keeper hook and its rejoin are `adrp` (+-4 GB, and the
// island is 2.2 GB away) — the one place on this build where a direct `b` is impossible. The
// three prologue words are replayed inline because the 12-byte hook overwrote all three.
    .globl  _i_k3d
    .p2align 4
_i_k3d:
    .long   0xD503245F             // bti c (arm64e word; assembled for arm64)
    SAVEALL
    mov     x29, sp
    LOADLIT x16, _i_k3d_body
    blr     x16
    RESTOREALL
    add     sp, sp, #0xa0
    .globl  _i_k3d_i1
_i_k3d_i1:  .long 0                 // pacibsp            (installer)
    .globl  _i_k3d_i2
_i_k3d_i2:  .long 0                 // sub sp, sp, #N     (installer)
    .globl  _i_k3d_i3
_i_k3d_i3:  .long 0                 // stp d9, d8, [sp,#] (installer)
    .globl  _i_k3d_ra
_i_k3d_ra:  .long 0                 // adrp x16, page     (installer)
    .globl  _i_k3d_rb
_i_k3d_rb:  .long 0                 // add  x16, x16, #lo (installer)
    .globl  _i_k3d_ret
_i_k3d_ret: .long 0xD61F0200        // br   x16           -> entry+12
    .p2align 3
    .globl  _i_k3d_body
_i_k3d_body: .quad 0

    .globl  _i_k2d
    .p2align 4
_i_k2d:
    .long   0xD503245F             // bti c (arm64e word; assembled for arm64)
    SAVEALL
    mov     x29, sp
    LOADLIT x16, _i_k2d_body
    blr     x16
    RESTOREALL
    add     sp, sp, #0xa0
    .globl  _i_k2d_i1
_i_k2d_i1:  .long 0
    .globl  _i_k2d_i2
_i_k2d_i2:  .long 0
    .globl  _i_k2d_i3
_i_k2d_i3:  .long 0
    .globl  _i_k2d_ra
_i_k2d_ra:  .long 0
    .globl  _i_k2d_rb
_i_k2d_rb:  .long 0
    .globl  _i_k2d_ret
_i_k2d_ret: .long 0xD61F0200
    .p2align 3
    .globl  _i_k2d_body
_i_k2d_body: .quad 0
