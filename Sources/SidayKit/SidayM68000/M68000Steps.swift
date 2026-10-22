// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Made by Scripts/m68000-steps.swift, which is where to change it. Do not edit.

/// What runs an opcode (`M68000.resume`): a step that runs an instruction of every mode, a step made for
/// some of its modes (or its size, condition or kind), or one of those a tune's code seldom runs.
enum M68000Step {
    case oriB, oriW, oriL, andiB, andiW, andiL, subiB, subiW, subiL, addiB, addiW, addiL, eoriB, eoriW, eoriL
    case cmpiB, cmpiW, cmpiL, bitDynamic, bitStatic, moveB, moveW, moveL, moveaB, moveaW, moveaL, lea, pea, jsr
    case jmp, clrB, tstB, clrW, tstW, clrL, tstL, neg, not, swap, extW, extL, movemStoreW, movemStoreL
    case movemLoadW, movemLoadL, nop, rts, rte, dbra, dbcc, scc, addqA, subqA, addqB, subqB, addqW, subqW, addqL
    case subqL, bra, bsr, bhi, bls, bcc, bcs, bne, beq, bvc, bvs, bpl, bmi, bge, blt, bgt, ble, moveq, orB, orEaB
    case orW, orEaW, orL, orEaL, andB, andEaB, andW, andEaW, andL, andEaL, addB, addEaB, addW, addEaW, addL
    case addEaL, subB, subEaB, subW, subEaW, subL, subEaL, addxB, subxB, addxW, subxW, addxL, subxL, eorB, cmpB
    case eorW, cmpW, eorL, cmpL, cmpaW, addaW, subaW, cmpaL, addaL, subaL, mulu, muls, shiftRegister, oriB_dn
    case oriB_ind, oriB_inc, oriB_dec, oriB_disp, oriB_index, oriB_absW, oriB_absL, oriW_dn, oriW_ind, oriW_inc
    case oriW_dec, oriW_disp, oriW_index, oriW_absW, oriW_absL, oriL_dn, oriL_ind, oriL_inc, oriL_dec, oriL_disp
    case oriL_index, oriL_absW, oriL_absL, andiB_dn, andiB_ind, andiB_inc, andiB_dec, andiB_disp, andiB_index
    case andiB_absW, andiB_absL, andiW_dn, andiW_ind, andiW_inc, andiW_dec, andiW_disp, andiW_index, andiW_absW
    case andiW_absL, andiL_dn, andiL_ind, andiL_inc, andiL_dec, andiL_disp, andiL_index, andiL_absW, andiL_absL
    case subiB_dn, subiB_ind, subiB_inc, subiB_dec, subiB_disp, subiB_index, subiB_absW, subiB_absL, subiW_dn
    case subiW_ind, subiW_inc, subiW_dec, subiW_disp, subiW_index, subiW_absW, subiW_absL, subiL_dn, subiL_ind
    case subiL_inc, subiL_dec, subiL_disp, subiL_index, subiL_absW, subiL_absL, addiB_dn, addiB_ind, addiB_inc
    case addiB_dec, addiB_disp, addiB_index, addiB_absW, addiB_absL, addiW_dn, addiW_ind, addiW_inc, addiW_dec
    case addiW_disp, addiW_index, addiW_absW, addiW_absL, addiL_dn, addiL_ind, addiL_inc, addiL_dec, addiL_disp
    case addiL_index, addiL_absW, addiL_absL, eoriB_dn, eoriB_ind, eoriB_inc, eoriB_dec, eoriB_disp, eoriB_index
    case eoriB_absW, eoriB_absL, eoriW_dn, eoriW_ind, eoriW_inc, eoriW_dec, eoriW_disp, eoriW_index, eoriW_absW
    case eoriW_absL, eoriL_dn, eoriL_ind, eoriL_inc, eoriL_dec, eoriL_disp, eoriL_index, eoriL_absW, eoriL_absL
    case cmpiB_dn, cmpiB_ind, cmpiB_inc, cmpiB_dec, cmpiB_disp, cmpiB_index, cmpiB_absW, cmpiB_absL, cmpiW_dn
    case cmpiW_ind, cmpiW_inc, cmpiW_dec, cmpiW_disp, cmpiW_index, cmpiW_absW, cmpiW_absL, cmpiL_dn, cmpiL_ind
    case cmpiL_inc, cmpiL_dec, cmpiL_disp, cmpiL_index, cmpiL_absW, cmpiL_absL, bitDynamic_btst_dn
    case bitDynamic_btst_ind, bitDynamic_btst_inc, bitDynamic_btst_dec, bitDynamic_btst_disp
    case bitDynamic_btst_index, bitDynamic_btst_absW, bitDynamic_btst_absL, bitDynamic_bchg_dn
    case bitDynamic_bchg_ind, bitDynamic_bchg_inc, bitDynamic_bchg_dec, bitDynamic_bchg_disp
    case bitDynamic_bchg_index, bitDynamic_bchg_absW, bitDynamic_bchg_absL, bitDynamic_bclr_dn
    case bitDynamic_bclr_ind, bitDynamic_bclr_inc, bitDynamic_bclr_dec, bitDynamic_bclr_disp
    case bitDynamic_bclr_index, bitDynamic_bclr_absW, bitDynamic_bclr_absL, bitDynamic_bset_dn
    case bitDynamic_bset_ind, bitDynamic_bset_inc, bitDynamic_bset_dec, bitDynamic_bset_disp
    case bitDynamic_bset_index, bitDynamic_bset_absW, bitDynamic_bset_absL, bitStatic_btst_dn, bitStatic_btst_ind
    case bitStatic_btst_inc, bitStatic_btst_dec, bitStatic_btst_disp, bitStatic_btst_index, bitStatic_btst_absW
    case bitStatic_btst_absL, bitStatic_bchg_dn, bitStatic_bchg_ind, bitStatic_bchg_inc, bitStatic_bchg_dec
    case bitStatic_bchg_disp, bitStatic_bchg_index, bitStatic_bchg_absW, bitStatic_bchg_absL, bitStatic_bclr_dn
    case bitStatic_bclr_ind, bitStatic_bclr_inc, bitStatic_bclr_dec, bitStatic_bclr_disp, bitStatic_bclr_index
    case bitStatic_bclr_absW, bitStatic_bclr_absL, bitStatic_bset_dn, bitStatic_bset_ind, bitStatic_bset_inc
    case bitStatic_bset_dec, bitStatic_bset_disp, bitStatic_bset_index, bitStatic_bset_absW, bitStatic_bset_absL
    case moveB_dn_dn, moveB_dn_ind, moveB_dn_inc, moveB_dn_dec, moveB_dn_disp, moveB_dn_index, moveB_dn_absW
    case moveB_dn_absL, moveB_ind_dn, moveB_ind_ind, moveB_ind_inc, moveB_ind_dec, moveB_ind_disp
    case moveB_ind_index, moveB_ind_absW, moveB_ind_absL, moveB_inc_dn, moveB_inc_ind, moveB_inc_inc
    case moveB_inc_dec, moveB_inc_disp, moveB_inc_index, moveB_inc_absW, moveB_inc_absL, moveB_dec_dn
    case moveB_dec_ind, moveB_dec_inc, moveB_dec_dec, moveB_dec_disp, moveB_dec_index, moveB_dec_absW
    case moveB_dec_absL, moveB_disp_dn, moveB_disp_ind, moveB_disp_inc, moveB_disp_dec, moveB_disp_disp
    case moveB_disp_index, moveB_disp_absW, moveB_disp_absL, moveB_index_dn, moveB_index_ind, moveB_index_inc
    case moveB_index_dec, moveB_index_disp, moveB_index_index, moveB_index_absW, moveB_index_absL, moveB_absW_dn
    case moveB_absW_ind, moveB_absW_inc, moveB_absW_dec, moveB_absW_disp, moveB_absW_index, moveB_absW_absW
    case moveB_absW_absL, moveB_absL_dn, moveB_absL_ind, moveB_absL_inc, moveB_absL_dec, moveB_absL_disp
    case moveB_absL_index, moveB_absL_absW, moveB_absL_absL, moveB_pcDisp_dn, moveB_pcDisp_ind, moveB_pcDisp_inc
    case moveB_pcDisp_dec, moveB_pcDisp_disp, moveB_pcDisp_index, moveB_pcDisp_absW, moveB_pcDisp_absL
    case moveB_pcIndex_dn, moveB_pcIndex_ind, moveB_pcIndex_inc, moveB_pcIndex_dec, moveB_pcIndex_disp
    case moveB_pcIndex_index, moveB_pcIndex_absW, moveB_pcIndex_absL, moveB_imm_dn, moveB_imm_ind, moveB_imm_inc
    case moveB_imm_dec, moveB_imm_disp, moveB_imm_index, moveB_imm_absW, moveB_imm_absL, moveW_dn_dn
    case moveW_dn_ind, moveW_dn_inc, moveW_dn_dec, moveW_dn_disp, moveW_dn_index, moveW_dn_absW, moveW_dn_absL
    case moveW_an_dn, moveW_an_ind, moveW_an_inc, moveW_an_dec, moveW_an_disp, moveW_an_index, moveW_an_absW
    case moveW_an_absL, moveW_ind_dn, moveW_ind_ind, moveW_ind_inc, moveW_ind_dec, moveW_ind_disp
    case moveW_ind_index, moveW_ind_absW, moveW_ind_absL, moveW_inc_dn, moveW_inc_ind, moveW_inc_inc
    case moveW_inc_dec, moveW_inc_disp, moveW_inc_index, moveW_inc_absW, moveW_inc_absL, moveW_dec_dn
    case moveW_dec_ind, moveW_dec_inc, moveW_dec_dec, moveW_dec_disp, moveW_dec_index, moveW_dec_absW
    case moveW_dec_absL, moveW_disp_dn, moveW_disp_ind, moveW_disp_inc, moveW_disp_dec, moveW_disp_disp
    case moveW_disp_index, moveW_disp_absW, moveW_disp_absL, moveW_index_dn, moveW_index_ind, moveW_index_inc
    case moveW_index_dec, moveW_index_disp, moveW_index_index, moveW_index_absW, moveW_index_absL, moveW_absW_dn
    case moveW_absW_ind, moveW_absW_inc, moveW_absW_dec, moveW_absW_disp, moveW_absW_index, moveW_absW_absW
    case moveW_absW_absL, moveW_absL_dn, moveW_absL_ind, moveW_absL_inc, moveW_absL_dec, moveW_absL_disp
    case moveW_absL_index, moveW_absL_absW, moveW_absL_absL, moveW_pcDisp_dn, moveW_pcDisp_ind, moveW_pcDisp_inc
    case moveW_pcDisp_dec, moveW_pcDisp_disp, moveW_pcDisp_index, moveW_pcDisp_absW, moveW_pcDisp_absL
    case moveW_pcIndex_dn, moveW_pcIndex_ind, moveW_pcIndex_inc, moveW_pcIndex_dec, moveW_pcIndex_disp
    case moveW_pcIndex_index, moveW_pcIndex_absW, moveW_pcIndex_absL, moveW_imm_dn, moveW_imm_ind, moveW_imm_inc
    case moveW_imm_dec, moveW_imm_disp, moveW_imm_index, moveW_imm_absW, moveW_imm_absL, moveL_dn_dn
    case moveL_dn_ind, moveL_dn_inc, moveL_dn_dec, moveL_dn_disp, moveL_dn_index, moveL_dn_absW, moveL_dn_absL
    case moveL_an_dn, moveL_an_ind, moveL_an_inc, moveL_an_dec, moveL_an_disp, moveL_an_index, moveL_an_absW
    case moveL_an_absL, moveL_ind_dn, moveL_ind_ind, moveL_ind_inc, moveL_ind_dec, moveL_ind_disp
    case moveL_ind_index, moveL_ind_absW, moveL_ind_absL, moveL_inc_dn, moveL_inc_ind, moveL_inc_inc
    case moveL_inc_dec, moveL_inc_disp, moveL_inc_index, moveL_inc_absW, moveL_inc_absL, moveL_dec_dn
    case moveL_dec_ind, moveL_dec_inc, moveL_dec_dec, moveL_dec_disp, moveL_dec_index, moveL_dec_absW
    case moveL_dec_absL, moveL_disp_dn, moveL_disp_ind, moveL_disp_inc, moveL_disp_dec, moveL_disp_disp
    case moveL_disp_index, moveL_disp_absW, moveL_disp_absL, moveL_index_dn, moveL_index_ind, moveL_index_inc
    case moveL_index_dec, moveL_index_disp, moveL_index_index, moveL_index_absW, moveL_index_absL, moveL_absW_dn
    case moveL_absW_ind, moveL_absW_inc, moveL_absW_dec, moveL_absW_disp, moveL_absW_index, moveL_absW_absW
    case moveL_absW_absL, moveL_absL_dn, moveL_absL_ind, moveL_absL_inc, moveL_absL_dec, moveL_absL_disp
    case moveL_absL_index, moveL_absL_absW, moveL_absL_absL, moveL_pcDisp_dn, moveL_pcDisp_ind, moveL_pcDisp_inc
    case moveL_pcDisp_dec, moveL_pcDisp_disp, moveL_pcDisp_index, moveL_pcDisp_absW, moveL_pcDisp_absL
    case moveL_pcIndex_dn, moveL_pcIndex_ind, moveL_pcIndex_inc, moveL_pcIndex_dec, moveL_pcIndex_disp
    case moveL_pcIndex_index, moveL_pcIndex_absW, moveL_pcIndex_absL, moveL_imm_dn, moveL_imm_ind, moveL_imm_inc
    case moveL_imm_dec, moveL_imm_disp, moveL_imm_index, moveL_imm_absW, moveL_imm_absL, moveaW_dn, moveaW_an
    case moveaW_ind, moveaW_inc, moveaW_dec, moveaW_disp, moveaW_index, moveaW_absW, moveaW_absL, moveaW_pcDisp
    case moveaW_pcIndex, moveaW_imm, moveaL_dn, moveaL_an, moveaL_ind, moveaL_inc, moveaL_dec, moveaL_disp
    case moveaL_index, moveaL_absW, moveaL_absL, moveaL_pcDisp, moveaL_pcIndex, moveaL_imm, lea_ind, lea_disp
    case lea_index, lea_absW, lea_absL, lea_pcDisp, lea_pcIndex, pea_ind, pea_disp, pea_index, pea_absW, pea_absL
    case pea_pcDisp, pea_pcIndex, jsr_ind, jsr_disp, jsr_index, jsr_absW, jsr_absL, jsr_pcDisp, jsr_pcIndex
    case jmp_ind, jmp_disp, jmp_index, jmp_absW, jmp_absL, jmp_pcDisp, jmp_pcIndex, clrB_dn, clrB_ind, clrB_inc
    case clrB_dec, clrB_disp, clrB_index, clrB_absW, clrB_absL, tstB_dn, tstB_ind, tstB_inc, tstB_dec, tstB_disp
    case tstB_index, tstB_absW, tstB_absL, clrW_dn, clrW_ind, clrW_inc, clrW_dec, clrW_disp, clrW_index
    case clrW_absW, clrW_absL, tstW_dn, tstW_ind, tstW_inc, tstW_dec, tstW_disp, tstW_index, tstW_absW, tstW_absL
    case clrL_dn, clrL_ind, clrL_inc, clrL_dec, clrL_disp, clrL_index, clrL_absW, clrL_absL, tstL_dn, tstL_ind
    case tstL_inc, tstL_dec, tstL_disp, tstL_index, tstL_absW, tstL_absL, dbcc_t, dbcc_hi, dbcc_ls, dbcc_cc
    case dbcc_cs, dbcc_ne, dbcc_eq, dbcc_vc, dbcc_vs, dbcc_pl, dbcc_mi, dbcc_ge, dbcc_lt, dbcc_gt, dbcc_le
    case addqB_dn, addqB_ind, addqB_inc, addqB_dec, addqB_disp, addqB_index, addqB_absW, addqB_absL, subqB_dn
    case subqB_ind, subqB_inc, subqB_dec, subqB_disp, subqB_index, subqB_absW, subqB_absL, addqW_dn, addqW_ind
    case addqW_inc, addqW_dec, addqW_disp, addqW_index, addqW_absW, addqW_absL, subqW_dn, subqW_ind, subqW_inc
    case subqW_dec, subqW_disp, subqW_index, subqW_absW, subqW_absL, addqL_dn, addqL_ind, addqL_inc, addqL_dec
    case addqL_disp, addqL_index, addqL_absW, addqL_absL, subqL_dn, subqL_ind, subqL_inc, subqL_dec, subqL_disp
    case subqL_index, subqL_absW, subqL_absL, orB_dn, orB_ind, orB_inc, orB_dec, orB_disp, orB_index, orB_absW
    case orB_absL, orB_pcDisp, orB_pcIndex, orB_imm, orEaB_ind, orEaB_inc, orEaB_dec, orEaB_disp, orEaB_index
    case orEaB_absW, orEaB_absL, orW_dn, orW_ind, orW_inc, orW_dec, orW_disp, orW_index, orW_absW, orW_absL
    case orW_pcDisp, orW_pcIndex, orW_imm, orEaW_ind, orEaW_inc, orEaW_dec, orEaW_disp, orEaW_index, orEaW_absW
    case orEaW_absL, orL_dn, orL_ind, orL_inc, orL_dec, orL_disp, orL_index, orL_absW, orL_absL, orL_pcDisp
    case orL_pcIndex, orL_imm, orEaL_ind, orEaL_inc, orEaL_dec, orEaL_disp, orEaL_index, orEaL_absW, orEaL_absL
    case andB_dn, andB_ind, andB_inc, andB_dec, andB_disp, andB_index, andB_absW, andB_absL, andB_pcDisp
    case andB_pcIndex, andB_imm, andEaB_ind, andEaB_inc, andEaB_dec, andEaB_disp, andEaB_index, andEaB_absW
    case andEaB_absL, andW_dn, andW_ind, andW_inc, andW_dec, andW_disp, andW_index, andW_absW, andW_absL
    case andW_pcDisp, andW_pcIndex, andW_imm, andEaW_ind, andEaW_inc, andEaW_dec, andEaW_disp, andEaW_index
    case andEaW_absW, andEaW_absL, andL_dn, andL_ind, andL_inc, andL_dec, andL_disp, andL_index, andL_absW
    case andL_absL, andL_pcDisp, andL_pcIndex, andL_imm, andEaL_ind, andEaL_inc, andEaL_dec, andEaL_disp
    case andEaL_index, andEaL_absW, andEaL_absL, addB_dn, addB_ind, addB_inc, addB_dec, addB_disp, addB_index
    case addB_absW, addB_absL, addB_pcDisp, addB_pcIndex, addB_imm, addEaB_ind, addEaB_inc, addEaB_dec
    case addEaB_disp, addEaB_index, addEaB_absW, addEaB_absL, addW_dn, addW_an, addW_ind, addW_inc, addW_dec
    case addW_disp, addW_index, addW_absW, addW_absL, addW_pcDisp, addW_pcIndex, addW_imm, addEaW_ind, addEaW_inc
    case addEaW_dec, addEaW_disp, addEaW_index, addEaW_absW, addEaW_absL, addL_dn, addL_an, addL_ind, addL_inc
    case addL_dec, addL_disp, addL_index, addL_absW, addL_absL, addL_pcDisp, addL_pcIndex, addL_imm, addEaL_ind
    case addEaL_inc, addEaL_dec, addEaL_disp, addEaL_index, addEaL_absW, addEaL_absL, subB_dn, subB_ind, subB_inc
    case subB_dec, subB_disp, subB_index, subB_absW, subB_absL, subB_pcDisp, subB_pcIndex, subB_imm, subEaB_ind
    case subEaB_inc, subEaB_dec, subEaB_disp, subEaB_index, subEaB_absW, subEaB_absL, subW_dn, subW_an, subW_ind
    case subW_inc, subW_dec, subW_disp, subW_index, subW_absW, subW_absL, subW_pcDisp, subW_pcIndex, subW_imm
    case subEaW_ind, subEaW_inc, subEaW_dec, subEaW_disp, subEaW_index, subEaW_absW, subEaW_absL, subL_dn
    case subL_an, subL_ind, subL_inc, subL_dec, subL_disp, subL_index, subL_absW, subL_absL, subL_pcDisp
    case subL_pcIndex, subL_imm, subEaL_ind, subEaL_inc, subEaL_dec, subEaL_disp, subEaL_index, subEaL_absW
    case subEaL_absL, addxB_registers, addxB_memory, subxB_registers, subxB_memory, addxW_registers, addxW_memory
    case subxW_registers, subxW_memory, addxL_registers, addxL_memory, subxL_registers, subxL_memory, eorB_dn
    case eorB_ind, eorB_inc, eorB_dec, eorB_disp, eorB_index, eorB_absW, eorB_absL, cmpB_dn, cmpB_ind, cmpB_inc
    case cmpB_dec, cmpB_disp, cmpB_index, cmpB_absW, cmpB_absL, cmpB_pcDisp, cmpB_pcIndex, cmpB_imm, eorW_dn
    case eorW_ind, eorW_inc, eorW_dec, eorW_disp, eorW_index, eorW_absW, eorW_absL, cmpW_dn, cmpW_an, cmpW_ind
    case cmpW_inc, cmpW_dec, cmpW_disp, cmpW_index, cmpW_absW, cmpW_absL, cmpW_pcDisp, cmpW_pcIndex, cmpW_imm
    case eorL_dn, eorL_ind, eorL_inc, eorL_dec, eorL_disp, eorL_index, eorL_absW, eorL_absL, cmpL_dn, cmpL_an
    case cmpL_ind, cmpL_inc, cmpL_dec, cmpL_disp, cmpL_index, cmpL_absW, cmpL_absL, cmpL_pcDisp, cmpL_pcIndex
    case cmpL_imm, cmpaW_dn, cmpaW_an, cmpaW_ind, cmpaW_inc, cmpaW_dec, cmpaW_disp, cmpaW_index, cmpaW_absW
    case cmpaW_absL, cmpaW_pcDisp, cmpaW_pcIndex, cmpaW_imm, addaW_dn, addaW_an, addaW_ind, addaW_inc, addaW_dec
    case addaW_disp, addaW_index, addaW_absW, addaW_absL, addaW_pcDisp, addaW_pcIndex, addaW_imm, subaW_dn
    case subaW_an, subaW_ind, subaW_inc, subaW_dec, subaW_disp, subaW_index, subaW_absW, subaW_absL, subaW_pcDisp
    case subaW_pcIndex, subaW_imm, cmpaL_dn, cmpaL_an, cmpaL_ind, cmpaL_inc, cmpaL_dec, cmpaL_disp, cmpaL_index
    case cmpaL_absW, cmpaL_absL, cmpaL_pcDisp, cmpaL_pcIndex, cmpaL_imm, addaL_dn, addaL_an, addaL_ind, addaL_inc
    case addaL_dec, addaL_disp, addaL_index, addaL_absW, addaL_absL, addaL_pcDisp, addaL_pcIndex, addaL_imm
    case subaL_dn, subaL_an, subaL_ind, subaL_inc, subaL_dec, subaL_disp, subaL_index, subaL_absW, subaL_absL
    case subaL_pcDisp, subaL_pcIndex, subaL_imm, mulu_dn, mulu_ind, mulu_inc, mulu_dec, mulu_disp, mulu_index
    case mulu_absW, mulu_absL, mulu_pcDisp, mulu_pcIndex, mulu_imm, muls_dn, muls_ind, muls_inc, muls_dec
    case muls_disp, muls_index, muls_absW, muls_absL, muls_pcDisp, muls_pcIndex, muls_imm
    case shiftRegister_as_r_B_byCount, shiftRegister_as_r_B_byRegister, shiftRegister_as_r_W_byCount
    case shiftRegister_as_r_W_byRegister, shiftRegister_as_r_L_byCount, shiftRegister_as_r_L_byRegister
    case shiftRegister_as_l_B_byCount, shiftRegister_as_l_B_byRegister, shiftRegister_as_l_W_byCount
    case shiftRegister_as_l_W_byRegister, shiftRegister_as_l_L_byCount, shiftRegister_as_l_L_byRegister
    case shiftRegister_ls_r_B_byCount, shiftRegister_ls_r_B_byRegister, shiftRegister_ls_r_W_byCount
    case shiftRegister_ls_r_W_byRegister, shiftRegister_ls_r_L_byCount, shiftRegister_ls_r_L_byRegister
    case shiftRegister_ls_l_B_byCount, shiftRegister_ls_l_B_byRegister, shiftRegister_ls_l_W_byCount
    case shiftRegister_ls_l_W_byRegister, shiftRegister_ls_l_L_byCount, shiftRegister_ls_l_L_byRegister
    case shiftRegister_rox_r_B_byCount, shiftRegister_rox_r_B_byRegister, shiftRegister_rox_r_W_byCount
    case shiftRegister_rox_r_W_byRegister, shiftRegister_rox_r_L_byCount, shiftRegister_rox_r_L_byRegister
    case shiftRegister_rox_l_B_byCount, shiftRegister_rox_l_B_byRegister, shiftRegister_rox_l_W_byCount
    case shiftRegister_rox_l_W_byRegister, shiftRegister_rox_l_L_byCount, shiftRegister_rox_l_L_byRegister
    case shiftRegister_ro_r_B_byCount, shiftRegister_ro_r_B_byRegister, shiftRegister_ro_r_W_byCount
    case shiftRegister_ro_r_W_byRegister, shiftRegister_ro_r_L_byCount, shiftRegister_ro_r_L_byRegister
    case shiftRegister_ro_l_B_byCount, shiftRegister_ro_l_B_byRegister, shiftRegister_ro_l_W_byCount
    case shiftRegister_ro_l_W_byRegister, shiftRegister_ro_l_L_byCount, shiftRegister_ro_l_L_byRegister, movep
    case immediateToStatus, chk, moveFromStatus, negx, moveToConditions, moveToStatus, nbcd, tas, trap, link
    case unlink, moveUserStack, resetInstruction, stopInstruction, trapv, rtr, divide, decimal, cmpm, exchange
    case shiftMemory, unimplemented, illegal
}

extension M68000Step {
    /// The step made for an opcode's modes, if there is one, beside the step that runs any.
    @export(interface) static func specialised(_ step: M68000Step, _ op: UInt32) -> M68000Step? {
        switch step {
        case .oriB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .oriB_dn
            case 2: return .oriB_ind
            case 3: return .oriB_inc
            case 4: return .oriB_dec
            case 5: return .oriB_disp
            case 6: return .oriB_index
            case 7: return .oriB_absW
            case 8: return .oriB_absL
            default: return nil
            }
        case .oriW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .oriW_dn
            case 2: return .oriW_ind
            case 3: return .oriW_inc
            case 4: return .oriW_dec
            case 5: return .oriW_disp
            case 6: return .oriW_index
            case 7: return .oriW_absW
            case 8: return .oriW_absL
            default: return nil
            }
        case .oriL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .oriL_dn
            case 2: return .oriL_ind
            case 3: return .oriL_inc
            case 4: return .oriL_dec
            case 5: return .oriL_disp
            case 6: return .oriL_index
            case 7: return .oriL_absW
            case 8: return .oriL_absL
            default: return nil
            }
        case .andiB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .andiB_dn
            case 2: return .andiB_ind
            case 3: return .andiB_inc
            case 4: return .andiB_dec
            case 5: return .andiB_disp
            case 6: return .andiB_index
            case 7: return .andiB_absW
            case 8: return .andiB_absL
            default: return nil
            }
        case .andiW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .andiW_dn
            case 2: return .andiW_ind
            case 3: return .andiW_inc
            case 4: return .andiW_dec
            case 5: return .andiW_disp
            case 6: return .andiW_index
            case 7: return .andiW_absW
            case 8: return .andiW_absL
            default: return nil
            }
        case .andiL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .andiL_dn
            case 2: return .andiL_ind
            case 3: return .andiL_inc
            case 4: return .andiL_dec
            case 5: return .andiL_disp
            case 6: return .andiL_index
            case 7: return .andiL_absW
            case 8: return .andiL_absL
            default: return nil
            }
        case .subiB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subiB_dn
            case 2: return .subiB_ind
            case 3: return .subiB_inc
            case 4: return .subiB_dec
            case 5: return .subiB_disp
            case 6: return .subiB_index
            case 7: return .subiB_absW
            case 8: return .subiB_absL
            default: return nil
            }
        case .subiW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subiW_dn
            case 2: return .subiW_ind
            case 3: return .subiW_inc
            case 4: return .subiW_dec
            case 5: return .subiW_disp
            case 6: return .subiW_index
            case 7: return .subiW_absW
            case 8: return .subiW_absL
            default: return nil
            }
        case .subiL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subiL_dn
            case 2: return .subiL_ind
            case 3: return .subiL_inc
            case 4: return .subiL_dec
            case 5: return .subiL_disp
            case 6: return .subiL_index
            case 7: return .subiL_absW
            case 8: return .subiL_absL
            default: return nil
            }
        case .addiB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addiB_dn
            case 2: return .addiB_ind
            case 3: return .addiB_inc
            case 4: return .addiB_dec
            case 5: return .addiB_disp
            case 6: return .addiB_index
            case 7: return .addiB_absW
            case 8: return .addiB_absL
            default: return nil
            }
        case .addiW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addiW_dn
            case 2: return .addiW_ind
            case 3: return .addiW_inc
            case 4: return .addiW_dec
            case 5: return .addiW_disp
            case 6: return .addiW_index
            case 7: return .addiW_absW
            case 8: return .addiW_absL
            default: return nil
            }
        case .addiL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addiL_dn
            case 2: return .addiL_ind
            case 3: return .addiL_inc
            case 4: return .addiL_dec
            case 5: return .addiL_disp
            case 6: return .addiL_index
            case 7: return .addiL_absW
            case 8: return .addiL_absL
            default: return nil
            }
        case .eoriB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .eoriB_dn
            case 2: return .eoriB_ind
            case 3: return .eoriB_inc
            case 4: return .eoriB_dec
            case 5: return .eoriB_disp
            case 6: return .eoriB_index
            case 7: return .eoriB_absW
            case 8: return .eoriB_absL
            default: return nil
            }
        case .eoriW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .eoriW_dn
            case 2: return .eoriW_ind
            case 3: return .eoriW_inc
            case 4: return .eoriW_dec
            case 5: return .eoriW_disp
            case 6: return .eoriW_index
            case 7: return .eoriW_absW
            case 8: return .eoriW_absL
            default: return nil
            }
        case .eoriL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .eoriL_dn
            case 2: return .eoriL_ind
            case 3: return .eoriL_inc
            case 4: return .eoriL_dec
            case 5: return .eoriL_disp
            case 6: return .eoriL_index
            case 7: return .eoriL_absW
            case 8: return .eoriL_absL
            default: return nil
            }
        case .cmpiB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .cmpiB_dn
            case 2: return .cmpiB_ind
            case 3: return .cmpiB_inc
            case 4: return .cmpiB_dec
            case 5: return .cmpiB_disp
            case 6: return .cmpiB_index
            case 7: return .cmpiB_absW
            case 8: return .cmpiB_absL
            default: return nil
            }
        case .cmpiW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .cmpiW_dn
            case 2: return .cmpiW_ind
            case 3: return .cmpiW_inc
            case 4: return .cmpiW_dec
            case 5: return .cmpiW_disp
            case 6: return .cmpiW_index
            case 7: return .cmpiW_absW
            case 8: return .cmpiW_absL
            default: return nil
            }
        case .cmpiL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .cmpiL_dn
            case 2: return .cmpiL_ind
            case 3: return .cmpiL_inc
            case 4: return .cmpiL_dec
            case 5: return .cmpiL_disp
            case 6: return .cmpiL_index
            case 7: return .cmpiL_absW
            case 8: return .cmpiL_absL
            default: return nil
            }
        case .bitDynamic:
            switch ((op >> 6) & 3) << 4 | (M68000Step.sourceMode(op)) {
            case 0: return .bitDynamic_btst_dn
            case 2: return .bitDynamic_btst_ind
            case 3: return .bitDynamic_btst_inc
            case 4: return .bitDynamic_btst_dec
            case 5: return .bitDynamic_btst_disp
            case 6: return .bitDynamic_btst_index
            case 7: return .bitDynamic_btst_absW
            case 8: return .bitDynamic_btst_absL
            case 16: return .bitDynamic_bchg_dn
            case 18: return .bitDynamic_bchg_ind
            case 19: return .bitDynamic_bchg_inc
            case 20: return .bitDynamic_bchg_dec
            case 21: return .bitDynamic_bchg_disp
            case 22: return .bitDynamic_bchg_index
            case 23: return .bitDynamic_bchg_absW
            case 24: return .bitDynamic_bchg_absL
            case 32: return .bitDynamic_bclr_dn
            case 34: return .bitDynamic_bclr_ind
            case 35: return .bitDynamic_bclr_inc
            case 36: return .bitDynamic_bclr_dec
            case 37: return .bitDynamic_bclr_disp
            case 38: return .bitDynamic_bclr_index
            case 39: return .bitDynamic_bclr_absW
            case 40: return .bitDynamic_bclr_absL
            case 48: return .bitDynamic_bset_dn
            case 50: return .bitDynamic_bset_ind
            case 51: return .bitDynamic_bset_inc
            case 52: return .bitDynamic_bset_dec
            case 53: return .bitDynamic_bset_disp
            case 54: return .bitDynamic_bset_index
            case 55: return .bitDynamic_bset_absW
            case 56: return .bitDynamic_bset_absL
            default: return nil
            }
        case .bitStatic:
            switch ((op >> 6) & 3) << 4 | (M68000Step.sourceMode(op)) {
            case 0: return .bitStatic_btst_dn
            case 2: return .bitStatic_btst_ind
            case 3: return .bitStatic_btst_inc
            case 4: return .bitStatic_btst_dec
            case 5: return .bitStatic_btst_disp
            case 6: return .bitStatic_btst_index
            case 7: return .bitStatic_btst_absW
            case 8: return .bitStatic_btst_absL
            case 16: return .bitStatic_bchg_dn
            case 18: return .bitStatic_bchg_ind
            case 19: return .bitStatic_bchg_inc
            case 20: return .bitStatic_bchg_dec
            case 21: return .bitStatic_bchg_disp
            case 22: return .bitStatic_bchg_index
            case 23: return .bitStatic_bchg_absW
            case 24: return .bitStatic_bchg_absL
            case 32: return .bitStatic_bclr_dn
            case 34: return .bitStatic_bclr_ind
            case 35: return .bitStatic_bclr_inc
            case 36: return .bitStatic_bclr_dec
            case 37: return .bitStatic_bclr_disp
            case 38: return .bitStatic_bclr_index
            case 39: return .bitStatic_bclr_absW
            case 40: return .bitStatic_bclr_absL
            case 48: return .bitStatic_bset_dn
            case 50: return .bitStatic_bset_ind
            case 51: return .bitStatic_bset_inc
            case 52: return .bitStatic_bset_dec
            case 53: return .bitStatic_bset_disp
            case 54: return .bitStatic_bset_index
            case 55: return .bitStatic_bset_absW
            case 56: return .bitStatic_bset_absL
            default: return nil
            }
        case .moveB:
            switch (M68000Step.sourceMode(op)) << 4 | (M68000Step.targetMode(op)) {
            case 0: return .moveB_dn_dn
            case 2: return .moveB_dn_ind
            case 3: return .moveB_dn_inc
            case 4: return .moveB_dn_dec
            case 5: return .moveB_dn_disp
            case 6: return .moveB_dn_index
            case 7: return .moveB_dn_absW
            case 8: return .moveB_dn_absL
            case 32: return .moveB_ind_dn
            case 34: return .moveB_ind_ind
            case 35: return .moveB_ind_inc
            case 36: return .moveB_ind_dec
            case 37: return .moveB_ind_disp
            case 38: return .moveB_ind_index
            case 39: return .moveB_ind_absW
            case 40: return .moveB_ind_absL
            case 48: return .moveB_inc_dn
            case 50: return .moveB_inc_ind
            case 51: return .moveB_inc_inc
            case 52: return .moveB_inc_dec
            case 53: return .moveB_inc_disp
            case 54: return .moveB_inc_index
            case 55: return .moveB_inc_absW
            case 56: return .moveB_inc_absL
            case 64: return .moveB_dec_dn
            case 66: return .moveB_dec_ind
            case 67: return .moveB_dec_inc
            case 68: return .moveB_dec_dec
            case 69: return .moveB_dec_disp
            case 70: return .moveB_dec_index
            case 71: return .moveB_dec_absW
            case 72: return .moveB_dec_absL
            case 80: return .moveB_disp_dn
            case 82: return .moveB_disp_ind
            case 83: return .moveB_disp_inc
            case 84: return .moveB_disp_dec
            case 85: return .moveB_disp_disp
            case 86: return .moveB_disp_index
            case 87: return .moveB_disp_absW
            case 88: return .moveB_disp_absL
            case 96: return .moveB_index_dn
            case 98: return .moveB_index_ind
            case 99: return .moveB_index_inc
            case 100: return .moveB_index_dec
            case 101: return .moveB_index_disp
            case 102: return .moveB_index_index
            case 103: return .moveB_index_absW
            case 104: return .moveB_index_absL
            case 112: return .moveB_absW_dn
            case 114: return .moveB_absW_ind
            case 115: return .moveB_absW_inc
            case 116: return .moveB_absW_dec
            case 117: return .moveB_absW_disp
            case 118: return .moveB_absW_index
            case 119: return .moveB_absW_absW
            case 120: return .moveB_absW_absL
            case 128: return .moveB_absL_dn
            case 130: return .moveB_absL_ind
            case 131: return .moveB_absL_inc
            case 132: return .moveB_absL_dec
            case 133: return .moveB_absL_disp
            case 134: return .moveB_absL_index
            case 135: return .moveB_absL_absW
            case 136: return .moveB_absL_absL
            case 144: return .moveB_pcDisp_dn
            case 146: return .moveB_pcDisp_ind
            case 147: return .moveB_pcDisp_inc
            case 148: return .moveB_pcDisp_dec
            case 149: return .moveB_pcDisp_disp
            case 150: return .moveB_pcDisp_index
            case 151: return .moveB_pcDisp_absW
            case 152: return .moveB_pcDisp_absL
            case 160: return .moveB_pcIndex_dn
            case 162: return .moveB_pcIndex_ind
            case 163: return .moveB_pcIndex_inc
            case 164: return .moveB_pcIndex_dec
            case 165: return .moveB_pcIndex_disp
            case 166: return .moveB_pcIndex_index
            case 167: return .moveB_pcIndex_absW
            case 168: return .moveB_pcIndex_absL
            case 176: return .moveB_imm_dn
            case 178: return .moveB_imm_ind
            case 179: return .moveB_imm_inc
            case 180: return .moveB_imm_dec
            case 181: return .moveB_imm_disp
            case 182: return .moveB_imm_index
            case 183: return .moveB_imm_absW
            case 184: return .moveB_imm_absL
            default: return nil
            }
        case .moveW:
            switch (M68000Step.sourceMode(op)) << 4 | (M68000Step.targetMode(op)) {
            case 0: return .moveW_dn_dn
            case 2: return .moveW_dn_ind
            case 3: return .moveW_dn_inc
            case 4: return .moveW_dn_dec
            case 5: return .moveW_dn_disp
            case 6: return .moveW_dn_index
            case 7: return .moveW_dn_absW
            case 8: return .moveW_dn_absL
            case 16: return .moveW_an_dn
            case 18: return .moveW_an_ind
            case 19: return .moveW_an_inc
            case 20: return .moveW_an_dec
            case 21: return .moveW_an_disp
            case 22: return .moveW_an_index
            case 23: return .moveW_an_absW
            case 24: return .moveW_an_absL
            case 32: return .moveW_ind_dn
            case 34: return .moveW_ind_ind
            case 35: return .moveW_ind_inc
            case 36: return .moveW_ind_dec
            case 37: return .moveW_ind_disp
            case 38: return .moveW_ind_index
            case 39: return .moveW_ind_absW
            case 40: return .moveW_ind_absL
            case 48: return .moveW_inc_dn
            case 50: return .moveW_inc_ind
            case 51: return .moveW_inc_inc
            case 52: return .moveW_inc_dec
            case 53: return .moveW_inc_disp
            case 54: return .moveW_inc_index
            case 55: return .moveW_inc_absW
            case 56: return .moveW_inc_absL
            case 64: return .moveW_dec_dn
            case 66: return .moveW_dec_ind
            case 67: return .moveW_dec_inc
            case 68: return .moveW_dec_dec
            case 69: return .moveW_dec_disp
            case 70: return .moveW_dec_index
            case 71: return .moveW_dec_absW
            case 72: return .moveW_dec_absL
            case 80: return .moveW_disp_dn
            case 82: return .moveW_disp_ind
            case 83: return .moveW_disp_inc
            case 84: return .moveW_disp_dec
            case 85: return .moveW_disp_disp
            case 86: return .moveW_disp_index
            case 87: return .moveW_disp_absW
            case 88: return .moveW_disp_absL
            case 96: return .moveW_index_dn
            case 98: return .moveW_index_ind
            case 99: return .moveW_index_inc
            case 100: return .moveW_index_dec
            case 101: return .moveW_index_disp
            case 102: return .moveW_index_index
            case 103: return .moveW_index_absW
            case 104: return .moveW_index_absL
            case 112: return .moveW_absW_dn
            case 114: return .moveW_absW_ind
            case 115: return .moveW_absW_inc
            case 116: return .moveW_absW_dec
            case 117: return .moveW_absW_disp
            case 118: return .moveW_absW_index
            case 119: return .moveW_absW_absW
            case 120: return .moveW_absW_absL
            case 128: return .moveW_absL_dn
            case 130: return .moveW_absL_ind
            case 131: return .moveW_absL_inc
            case 132: return .moveW_absL_dec
            case 133: return .moveW_absL_disp
            case 134: return .moveW_absL_index
            case 135: return .moveW_absL_absW
            case 136: return .moveW_absL_absL
            case 144: return .moveW_pcDisp_dn
            case 146: return .moveW_pcDisp_ind
            case 147: return .moveW_pcDisp_inc
            case 148: return .moveW_pcDisp_dec
            case 149: return .moveW_pcDisp_disp
            case 150: return .moveW_pcDisp_index
            case 151: return .moveW_pcDisp_absW
            case 152: return .moveW_pcDisp_absL
            case 160: return .moveW_pcIndex_dn
            case 162: return .moveW_pcIndex_ind
            case 163: return .moveW_pcIndex_inc
            case 164: return .moveW_pcIndex_dec
            case 165: return .moveW_pcIndex_disp
            case 166: return .moveW_pcIndex_index
            case 167: return .moveW_pcIndex_absW
            case 168: return .moveW_pcIndex_absL
            case 176: return .moveW_imm_dn
            case 178: return .moveW_imm_ind
            case 179: return .moveW_imm_inc
            case 180: return .moveW_imm_dec
            case 181: return .moveW_imm_disp
            case 182: return .moveW_imm_index
            case 183: return .moveW_imm_absW
            case 184: return .moveW_imm_absL
            default: return nil
            }
        case .moveL:
            switch (M68000Step.sourceMode(op)) << 4 | (M68000Step.targetMode(op)) {
            case 0: return .moveL_dn_dn
            case 2: return .moveL_dn_ind
            case 3: return .moveL_dn_inc
            case 4: return .moveL_dn_dec
            case 5: return .moveL_dn_disp
            case 6: return .moveL_dn_index
            case 7: return .moveL_dn_absW
            case 8: return .moveL_dn_absL
            case 16: return .moveL_an_dn
            case 18: return .moveL_an_ind
            case 19: return .moveL_an_inc
            case 20: return .moveL_an_dec
            case 21: return .moveL_an_disp
            case 22: return .moveL_an_index
            case 23: return .moveL_an_absW
            case 24: return .moveL_an_absL
            case 32: return .moveL_ind_dn
            case 34: return .moveL_ind_ind
            case 35: return .moveL_ind_inc
            case 36: return .moveL_ind_dec
            case 37: return .moveL_ind_disp
            case 38: return .moveL_ind_index
            case 39: return .moveL_ind_absW
            case 40: return .moveL_ind_absL
            case 48: return .moveL_inc_dn
            case 50: return .moveL_inc_ind
            case 51: return .moveL_inc_inc
            case 52: return .moveL_inc_dec
            case 53: return .moveL_inc_disp
            case 54: return .moveL_inc_index
            case 55: return .moveL_inc_absW
            case 56: return .moveL_inc_absL
            case 64: return .moveL_dec_dn
            case 66: return .moveL_dec_ind
            case 67: return .moveL_dec_inc
            case 68: return .moveL_dec_dec
            case 69: return .moveL_dec_disp
            case 70: return .moveL_dec_index
            case 71: return .moveL_dec_absW
            case 72: return .moveL_dec_absL
            case 80: return .moveL_disp_dn
            case 82: return .moveL_disp_ind
            case 83: return .moveL_disp_inc
            case 84: return .moveL_disp_dec
            case 85: return .moveL_disp_disp
            case 86: return .moveL_disp_index
            case 87: return .moveL_disp_absW
            case 88: return .moveL_disp_absL
            case 96: return .moveL_index_dn
            case 98: return .moveL_index_ind
            case 99: return .moveL_index_inc
            case 100: return .moveL_index_dec
            case 101: return .moveL_index_disp
            case 102: return .moveL_index_index
            case 103: return .moveL_index_absW
            case 104: return .moveL_index_absL
            case 112: return .moveL_absW_dn
            case 114: return .moveL_absW_ind
            case 115: return .moveL_absW_inc
            case 116: return .moveL_absW_dec
            case 117: return .moveL_absW_disp
            case 118: return .moveL_absW_index
            case 119: return .moveL_absW_absW
            case 120: return .moveL_absW_absL
            case 128: return .moveL_absL_dn
            case 130: return .moveL_absL_ind
            case 131: return .moveL_absL_inc
            case 132: return .moveL_absL_dec
            case 133: return .moveL_absL_disp
            case 134: return .moveL_absL_index
            case 135: return .moveL_absL_absW
            case 136: return .moveL_absL_absL
            case 144: return .moveL_pcDisp_dn
            case 146: return .moveL_pcDisp_ind
            case 147: return .moveL_pcDisp_inc
            case 148: return .moveL_pcDisp_dec
            case 149: return .moveL_pcDisp_disp
            case 150: return .moveL_pcDisp_index
            case 151: return .moveL_pcDisp_absW
            case 152: return .moveL_pcDisp_absL
            case 160: return .moveL_pcIndex_dn
            case 162: return .moveL_pcIndex_ind
            case 163: return .moveL_pcIndex_inc
            case 164: return .moveL_pcIndex_dec
            case 165: return .moveL_pcIndex_disp
            case 166: return .moveL_pcIndex_index
            case 167: return .moveL_pcIndex_absW
            case 168: return .moveL_pcIndex_absL
            case 176: return .moveL_imm_dn
            case 178: return .moveL_imm_ind
            case 179: return .moveL_imm_inc
            case 180: return .moveL_imm_dec
            case 181: return .moveL_imm_disp
            case 182: return .moveL_imm_index
            case 183: return .moveL_imm_absW
            case 184: return .moveL_imm_absL
            default: return nil
            }
        case .moveaW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .moveaW_dn
            case 1: return .moveaW_an
            case 2: return .moveaW_ind
            case 3: return .moveaW_inc
            case 4: return .moveaW_dec
            case 5: return .moveaW_disp
            case 6: return .moveaW_index
            case 7: return .moveaW_absW
            case 8: return .moveaW_absL
            case 9: return .moveaW_pcDisp
            case 10: return .moveaW_pcIndex
            case 11: return .moveaW_imm
            default: return nil
            }
        case .moveaL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .moveaL_dn
            case 1: return .moveaL_an
            case 2: return .moveaL_ind
            case 3: return .moveaL_inc
            case 4: return .moveaL_dec
            case 5: return .moveaL_disp
            case 6: return .moveaL_index
            case 7: return .moveaL_absW
            case 8: return .moveaL_absL
            case 9: return .moveaL_pcDisp
            case 10: return .moveaL_pcIndex
            case 11: return .moveaL_imm
            default: return nil
            }
        case .lea:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .lea_ind
            case 5: return .lea_disp
            case 6: return .lea_index
            case 7: return .lea_absW
            case 8: return .lea_absL
            case 9: return .lea_pcDisp
            case 10: return .lea_pcIndex
            default: return nil
            }
        case .pea:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .pea_ind
            case 5: return .pea_disp
            case 6: return .pea_index
            case 7: return .pea_absW
            case 8: return .pea_absL
            case 9: return .pea_pcDisp
            case 10: return .pea_pcIndex
            default: return nil
            }
        case .jsr:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .jsr_ind
            case 5: return .jsr_disp
            case 6: return .jsr_index
            case 7: return .jsr_absW
            case 8: return .jsr_absL
            case 9: return .jsr_pcDisp
            case 10: return .jsr_pcIndex
            default: return nil
            }
        case .jmp:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .jmp_ind
            case 5: return .jmp_disp
            case 6: return .jmp_index
            case 7: return .jmp_absW
            case 8: return .jmp_absL
            case 9: return .jmp_pcDisp
            case 10: return .jmp_pcIndex
            default: return nil
            }
        case .clrB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .clrB_dn
            case 2: return .clrB_ind
            case 3: return .clrB_inc
            case 4: return .clrB_dec
            case 5: return .clrB_disp
            case 6: return .clrB_index
            case 7: return .clrB_absW
            case 8: return .clrB_absL
            default: return nil
            }
        case .tstB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .tstB_dn
            case 2: return .tstB_ind
            case 3: return .tstB_inc
            case 4: return .tstB_dec
            case 5: return .tstB_disp
            case 6: return .tstB_index
            case 7: return .tstB_absW
            case 8: return .tstB_absL
            default: return nil
            }
        case .clrW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .clrW_dn
            case 2: return .clrW_ind
            case 3: return .clrW_inc
            case 4: return .clrW_dec
            case 5: return .clrW_disp
            case 6: return .clrW_index
            case 7: return .clrW_absW
            case 8: return .clrW_absL
            default: return nil
            }
        case .tstW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .tstW_dn
            case 2: return .tstW_ind
            case 3: return .tstW_inc
            case 4: return .tstW_dec
            case 5: return .tstW_disp
            case 6: return .tstW_index
            case 7: return .tstW_absW
            case 8: return .tstW_absL
            default: return nil
            }
        case .clrL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .clrL_dn
            case 2: return .clrL_ind
            case 3: return .clrL_inc
            case 4: return .clrL_dec
            case 5: return .clrL_disp
            case 6: return .clrL_index
            case 7: return .clrL_absW
            case 8: return .clrL_absL
            default: return nil
            }
        case .tstL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .tstL_dn
            case 2: return .tstL_ind
            case 3: return .tstL_inc
            case 4: return .tstL_dec
            case 5: return .tstL_disp
            case 6: return .tstL_index
            case 7: return .tstL_absW
            case 8: return .tstL_absL
            default: return nil
            }
        case .dbcc:
            switch ((op >> 8) & 15) {
            case 0: return .dbcc_t
            case 2: return .dbcc_hi
            case 3: return .dbcc_ls
            case 4: return .dbcc_cc
            case 5: return .dbcc_cs
            case 6: return .dbcc_ne
            case 7: return .dbcc_eq
            case 8: return .dbcc_vc
            case 9: return .dbcc_vs
            case 10: return .dbcc_pl
            case 11: return .dbcc_mi
            case 12: return .dbcc_ge
            case 13: return .dbcc_lt
            case 14: return .dbcc_gt
            case 15: return .dbcc_le
            default: return nil
            }
        case .addqB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addqB_dn
            case 2: return .addqB_ind
            case 3: return .addqB_inc
            case 4: return .addqB_dec
            case 5: return .addqB_disp
            case 6: return .addqB_index
            case 7: return .addqB_absW
            case 8: return .addqB_absL
            default: return nil
            }
        case .subqB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subqB_dn
            case 2: return .subqB_ind
            case 3: return .subqB_inc
            case 4: return .subqB_dec
            case 5: return .subqB_disp
            case 6: return .subqB_index
            case 7: return .subqB_absW
            case 8: return .subqB_absL
            default: return nil
            }
        case .addqW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addqW_dn
            case 2: return .addqW_ind
            case 3: return .addqW_inc
            case 4: return .addqW_dec
            case 5: return .addqW_disp
            case 6: return .addqW_index
            case 7: return .addqW_absW
            case 8: return .addqW_absL
            default: return nil
            }
        case .subqW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subqW_dn
            case 2: return .subqW_ind
            case 3: return .subqW_inc
            case 4: return .subqW_dec
            case 5: return .subqW_disp
            case 6: return .subqW_index
            case 7: return .subqW_absW
            case 8: return .subqW_absL
            default: return nil
            }
        case .addqL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addqL_dn
            case 2: return .addqL_ind
            case 3: return .addqL_inc
            case 4: return .addqL_dec
            case 5: return .addqL_disp
            case 6: return .addqL_index
            case 7: return .addqL_absW
            case 8: return .addqL_absL
            default: return nil
            }
        case .subqL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subqL_dn
            case 2: return .subqL_ind
            case 3: return .subqL_inc
            case 4: return .subqL_dec
            case 5: return .subqL_disp
            case 6: return .subqL_index
            case 7: return .subqL_absW
            case 8: return .subqL_absL
            default: return nil
            }
        case .orB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .orB_dn
            case 2: return .orB_ind
            case 3: return .orB_inc
            case 4: return .orB_dec
            case 5: return .orB_disp
            case 6: return .orB_index
            case 7: return .orB_absW
            case 8: return .orB_absL
            case 9: return .orB_pcDisp
            case 10: return .orB_pcIndex
            case 11: return .orB_imm
            default: return nil
            }
        case .orEaB:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .orEaB_ind
            case 3: return .orEaB_inc
            case 4: return .orEaB_dec
            case 5: return .orEaB_disp
            case 6: return .orEaB_index
            case 7: return .orEaB_absW
            case 8: return .orEaB_absL
            default: return nil
            }
        case .orW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .orW_dn
            case 2: return .orW_ind
            case 3: return .orW_inc
            case 4: return .orW_dec
            case 5: return .orW_disp
            case 6: return .orW_index
            case 7: return .orW_absW
            case 8: return .orW_absL
            case 9: return .orW_pcDisp
            case 10: return .orW_pcIndex
            case 11: return .orW_imm
            default: return nil
            }
        case .orEaW:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .orEaW_ind
            case 3: return .orEaW_inc
            case 4: return .orEaW_dec
            case 5: return .orEaW_disp
            case 6: return .orEaW_index
            case 7: return .orEaW_absW
            case 8: return .orEaW_absL
            default: return nil
            }
        case .orL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .orL_dn
            case 2: return .orL_ind
            case 3: return .orL_inc
            case 4: return .orL_dec
            case 5: return .orL_disp
            case 6: return .orL_index
            case 7: return .orL_absW
            case 8: return .orL_absL
            case 9: return .orL_pcDisp
            case 10: return .orL_pcIndex
            case 11: return .orL_imm
            default: return nil
            }
        case .orEaL:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .orEaL_ind
            case 3: return .orEaL_inc
            case 4: return .orEaL_dec
            case 5: return .orEaL_disp
            case 6: return .orEaL_index
            case 7: return .orEaL_absW
            case 8: return .orEaL_absL
            default: return nil
            }
        case .andB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .andB_dn
            case 2: return .andB_ind
            case 3: return .andB_inc
            case 4: return .andB_dec
            case 5: return .andB_disp
            case 6: return .andB_index
            case 7: return .andB_absW
            case 8: return .andB_absL
            case 9: return .andB_pcDisp
            case 10: return .andB_pcIndex
            case 11: return .andB_imm
            default: return nil
            }
        case .andEaB:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .andEaB_ind
            case 3: return .andEaB_inc
            case 4: return .andEaB_dec
            case 5: return .andEaB_disp
            case 6: return .andEaB_index
            case 7: return .andEaB_absW
            case 8: return .andEaB_absL
            default: return nil
            }
        case .andW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .andW_dn
            case 2: return .andW_ind
            case 3: return .andW_inc
            case 4: return .andW_dec
            case 5: return .andW_disp
            case 6: return .andW_index
            case 7: return .andW_absW
            case 8: return .andW_absL
            case 9: return .andW_pcDisp
            case 10: return .andW_pcIndex
            case 11: return .andW_imm
            default: return nil
            }
        case .andEaW:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .andEaW_ind
            case 3: return .andEaW_inc
            case 4: return .andEaW_dec
            case 5: return .andEaW_disp
            case 6: return .andEaW_index
            case 7: return .andEaW_absW
            case 8: return .andEaW_absL
            default: return nil
            }
        case .andL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .andL_dn
            case 2: return .andL_ind
            case 3: return .andL_inc
            case 4: return .andL_dec
            case 5: return .andL_disp
            case 6: return .andL_index
            case 7: return .andL_absW
            case 8: return .andL_absL
            case 9: return .andL_pcDisp
            case 10: return .andL_pcIndex
            case 11: return .andL_imm
            default: return nil
            }
        case .andEaL:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .andEaL_ind
            case 3: return .andEaL_inc
            case 4: return .andEaL_dec
            case 5: return .andEaL_disp
            case 6: return .andEaL_index
            case 7: return .andEaL_absW
            case 8: return .andEaL_absL
            default: return nil
            }
        case .addB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addB_dn
            case 2: return .addB_ind
            case 3: return .addB_inc
            case 4: return .addB_dec
            case 5: return .addB_disp
            case 6: return .addB_index
            case 7: return .addB_absW
            case 8: return .addB_absL
            case 9: return .addB_pcDisp
            case 10: return .addB_pcIndex
            case 11: return .addB_imm
            default: return nil
            }
        case .addEaB:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .addEaB_ind
            case 3: return .addEaB_inc
            case 4: return .addEaB_dec
            case 5: return .addEaB_disp
            case 6: return .addEaB_index
            case 7: return .addEaB_absW
            case 8: return .addEaB_absL
            default: return nil
            }
        case .addW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addW_dn
            case 1: return .addW_an
            case 2: return .addW_ind
            case 3: return .addW_inc
            case 4: return .addW_dec
            case 5: return .addW_disp
            case 6: return .addW_index
            case 7: return .addW_absW
            case 8: return .addW_absL
            case 9: return .addW_pcDisp
            case 10: return .addW_pcIndex
            case 11: return .addW_imm
            default: return nil
            }
        case .addEaW:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .addEaW_ind
            case 3: return .addEaW_inc
            case 4: return .addEaW_dec
            case 5: return .addEaW_disp
            case 6: return .addEaW_index
            case 7: return .addEaW_absW
            case 8: return .addEaW_absL
            default: return nil
            }
        case .addL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addL_dn
            case 1: return .addL_an
            case 2: return .addL_ind
            case 3: return .addL_inc
            case 4: return .addL_dec
            case 5: return .addL_disp
            case 6: return .addL_index
            case 7: return .addL_absW
            case 8: return .addL_absL
            case 9: return .addL_pcDisp
            case 10: return .addL_pcIndex
            case 11: return .addL_imm
            default: return nil
            }
        case .addEaL:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .addEaL_ind
            case 3: return .addEaL_inc
            case 4: return .addEaL_dec
            case 5: return .addEaL_disp
            case 6: return .addEaL_index
            case 7: return .addEaL_absW
            case 8: return .addEaL_absL
            default: return nil
            }
        case .subB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subB_dn
            case 2: return .subB_ind
            case 3: return .subB_inc
            case 4: return .subB_dec
            case 5: return .subB_disp
            case 6: return .subB_index
            case 7: return .subB_absW
            case 8: return .subB_absL
            case 9: return .subB_pcDisp
            case 10: return .subB_pcIndex
            case 11: return .subB_imm
            default: return nil
            }
        case .subEaB:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .subEaB_ind
            case 3: return .subEaB_inc
            case 4: return .subEaB_dec
            case 5: return .subEaB_disp
            case 6: return .subEaB_index
            case 7: return .subEaB_absW
            case 8: return .subEaB_absL
            default: return nil
            }
        case .subW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subW_dn
            case 1: return .subW_an
            case 2: return .subW_ind
            case 3: return .subW_inc
            case 4: return .subW_dec
            case 5: return .subW_disp
            case 6: return .subW_index
            case 7: return .subW_absW
            case 8: return .subW_absL
            case 9: return .subW_pcDisp
            case 10: return .subW_pcIndex
            case 11: return .subW_imm
            default: return nil
            }
        case .subEaW:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .subEaW_ind
            case 3: return .subEaW_inc
            case 4: return .subEaW_dec
            case 5: return .subEaW_disp
            case 6: return .subEaW_index
            case 7: return .subEaW_absW
            case 8: return .subEaW_absL
            default: return nil
            }
        case .subL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subL_dn
            case 1: return .subL_an
            case 2: return .subL_ind
            case 3: return .subL_inc
            case 4: return .subL_dec
            case 5: return .subL_disp
            case 6: return .subL_index
            case 7: return .subL_absW
            case 8: return .subL_absL
            case 9: return .subL_pcDisp
            case 10: return .subL_pcIndex
            case 11: return .subL_imm
            default: return nil
            }
        case .subEaL:
            switch (M68000Step.sourceMode(op)) {
            case 2: return .subEaL_ind
            case 3: return .subEaL_inc
            case 4: return .subEaL_dec
            case 5: return .subEaL_disp
            case 6: return .subEaL_index
            case 7: return .subEaL_absW
            case 8: return .subEaL_absL
            default: return nil
            }
        case .addxB:
            switch (op & 8 != 0 ? 1 : 0) {
            case 0: return .addxB_registers
            case 1: return .addxB_memory
            default: return nil
            }
        case .subxB:
            switch (op & 8 != 0 ? 1 : 0) {
            case 0: return .subxB_registers
            case 1: return .subxB_memory
            default: return nil
            }
        case .addxW:
            switch (op & 8 != 0 ? 1 : 0) {
            case 0: return .addxW_registers
            case 1: return .addxW_memory
            default: return nil
            }
        case .subxW:
            switch (op & 8 != 0 ? 1 : 0) {
            case 0: return .subxW_registers
            case 1: return .subxW_memory
            default: return nil
            }
        case .addxL:
            switch (op & 8 != 0 ? 1 : 0) {
            case 0: return .addxL_registers
            case 1: return .addxL_memory
            default: return nil
            }
        case .subxL:
            switch (op & 8 != 0 ? 1 : 0) {
            case 0: return .subxL_registers
            case 1: return .subxL_memory
            default: return nil
            }
        case .eorB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .eorB_dn
            case 2: return .eorB_ind
            case 3: return .eorB_inc
            case 4: return .eorB_dec
            case 5: return .eorB_disp
            case 6: return .eorB_index
            case 7: return .eorB_absW
            case 8: return .eorB_absL
            default: return nil
            }
        case .cmpB:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .cmpB_dn
            case 2: return .cmpB_ind
            case 3: return .cmpB_inc
            case 4: return .cmpB_dec
            case 5: return .cmpB_disp
            case 6: return .cmpB_index
            case 7: return .cmpB_absW
            case 8: return .cmpB_absL
            case 9: return .cmpB_pcDisp
            case 10: return .cmpB_pcIndex
            case 11: return .cmpB_imm
            default: return nil
            }
        case .eorW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .eorW_dn
            case 2: return .eorW_ind
            case 3: return .eorW_inc
            case 4: return .eorW_dec
            case 5: return .eorW_disp
            case 6: return .eorW_index
            case 7: return .eorW_absW
            case 8: return .eorW_absL
            default: return nil
            }
        case .cmpW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .cmpW_dn
            case 1: return .cmpW_an
            case 2: return .cmpW_ind
            case 3: return .cmpW_inc
            case 4: return .cmpW_dec
            case 5: return .cmpW_disp
            case 6: return .cmpW_index
            case 7: return .cmpW_absW
            case 8: return .cmpW_absL
            case 9: return .cmpW_pcDisp
            case 10: return .cmpW_pcIndex
            case 11: return .cmpW_imm
            default: return nil
            }
        case .eorL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .eorL_dn
            case 2: return .eorL_ind
            case 3: return .eorL_inc
            case 4: return .eorL_dec
            case 5: return .eorL_disp
            case 6: return .eorL_index
            case 7: return .eorL_absW
            case 8: return .eorL_absL
            default: return nil
            }
        case .cmpL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .cmpL_dn
            case 1: return .cmpL_an
            case 2: return .cmpL_ind
            case 3: return .cmpL_inc
            case 4: return .cmpL_dec
            case 5: return .cmpL_disp
            case 6: return .cmpL_index
            case 7: return .cmpL_absW
            case 8: return .cmpL_absL
            case 9: return .cmpL_pcDisp
            case 10: return .cmpL_pcIndex
            case 11: return .cmpL_imm
            default: return nil
            }
        case .cmpaW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .cmpaW_dn
            case 1: return .cmpaW_an
            case 2: return .cmpaW_ind
            case 3: return .cmpaW_inc
            case 4: return .cmpaW_dec
            case 5: return .cmpaW_disp
            case 6: return .cmpaW_index
            case 7: return .cmpaW_absW
            case 8: return .cmpaW_absL
            case 9: return .cmpaW_pcDisp
            case 10: return .cmpaW_pcIndex
            case 11: return .cmpaW_imm
            default: return nil
            }
        case .addaW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addaW_dn
            case 1: return .addaW_an
            case 2: return .addaW_ind
            case 3: return .addaW_inc
            case 4: return .addaW_dec
            case 5: return .addaW_disp
            case 6: return .addaW_index
            case 7: return .addaW_absW
            case 8: return .addaW_absL
            case 9: return .addaW_pcDisp
            case 10: return .addaW_pcIndex
            case 11: return .addaW_imm
            default: return nil
            }
        case .subaW:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subaW_dn
            case 1: return .subaW_an
            case 2: return .subaW_ind
            case 3: return .subaW_inc
            case 4: return .subaW_dec
            case 5: return .subaW_disp
            case 6: return .subaW_index
            case 7: return .subaW_absW
            case 8: return .subaW_absL
            case 9: return .subaW_pcDisp
            case 10: return .subaW_pcIndex
            case 11: return .subaW_imm
            default: return nil
            }
        case .cmpaL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .cmpaL_dn
            case 1: return .cmpaL_an
            case 2: return .cmpaL_ind
            case 3: return .cmpaL_inc
            case 4: return .cmpaL_dec
            case 5: return .cmpaL_disp
            case 6: return .cmpaL_index
            case 7: return .cmpaL_absW
            case 8: return .cmpaL_absL
            case 9: return .cmpaL_pcDisp
            case 10: return .cmpaL_pcIndex
            case 11: return .cmpaL_imm
            default: return nil
            }
        case .addaL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .addaL_dn
            case 1: return .addaL_an
            case 2: return .addaL_ind
            case 3: return .addaL_inc
            case 4: return .addaL_dec
            case 5: return .addaL_disp
            case 6: return .addaL_index
            case 7: return .addaL_absW
            case 8: return .addaL_absL
            case 9: return .addaL_pcDisp
            case 10: return .addaL_pcIndex
            case 11: return .addaL_imm
            default: return nil
            }
        case .subaL:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .subaL_dn
            case 1: return .subaL_an
            case 2: return .subaL_ind
            case 3: return .subaL_inc
            case 4: return .subaL_dec
            case 5: return .subaL_disp
            case 6: return .subaL_index
            case 7: return .subaL_absW
            case 8: return .subaL_absL
            case 9: return .subaL_pcDisp
            case 10: return .subaL_pcIndex
            case 11: return .subaL_imm
            default: return nil
            }
        case .mulu:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .mulu_dn
            case 2: return .mulu_ind
            case 3: return .mulu_inc
            case 4: return .mulu_dec
            case 5: return .mulu_disp
            case 6: return .mulu_index
            case 7: return .mulu_absW
            case 8: return .mulu_absL
            case 9: return .mulu_pcDisp
            case 10: return .mulu_pcIndex
            case 11: return .mulu_imm
            default: return nil
            }
        case .muls:
            switch (M68000Step.sourceMode(op)) {
            case 0: return .muls_dn
            case 2: return .muls_ind
            case 3: return .muls_inc
            case 4: return .muls_dec
            case 5: return .muls_disp
            case 6: return .muls_index
            case 7: return .muls_absW
            case 8: return .muls_absL
            case 9: return .muls_pcDisp
            case 10: return .muls_pcIndex
            case 11: return .muls_imm
            default: return nil
            }
        case .shiftRegister:
            switch ((op >> 3) & 3) << 12 | (op & 0x100 != 0 ? 1 : 0) << 8 | ((op >> 6) & 3) << 4 | (op & 0x20 != 0 ? 1 : 0) {
            case 0: return .shiftRegister_as_r_B_byCount
            case 1: return .shiftRegister_as_r_B_byRegister
            case 16: return .shiftRegister_as_r_W_byCount
            case 17: return .shiftRegister_as_r_W_byRegister
            case 32: return .shiftRegister_as_r_L_byCount
            case 33: return .shiftRegister_as_r_L_byRegister
            case 256: return .shiftRegister_as_l_B_byCount
            case 257: return .shiftRegister_as_l_B_byRegister
            case 272: return .shiftRegister_as_l_W_byCount
            case 273: return .shiftRegister_as_l_W_byRegister
            case 288: return .shiftRegister_as_l_L_byCount
            case 289: return .shiftRegister_as_l_L_byRegister
            case 4096: return .shiftRegister_ls_r_B_byCount
            case 4097: return .shiftRegister_ls_r_B_byRegister
            case 4112: return .shiftRegister_ls_r_W_byCount
            case 4113: return .shiftRegister_ls_r_W_byRegister
            case 4128: return .shiftRegister_ls_r_L_byCount
            case 4129: return .shiftRegister_ls_r_L_byRegister
            case 4352: return .shiftRegister_ls_l_B_byCount
            case 4353: return .shiftRegister_ls_l_B_byRegister
            case 4368: return .shiftRegister_ls_l_W_byCount
            case 4369: return .shiftRegister_ls_l_W_byRegister
            case 4384: return .shiftRegister_ls_l_L_byCount
            case 4385: return .shiftRegister_ls_l_L_byRegister
            case 8192: return .shiftRegister_rox_r_B_byCount
            case 8193: return .shiftRegister_rox_r_B_byRegister
            case 8208: return .shiftRegister_rox_r_W_byCount
            case 8209: return .shiftRegister_rox_r_W_byRegister
            case 8224: return .shiftRegister_rox_r_L_byCount
            case 8225: return .shiftRegister_rox_r_L_byRegister
            case 8448: return .shiftRegister_rox_l_B_byCount
            case 8449: return .shiftRegister_rox_l_B_byRegister
            case 8464: return .shiftRegister_rox_l_W_byCount
            case 8465: return .shiftRegister_rox_l_W_byRegister
            case 8480: return .shiftRegister_rox_l_L_byCount
            case 8481: return .shiftRegister_rox_l_L_byRegister
            case 12288: return .shiftRegister_ro_r_B_byCount
            case 12289: return .shiftRegister_ro_r_B_byRegister
            case 12304: return .shiftRegister_ro_r_W_byCount
            case 12305: return .shiftRegister_ro_r_W_byRegister
            case 12320: return .shiftRegister_ro_r_L_byCount
            case 12321: return .shiftRegister_ro_r_L_byRegister
            case 12544: return .shiftRegister_ro_l_B_byCount
            case 12545: return .shiftRegister_ro_l_B_byRegister
            case 12560: return .shiftRegister_ro_l_W_byCount
            case 12561: return .shiftRegister_ro_l_W_byRegister
            case 12576: return .shiftRegister_ro_l_L_byCount
            case 12577: return .shiftRegister_ro_l_L_byRegister
            default: return nil
            }
        default: return nil
        }
    }
}

extension M68000 {
    @inline(__always) mutating func run(_ step: M68000Step, _ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        switch step {
        case .oriB: return run_oriB(op, start, k)
        case .oriW: return run_oriW(op, start, k)
        case .oriL: return run_oriL(op, start, k)
        case .andiB: return run_andiB(op, start, k)
        case .andiW: return run_andiW(op, start, k)
        case .andiL: return run_andiL(op, start, k)
        case .subiB: return run_subiB(op, start, k)
        case .subiW: return run_subiW(op, start, k)
        case .subiL: return run_subiL(op, start, k)
        case .addiB: return run_addiB(op, start, k)
        case .addiW: return run_addiW(op, start, k)
        case .addiL: return run_addiL(op, start, k)
        case .eoriB: return run_eoriB(op, start, k)
        case .eoriW: return run_eoriW(op, start, k)
        case .eoriL: return run_eoriL(op, start, k)
        case .cmpiB: return run_cmpiB(op, start, k)
        case .cmpiW: return run_cmpiW(op, start, k)
        case .cmpiL: return run_cmpiL(op, start, k)
        case .bitDynamic: return run_bitDynamic(op, start, k)
        case .bitStatic: return run_bitStatic(op, start, k)
        case .moveB: return run_moveB(op, start, k)
        case .moveW: return run_moveW(op, start, k)
        case .moveL: return run_moveL(op, start, k)
        case .moveaB: return run_moveaB(op, start, k)
        case .moveaW: return run_moveaW(op, start, k)
        case .moveaL: return run_moveaL(op, start, k)
        case .lea: return run_lea(op, start, k)
        case .pea: return run_pea(op, start, k)
        case .jsr: return run_jsr(op, start, k)
        case .jmp: return run_jmp(op, start, k)
        case .clrB: return run_clrB(op, start, k)
        case .tstB: return run_tstB(op, start, k)
        case .clrW: return run_clrW(op, start, k)
        case .tstW: return run_tstW(op, start, k)
        case .clrL: return run_clrL(op, start, k)
        case .tstL: return run_tstL(op, start, k)
        case .neg: return run_neg(op, start, k)
        case .not: return run_not(op, start, k)
        case .swap: return run_swap(op, start, k)
        case .extW: return run_extW(op, start, k)
        case .extL: return run_extL(op, start, k)
        case .movemStoreW: return run_movemStoreW(op, start, k)
        case .movemStoreL: return run_movemStoreL(op, start, k)
        case .movemLoadW: return run_movemLoadW(op, start, k)
        case .movemLoadL: return run_movemLoadL(op, start, k)
        case .nop: return run_nop(op, start, k)
        case .rts: return run_rts(op, start, k)
        case .rte: return run_rte(op, start, k)
        case .dbra: return run_dbra(op, start, k)
        case .dbcc: return run_dbcc(op, start, k)
        case .scc: return run_scc(op, start, k)
        case .addqA: return run_addqA(op, start, k)
        case .subqA: return run_subqA(op, start, k)
        case .addqB: return run_addqB(op, start, k)
        case .subqB: return run_subqB(op, start, k)
        case .addqW: return run_addqW(op, start, k)
        case .subqW: return run_subqW(op, start, k)
        case .addqL: return run_addqL(op, start, k)
        case .subqL: return run_subqL(op, start, k)
        case .bra: return run_bra(op, start, k)
        case .bsr: return run_bsr(op, start, k)
        case .bhi: return run_bhi(op, start, k)
        case .bls: return run_bls(op, start, k)
        case .bcc: return run_bcc(op, start, k)
        case .bcs: return run_bcs(op, start, k)
        case .bne: return run_bne(op, start, k)
        case .beq: return run_beq(op, start, k)
        case .bvc: return run_bvc(op, start, k)
        case .bvs: return run_bvs(op, start, k)
        case .bpl: return run_bpl(op, start, k)
        case .bmi: return run_bmi(op, start, k)
        case .bge: return run_bge(op, start, k)
        case .blt: return run_blt(op, start, k)
        case .bgt: return run_bgt(op, start, k)
        case .ble: return run_ble(op, start, k)
        case .moveq: return run_moveq(op, start, k)
        case .orB: return run_orB(op, start, k)
        case .orEaB: return run_orEaB(op, start, k)
        case .orW: return run_orW(op, start, k)
        case .orEaW: return run_orEaW(op, start, k)
        case .orL: return run_orL(op, start, k)
        case .orEaL: return run_orEaL(op, start, k)
        case .andB: return run_andB(op, start, k)
        case .andEaB: return run_andEaB(op, start, k)
        case .andW: return run_andW(op, start, k)
        case .andEaW: return run_andEaW(op, start, k)
        case .andL: return run_andL(op, start, k)
        case .andEaL: return run_andEaL(op, start, k)
        case .addB: return run_addB(op, start, k)
        case .addEaB: return run_addEaB(op, start, k)
        case .addW: return run_addW(op, start, k)
        case .addEaW: return run_addEaW(op, start, k)
        case .addL: return run_addL(op, start, k)
        case .addEaL: return run_addEaL(op, start, k)
        case .subB: return run_subB(op, start, k)
        case .subEaB: return run_subEaB(op, start, k)
        case .subW: return run_subW(op, start, k)
        case .subEaW: return run_subEaW(op, start, k)
        case .subL: return run_subL(op, start, k)
        case .subEaL: return run_subEaL(op, start, k)
        case .addxB: return run_addxB(op, start, k)
        case .subxB: return run_subxB(op, start, k)
        case .addxW: return run_addxW(op, start, k)
        case .subxW: return run_subxW(op, start, k)
        case .addxL: return run_addxL(op, start, k)
        case .subxL: return run_subxL(op, start, k)
        case .eorB: return run_eorB(op, start, k)
        case .cmpB: return run_cmpB(op, start, k)
        case .eorW: return run_eorW(op, start, k)
        case .cmpW: return run_cmpW(op, start, k)
        case .eorL: return run_eorL(op, start, k)
        case .cmpL: return run_cmpL(op, start, k)
        case .cmpaW: return run_cmpaW(op, start, k)
        case .addaW: return run_addaW(op, start, k)
        case .subaW: return run_subaW(op, start, k)
        case .cmpaL: return run_cmpaL(op, start, k)
        case .addaL: return run_addaL(op, start, k)
        case .subaL: return run_subaL(op, start, k)
        case .mulu: return run_mulu(op, start, k)
        case .muls: return run_muls(op, start, k)
        case .shiftRegister: return run_shiftRegister(op, start, k)
        case .oriB_dn: return run_oriB_dn(op, start, k)
        case .oriB_ind: return run_oriB_ind(op, start, k)
        case .oriB_inc: return run_oriB_inc(op, start, k)
        case .oriB_dec: return run_oriB_dec(op, start, k)
        case .oriB_disp: return run_oriB_disp(op, start, k)
        case .oriB_index: return run_oriB_index(op, start, k)
        case .oriB_absW: return run_oriB_absW(op, start, k)
        case .oriB_absL: return run_oriB_absL(op, start, k)
        case .oriW_dn: return run_oriW_dn(op, start, k)
        case .oriW_ind: return run_oriW_ind(op, start, k)
        case .oriW_inc: return run_oriW_inc(op, start, k)
        case .oriW_dec: return run_oriW_dec(op, start, k)
        case .oriW_disp: return run_oriW_disp(op, start, k)
        case .oriW_index: return run_oriW_index(op, start, k)
        case .oriW_absW: return run_oriW_absW(op, start, k)
        case .oriW_absL: return run_oriW_absL(op, start, k)
        case .oriL_dn: return run_oriL_dn(op, start, k)
        case .oriL_ind: return run_oriL_ind(op, start, k)
        case .oriL_inc: return run_oriL_inc(op, start, k)
        case .oriL_dec: return run_oriL_dec(op, start, k)
        case .oriL_disp: return run_oriL_disp(op, start, k)
        case .oriL_index: return run_oriL_index(op, start, k)
        case .oriL_absW: return run_oriL_absW(op, start, k)
        case .oriL_absL: return run_oriL_absL(op, start, k)
        case .andiB_dn: return run_andiB_dn(op, start, k)
        case .andiB_ind: return run_andiB_ind(op, start, k)
        case .andiB_inc: return run_andiB_inc(op, start, k)
        case .andiB_dec: return run_andiB_dec(op, start, k)
        case .andiB_disp: return run_andiB_disp(op, start, k)
        case .andiB_index: return run_andiB_index(op, start, k)
        case .andiB_absW: return run_andiB_absW(op, start, k)
        case .andiB_absL: return run_andiB_absL(op, start, k)
        case .andiW_dn: return run_andiW_dn(op, start, k)
        case .andiW_ind: return run_andiW_ind(op, start, k)
        case .andiW_inc: return run_andiW_inc(op, start, k)
        case .andiW_dec: return run_andiW_dec(op, start, k)
        case .andiW_disp: return run_andiW_disp(op, start, k)
        case .andiW_index: return run_andiW_index(op, start, k)
        case .andiW_absW: return run_andiW_absW(op, start, k)
        case .andiW_absL: return run_andiW_absL(op, start, k)
        case .andiL_dn: return run_andiL_dn(op, start, k)
        case .andiL_ind: return run_andiL_ind(op, start, k)
        case .andiL_inc: return run_andiL_inc(op, start, k)
        case .andiL_dec: return run_andiL_dec(op, start, k)
        case .andiL_disp: return run_andiL_disp(op, start, k)
        case .andiL_index: return run_andiL_index(op, start, k)
        case .andiL_absW: return run_andiL_absW(op, start, k)
        case .andiL_absL: return run_andiL_absL(op, start, k)
        case .subiB_dn: return run_subiB_dn(op, start, k)
        case .subiB_ind: return run_subiB_ind(op, start, k)
        case .subiB_inc: return run_subiB_inc(op, start, k)
        case .subiB_dec: return run_subiB_dec(op, start, k)
        case .subiB_disp: return run_subiB_disp(op, start, k)
        case .subiB_index: return run_subiB_index(op, start, k)
        case .subiB_absW: return run_subiB_absW(op, start, k)
        case .subiB_absL: return run_subiB_absL(op, start, k)
        case .subiW_dn: return run_subiW_dn(op, start, k)
        case .subiW_ind: return run_subiW_ind(op, start, k)
        case .subiW_inc: return run_subiW_inc(op, start, k)
        case .subiW_dec: return run_subiW_dec(op, start, k)
        case .subiW_disp: return run_subiW_disp(op, start, k)
        case .subiW_index: return run_subiW_index(op, start, k)
        case .subiW_absW: return run_subiW_absW(op, start, k)
        case .subiW_absL: return run_subiW_absL(op, start, k)
        case .subiL_dn: return run_subiL_dn(op, start, k)
        case .subiL_ind: return run_subiL_ind(op, start, k)
        case .subiL_inc: return run_subiL_inc(op, start, k)
        case .subiL_dec: return run_subiL_dec(op, start, k)
        case .subiL_disp: return run_subiL_disp(op, start, k)
        case .subiL_index: return run_subiL_index(op, start, k)
        case .subiL_absW: return run_subiL_absW(op, start, k)
        case .subiL_absL: return run_subiL_absL(op, start, k)
        case .addiB_dn: return run_addiB_dn(op, start, k)
        case .addiB_ind: return run_addiB_ind(op, start, k)
        case .addiB_inc: return run_addiB_inc(op, start, k)
        case .addiB_dec: return run_addiB_dec(op, start, k)
        case .addiB_disp: return run_addiB_disp(op, start, k)
        case .addiB_index: return run_addiB_index(op, start, k)
        case .addiB_absW: return run_addiB_absW(op, start, k)
        case .addiB_absL: return run_addiB_absL(op, start, k)
        case .addiW_dn: return run_addiW_dn(op, start, k)
        case .addiW_ind: return run_addiW_ind(op, start, k)
        case .addiW_inc: return run_addiW_inc(op, start, k)
        case .addiW_dec: return run_addiW_dec(op, start, k)
        case .addiW_disp: return run_addiW_disp(op, start, k)
        case .addiW_index: return run_addiW_index(op, start, k)
        case .addiW_absW: return run_addiW_absW(op, start, k)
        case .addiW_absL: return run_addiW_absL(op, start, k)
        case .addiL_dn: return run_addiL_dn(op, start, k)
        case .addiL_ind: return run_addiL_ind(op, start, k)
        case .addiL_inc: return run_addiL_inc(op, start, k)
        case .addiL_dec: return run_addiL_dec(op, start, k)
        case .addiL_disp: return run_addiL_disp(op, start, k)
        case .addiL_index: return run_addiL_index(op, start, k)
        case .addiL_absW: return run_addiL_absW(op, start, k)
        case .addiL_absL: return run_addiL_absL(op, start, k)
        case .eoriB_dn: return run_eoriB_dn(op, start, k)
        case .eoriB_ind: return run_eoriB_ind(op, start, k)
        case .eoriB_inc: return run_eoriB_inc(op, start, k)
        case .eoriB_dec: return run_eoriB_dec(op, start, k)
        case .eoriB_disp: return run_eoriB_disp(op, start, k)
        case .eoriB_index: return run_eoriB_index(op, start, k)
        case .eoriB_absW: return run_eoriB_absW(op, start, k)
        case .eoriB_absL: return run_eoriB_absL(op, start, k)
        case .eoriW_dn: return run_eoriW_dn(op, start, k)
        case .eoriW_ind: return run_eoriW_ind(op, start, k)
        case .eoriW_inc: return run_eoriW_inc(op, start, k)
        case .eoriW_dec: return run_eoriW_dec(op, start, k)
        case .eoriW_disp: return run_eoriW_disp(op, start, k)
        case .eoriW_index: return run_eoriW_index(op, start, k)
        case .eoriW_absW: return run_eoriW_absW(op, start, k)
        case .eoriW_absL: return run_eoriW_absL(op, start, k)
        case .eoriL_dn: return run_eoriL_dn(op, start, k)
        case .eoriL_ind: return run_eoriL_ind(op, start, k)
        case .eoriL_inc: return run_eoriL_inc(op, start, k)
        case .eoriL_dec: return run_eoriL_dec(op, start, k)
        case .eoriL_disp: return run_eoriL_disp(op, start, k)
        case .eoriL_index: return run_eoriL_index(op, start, k)
        case .eoriL_absW: return run_eoriL_absW(op, start, k)
        case .eoriL_absL: return run_eoriL_absL(op, start, k)
        case .cmpiB_dn: return run_cmpiB_dn(op, start, k)
        case .cmpiB_ind: return run_cmpiB_ind(op, start, k)
        case .cmpiB_inc: return run_cmpiB_inc(op, start, k)
        case .cmpiB_dec: return run_cmpiB_dec(op, start, k)
        case .cmpiB_disp: return run_cmpiB_disp(op, start, k)
        case .cmpiB_index: return run_cmpiB_index(op, start, k)
        case .cmpiB_absW: return run_cmpiB_absW(op, start, k)
        case .cmpiB_absL: return run_cmpiB_absL(op, start, k)
        case .cmpiW_dn: return run_cmpiW_dn(op, start, k)
        case .cmpiW_ind: return run_cmpiW_ind(op, start, k)
        case .cmpiW_inc: return run_cmpiW_inc(op, start, k)
        case .cmpiW_dec: return run_cmpiW_dec(op, start, k)
        case .cmpiW_disp: return run_cmpiW_disp(op, start, k)
        case .cmpiW_index: return run_cmpiW_index(op, start, k)
        case .cmpiW_absW: return run_cmpiW_absW(op, start, k)
        case .cmpiW_absL: return run_cmpiW_absL(op, start, k)
        case .cmpiL_dn: return run_cmpiL_dn(op, start, k)
        case .cmpiL_ind: return run_cmpiL_ind(op, start, k)
        case .cmpiL_inc: return run_cmpiL_inc(op, start, k)
        case .cmpiL_dec: return run_cmpiL_dec(op, start, k)
        case .cmpiL_disp: return run_cmpiL_disp(op, start, k)
        case .cmpiL_index: return run_cmpiL_index(op, start, k)
        case .cmpiL_absW: return run_cmpiL_absW(op, start, k)
        case .cmpiL_absL: return run_cmpiL_absL(op, start, k)
        case .bitDynamic_btst_dn: return run_bitDynamic_btst_dn(op, start, k)
        case .bitDynamic_btst_ind: return run_bitDynamic_btst_ind(op, start, k)
        case .bitDynamic_btst_inc: return run_bitDynamic_btst_inc(op, start, k)
        case .bitDynamic_btst_dec: return run_bitDynamic_btst_dec(op, start, k)
        case .bitDynamic_btst_disp: return run_bitDynamic_btst_disp(op, start, k)
        case .bitDynamic_btst_index: return run_bitDynamic_btst_index(op, start, k)
        case .bitDynamic_btst_absW: return run_bitDynamic_btst_absW(op, start, k)
        case .bitDynamic_btst_absL: return run_bitDynamic_btst_absL(op, start, k)
        case .bitDynamic_bchg_dn: return run_bitDynamic_bchg_dn(op, start, k)
        case .bitDynamic_bchg_ind: return run_bitDynamic_bchg_ind(op, start, k)
        case .bitDynamic_bchg_inc: return run_bitDynamic_bchg_inc(op, start, k)
        case .bitDynamic_bchg_dec: return run_bitDynamic_bchg_dec(op, start, k)
        case .bitDynamic_bchg_disp: return run_bitDynamic_bchg_disp(op, start, k)
        case .bitDynamic_bchg_index: return run_bitDynamic_bchg_index(op, start, k)
        case .bitDynamic_bchg_absW: return run_bitDynamic_bchg_absW(op, start, k)
        case .bitDynamic_bchg_absL: return run_bitDynamic_bchg_absL(op, start, k)
        case .bitDynamic_bclr_dn: return run_bitDynamic_bclr_dn(op, start, k)
        case .bitDynamic_bclr_ind: return run_bitDynamic_bclr_ind(op, start, k)
        case .bitDynamic_bclr_inc: return run_bitDynamic_bclr_inc(op, start, k)
        case .bitDynamic_bclr_dec: return run_bitDynamic_bclr_dec(op, start, k)
        case .bitDynamic_bclr_disp: return run_bitDynamic_bclr_disp(op, start, k)
        case .bitDynamic_bclr_index: return run_bitDynamic_bclr_index(op, start, k)
        case .bitDynamic_bclr_absW: return run_bitDynamic_bclr_absW(op, start, k)
        case .bitDynamic_bclr_absL: return run_bitDynamic_bclr_absL(op, start, k)
        case .bitDynamic_bset_dn: return run_bitDynamic_bset_dn(op, start, k)
        case .bitDynamic_bset_ind: return run_bitDynamic_bset_ind(op, start, k)
        case .bitDynamic_bset_inc: return run_bitDynamic_bset_inc(op, start, k)
        case .bitDynamic_bset_dec: return run_bitDynamic_bset_dec(op, start, k)
        case .bitDynamic_bset_disp: return run_bitDynamic_bset_disp(op, start, k)
        case .bitDynamic_bset_index: return run_bitDynamic_bset_index(op, start, k)
        case .bitDynamic_bset_absW: return run_bitDynamic_bset_absW(op, start, k)
        case .bitDynamic_bset_absL: return run_bitDynamic_bset_absL(op, start, k)
        case .bitStatic_btst_dn: return run_bitStatic_btst_dn(op, start, k)
        case .bitStatic_btst_ind: return run_bitStatic_btst_ind(op, start, k)
        case .bitStatic_btst_inc: return run_bitStatic_btst_inc(op, start, k)
        case .bitStatic_btst_dec: return run_bitStatic_btst_dec(op, start, k)
        case .bitStatic_btst_disp: return run_bitStatic_btst_disp(op, start, k)
        case .bitStatic_btst_index: return run_bitStatic_btst_index(op, start, k)
        case .bitStatic_btst_absW: return run_bitStatic_btst_absW(op, start, k)
        case .bitStatic_btst_absL: return run_bitStatic_btst_absL(op, start, k)
        case .bitStatic_bchg_dn: return run_bitStatic_bchg_dn(op, start, k)
        case .bitStatic_bchg_ind: return run_bitStatic_bchg_ind(op, start, k)
        case .bitStatic_bchg_inc: return run_bitStatic_bchg_inc(op, start, k)
        case .bitStatic_bchg_dec: return run_bitStatic_bchg_dec(op, start, k)
        case .bitStatic_bchg_disp: return run_bitStatic_bchg_disp(op, start, k)
        case .bitStatic_bchg_index: return run_bitStatic_bchg_index(op, start, k)
        case .bitStatic_bchg_absW: return run_bitStatic_bchg_absW(op, start, k)
        case .bitStatic_bchg_absL: return run_bitStatic_bchg_absL(op, start, k)
        case .bitStatic_bclr_dn: return run_bitStatic_bclr_dn(op, start, k)
        case .bitStatic_bclr_ind: return run_bitStatic_bclr_ind(op, start, k)
        case .bitStatic_bclr_inc: return run_bitStatic_bclr_inc(op, start, k)
        case .bitStatic_bclr_dec: return run_bitStatic_bclr_dec(op, start, k)
        case .bitStatic_bclr_disp: return run_bitStatic_bclr_disp(op, start, k)
        case .bitStatic_bclr_index: return run_bitStatic_bclr_index(op, start, k)
        case .bitStatic_bclr_absW: return run_bitStatic_bclr_absW(op, start, k)
        case .bitStatic_bclr_absL: return run_bitStatic_bclr_absL(op, start, k)
        case .bitStatic_bset_dn: return run_bitStatic_bset_dn(op, start, k)
        case .bitStatic_bset_ind: return run_bitStatic_bset_ind(op, start, k)
        case .bitStatic_bset_inc: return run_bitStatic_bset_inc(op, start, k)
        case .bitStatic_bset_dec: return run_bitStatic_bset_dec(op, start, k)
        case .bitStatic_bset_disp: return run_bitStatic_bset_disp(op, start, k)
        case .bitStatic_bset_index: return run_bitStatic_bset_index(op, start, k)
        case .bitStatic_bset_absW: return run_bitStatic_bset_absW(op, start, k)
        case .bitStatic_bset_absL: return run_bitStatic_bset_absL(op, start, k)
        case .moveB_dn_dn: return run_moveB_dn_dn(op, start, k)
        case .moveB_dn_ind: return run_moveB_dn_ind(op, start, k)
        case .moveB_dn_inc: return run_moveB_dn_inc(op, start, k)
        case .moveB_dn_dec: return run_moveB_dn_dec(op, start, k)
        case .moveB_dn_disp: return run_moveB_dn_disp(op, start, k)
        case .moveB_dn_index: return run_moveB_dn_index(op, start, k)
        case .moveB_dn_absW: return run_moveB_dn_absW(op, start, k)
        case .moveB_dn_absL: return run_moveB_dn_absL(op, start, k)
        case .moveB_ind_dn: return run_moveB_ind_dn(op, start, k)
        case .moveB_ind_ind: return run_moveB_ind_ind(op, start, k)
        case .moveB_ind_inc: return run_moveB_ind_inc(op, start, k)
        case .moveB_ind_dec: return run_moveB_ind_dec(op, start, k)
        case .moveB_ind_disp: return run_moveB_ind_disp(op, start, k)
        case .moveB_ind_index: return run_moveB_ind_index(op, start, k)
        case .moveB_ind_absW: return run_moveB_ind_absW(op, start, k)
        case .moveB_ind_absL: return run_moveB_ind_absL(op, start, k)
        case .moveB_inc_dn: return run_moveB_inc_dn(op, start, k)
        case .moveB_inc_ind: return run_moveB_inc_ind(op, start, k)
        case .moveB_inc_inc: return run_moveB_inc_inc(op, start, k)
        case .moveB_inc_dec: return run_moveB_inc_dec(op, start, k)
        case .moveB_inc_disp: return run_moveB_inc_disp(op, start, k)
        case .moveB_inc_index: return run_moveB_inc_index(op, start, k)
        case .moveB_inc_absW: return run_moveB_inc_absW(op, start, k)
        case .moveB_inc_absL: return run_moveB_inc_absL(op, start, k)
        case .moveB_dec_dn: return run_moveB_dec_dn(op, start, k)
        case .moveB_dec_ind: return run_moveB_dec_ind(op, start, k)
        case .moveB_dec_inc: return run_moveB_dec_inc(op, start, k)
        case .moveB_dec_dec: return run_moveB_dec_dec(op, start, k)
        case .moveB_dec_disp: return run_moveB_dec_disp(op, start, k)
        case .moveB_dec_index: return run_moveB_dec_index(op, start, k)
        case .moveB_dec_absW: return run_moveB_dec_absW(op, start, k)
        case .moveB_dec_absL: return run_moveB_dec_absL(op, start, k)
        case .moveB_disp_dn: return run_moveB_disp_dn(op, start, k)
        case .moveB_disp_ind: return run_moveB_disp_ind(op, start, k)
        case .moveB_disp_inc: return run_moveB_disp_inc(op, start, k)
        case .moveB_disp_dec: return run_moveB_disp_dec(op, start, k)
        case .moveB_disp_disp: return run_moveB_disp_disp(op, start, k)
        case .moveB_disp_index: return run_moveB_disp_index(op, start, k)
        case .moveB_disp_absW: return run_moveB_disp_absW(op, start, k)
        case .moveB_disp_absL: return run_moveB_disp_absL(op, start, k)
        case .moveB_index_dn: return run_moveB_index_dn(op, start, k)
        case .moveB_index_ind: return run_moveB_index_ind(op, start, k)
        case .moveB_index_inc: return run_moveB_index_inc(op, start, k)
        case .moveB_index_dec: return run_moveB_index_dec(op, start, k)
        case .moveB_index_disp: return run_moveB_index_disp(op, start, k)
        case .moveB_index_index: return run_moveB_index_index(op, start, k)
        case .moveB_index_absW: return run_moveB_index_absW(op, start, k)
        case .moveB_index_absL: return run_moveB_index_absL(op, start, k)
        case .moveB_absW_dn: return run_moveB_absW_dn(op, start, k)
        case .moveB_absW_ind: return run_moveB_absW_ind(op, start, k)
        case .moveB_absW_inc: return run_moveB_absW_inc(op, start, k)
        case .moveB_absW_dec: return run_moveB_absW_dec(op, start, k)
        case .moveB_absW_disp: return run_moveB_absW_disp(op, start, k)
        case .moveB_absW_index: return run_moveB_absW_index(op, start, k)
        case .moveB_absW_absW: return run_moveB_absW_absW(op, start, k)
        case .moveB_absW_absL: return run_moveB_absW_absL(op, start, k)
        case .moveB_absL_dn: return run_moveB_absL_dn(op, start, k)
        case .moveB_absL_ind: return run_moveB_absL_ind(op, start, k)
        case .moveB_absL_inc: return run_moveB_absL_inc(op, start, k)
        case .moveB_absL_dec: return run_moveB_absL_dec(op, start, k)
        case .moveB_absL_disp: return run_moveB_absL_disp(op, start, k)
        case .moveB_absL_index: return run_moveB_absL_index(op, start, k)
        case .moveB_absL_absW: return run_moveB_absL_absW(op, start, k)
        case .moveB_absL_absL: return run_moveB_absL_absL(op, start, k)
        case .moveB_pcDisp_dn: return run_moveB_pcDisp_dn(op, start, k)
        case .moveB_pcDisp_ind: return run_moveB_pcDisp_ind(op, start, k)
        case .moveB_pcDisp_inc: return run_moveB_pcDisp_inc(op, start, k)
        case .moveB_pcDisp_dec: return run_moveB_pcDisp_dec(op, start, k)
        case .moveB_pcDisp_disp: return run_moveB_pcDisp_disp(op, start, k)
        case .moveB_pcDisp_index: return run_moveB_pcDisp_index(op, start, k)
        case .moveB_pcDisp_absW: return run_moveB_pcDisp_absW(op, start, k)
        case .moveB_pcDisp_absL: return run_moveB_pcDisp_absL(op, start, k)
        case .moveB_pcIndex_dn: return run_moveB_pcIndex_dn(op, start, k)
        case .moveB_pcIndex_ind: return run_moveB_pcIndex_ind(op, start, k)
        case .moveB_pcIndex_inc: return run_moveB_pcIndex_inc(op, start, k)
        case .moveB_pcIndex_dec: return run_moveB_pcIndex_dec(op, start, k)
        case .moveB_pcIndex_disp: return run_moveB_pcIndex_disp(op, start, k)
        case .moveB_pcIndex_index: return run_moveB_pcIndex_index(op, start, k)
        case .moveB_pcIndex_absW: return run_moveB_pcIndex_absW(op, start, k)
        case .moveB_pcIndex_absL: return run_moveB_pcIndex_absL(op, start, k)
        case .moveB_imm_dn: return run_moveB_imm_dn(op, start, k)
        case .moveB_imm_ind: return run_moveB_imm_ind(op, start, k)
        case .moveB_imm_inc: return run_moveB_imm_inc(op, start, k)
        case .moveB_imm_dec: return run_moveB_imm_dec(op, start, k)
        case .moveB_imm_disp: return run_moveB_imm_disp(op, start, k)
        case .moveB_imm_index: return run_moveB_imm_index(op, start, k)
        case .moveB_imm_absW: return run_moveB_imm_absW(op, start, k)
        case .moveB_imm_absL: return run_moveB_imm_absL(op, start, k)
        case .moveW_dn_dn: return run_moveW_dn_dn(op, start, k)
        case .moveW_dn_ind: return run_moveW_dn_ind(op, start, k)
        case .moveW_dn_inc: return run_moveW_dn_inc(op, start, k)
        case .moveW_dn_dec: return run_moveW_dn_dec(op, start, k)
        case .moveW_dn_disp: return run_moveW_dn_disp(op, start, k)
        case .moveW_dn_index: return run_moveW_dn_index(op, start, k)
        case .moveW_dn_absW: return run_moveW_dn_absW(op, start, k)
        case .moveW_dn_absL: return run_moveW_dn_absL(op, start, k)
        case .moveW_an_dn: return run_moveW_an_dn(op, start, k)
        case .moveW_an_ind: return run_moveW_an_ind(op, start, k)
        case .moveW_an_inc: return run_moveW_an_inc(op, start, k)
        case .moveW_an_dec: return run_moveW_an_dec(op, start, k)
        case .moveW_an_disp: return run_moveW_an_disp(op, start, k)
        case .moveW_an_index: return run_moveW_an_index(op, start, k)
        case .moveW_an_absW: return run_moveW_an_absW(op, start, k)
        case .moveW_an_absL: return run_moveW_an_absL(op, start, k)
        case .moveW_ind_dn: return run_moveW_ind_dn(op, start, k)
        case .moveW_ind_ind: return run_moveW_ind_ind(op, start, k)
        case .moveW_ind_inc: return run_moveW_ind_inc(op, start, k)
        case .moveW_ind_dec: return run_moveW_ind_dec(op, start, k)
        case .moveW_ind_disp: return run_moveW_ind_disp(op, start, k)
        case .moveW_ind_index: return run_moveW_ind_index(op, start, k)
        case .moveW_ind_absW: return run_moveW_ind_absW(op, start, k)
        case .moveW_ind_absL: return run_moveW_ind_absL(op, start, k)
        case .moveW_inc_dn: return run_moveW_inc_dn(op, start, k)
        case .moveW_inc_ind: return run_moveW_inc_ind(op, start, k)
        case .moveW_inc_inc: return run_moveW_inc_inc(op, start, k)
        case .moveW_inc_dec: return run_moveW_inc_dec(op, start, k)
        case .moveW_inc_disp: return run_moveW_inc_disp(op, start, k)
        case .moveW_inc_index: return run_moveW_inc_index(op, start, k)
        case .moveW_inc_absW: return run_moveW_inc_absW(op, start, k)
        case .moveW_inc_absL: return run_moveW_inc_absL(op, start, k)
        case .moveW_dec_dn: return run_moveW_dec_dn(op, start, k)
        case .moveW_dec_ind: return run_moveW_dec_ind(op, start, k)
        case .moveW_dec_inc: return run_moveW_dec_inc(op, start, k)
        case .moveW_dec_dec: return run_moveW_dec_dec(op, start, k)
        case .moveW_dec_disp: return run_moveW_dec_disp(op, start, k)
        case .moveW_dec_index: return run_moveW_dec_index(op, start, k)
        case .moveW_dec_absW: return run_moveW_dec_absW(op, start, k)
        case .moveW_dec_absL: return run_moveW_dec_absL(op, start, k)
        case .moveW_disp_dn: return run_moveW_disp_dn(op, start, k)
        case .moveW_disp_ind: return run_moveW_disp_ind(op, start, k)
        case .moveW_disp_inc: return run_moveW_disp_inc(op, start, k)
        case .moveW_disp_dec: return run_moveW_disp_dec(op, start, k)
        case .moveW_disp_disp: return run_moveW_disp_disp(op, start, k)
        case .moveW_disp_index: return run_moveW_disp_index(op, start, k)
        case .moveW_disp_absW: return run_moveW_disp_absW(op, start, k)
        case .moveW_disp_absL: return run_moveW_disp_absL(op, start, k)
        case .moveW_index_dn: return run_moveW_index_dn(op, start, k)
        case .moveW_index_ind: return run_moveW_index_ind(op, start, k)
        case .moveW_index_inc: return run_moveW_index_inc(op, start, k)
        case .moveW_index_dec: return run_moveW_index_dec(op, start, k)
        case .moveW_index_disp: return run_moveW_index_disp(op, start, k)
        case .moveW_index_index: return run_moveW_index_index(op, start, k)
        case .moveW_index_absW: return run_moveW_index_absW(op, start, k)
        case .moveW_index_absL: return run_moveW_index_absL(op, start, k)
        case .moveW_absW_dn: return run_moveW_absW_dn(op, start, k)
        case .moveW_absW_ind: return run_moveW_absW_ind(op, start, k)
        case .moveW_absW_inc: return run_moveW_absW_inc(op, start, k)
        case .moveW_absW_dec: return run_moveW_absW_dec(op, start, k)
        case .moveW_absW_disp: return run_moveW_absW_disp(op, start, k)
        case .moveW_absW_index: return run_moveW_absW_index(op, start, k)
        case .moveW_absW_absW: return run_moveW_absW_absW(op, start, k)
        case .moveW_absW_absL: return run_moveW_absW_absL(op, start, k)
        case .moveW_absL_dn: return run_moveW_absL_dn(op, start, k)
        case .moveW_absL_ind: return run_moveW_absL_ind(op, start, k)
        case .moveW_absL_inc: return run_moveW_absL_inc(op, start, k)
        case .moveW_absL_dec: return run_moveW_absL_dec(op, start, k)
        case .moveW_absL_disp: return run_moveW_absL_disp(op, start, k)
        case .moveW_absL_index: return run_moveW_absL_index(op, start, k)
        case .moveW_absL_absW: return run_moveW_absL_absW(op, start, k)
        case .moveW_absL_absL: return run_moveW_absL_absL(op, start, k)
        case .moveW_pcDisp_dn: return run_moveW_pcDisp_dn(op, start, k)
        case .moveW_pcDisp_ind: return run_moveW_pcDisp_ind(op, start, k)
        case .moveW_pcDisp_inc: return run_moveW_pcDisp_inc(op, start, k)
        case .moveW_pcDisp_dec: return run_moveW_pcDisp_dec(op, start, k)
        case .moveW_pcDisp_disp: return run_moveW_pcDisp_disp(op, start, k)
        case .moveW_pcDisp_index: return run_moveW_pcDisp_index(op, start, k)
        case .moveW_pcDisp_absW: return run_moveW_pcDisp_absW(op, start, k)
        case .moveW_pcDisp_absL: return run_moveW_pcDisp_absL(op, start, k)
        case .moveW_pcIndex_dn: return run_moveW_pcIndex_dn(op, start, k)
        case .moveW_pcIndex_ind: return run_moveW_pcIndex_ind(op, start, k)
        case .moveW_pcIndex_inc: return run_moveW_pcIndex_inc(op, start, k)
        case .moveW_pcIndex_dec: return run_moveW_pcIndex_dec(op, start, k)
        case .moveW_pcIndex_disp: return run_moveW_pcIndex_disp(op, start, k)
        case .moveW_pcIndex_index: return run_moveW_pcIndex_index(op, start, k)
        case .moveW_pcIndex_absW: return run_moveW_pcIndex_absW(op, start, k)
        case .moveW_pcIndex_absL: return run_moveW_pcIndex_absL(op, start, k)
        case .moveW_imm_dn: return run_moveW_imm_dn(op, start, k)
        case .moveW_imm_ind: return run_moveW_imm_ind(op, start, k)
        case .moveW_imm_inc: return run_moveW_imm_inc(op, start, k)
        case .moveW_imm_dec: return run_moveW_imm_dec(op, start, k)
        case .moveW_imm_disp: return run_moveW_imm_disp(op, start, k)
        case .moveW_imm_index: return run_moveW_imm_index(op, start, k)
        case .moveW_imm_absW: return run_moveW_imm_absW(op, start, k)
        case .moveW_imm_absL: return run_moveW_imm_absL(op, start, k)
        case .moveL_dn_dn: return run_moveL_dn_dn(op, start, k)
        case .moveL_dn_ind: return run_moveL_dn_ind(op, start, k)
        case .moveL_dn_inc: return run_moveL_dn_inc(op, start, k)
        case .moveL_dn_dec: return run_moveL_dn_dec(op, start, k)
        case .moveL_dn_disp: return run_moveL_dn_disp(op, start, k)
        case .moveL_dn_index: return run_moveL_dn_index(op, start, k)
        case .moveL_dn_absW: return run_moveL_dn_absW(op, start, k)
        case .moveL_dn_absL: return run_moveL_dn_absL(op, start, k)
        case .moveL_an_dn: return run_moveL_an_dn(op, start, k)
        case .moveL_an_ind: return run_moveL_an_ind(op, start, k)
        case .moveL_an_inc: return run_moveL_an_inc(op, start, k)
        case .moveL_an_dec: return run_moveL_an_dec(op, start, k)
        case .moveL_an_disp: return run_moveL_an_disp(op, start, k)
        case .moveL_an_index: return run_moveL_an_index(op, start, k)
        case .moveL_an_absW: return run_moveL_an_absW(op, start, k)
        case .moveL_an_absL: return run_moveL_an_absL(op, start, k)
        case .moveL_ind_dn: return run_moveL_ind_dn(op, start, k)
        case .moveL_ind_ind: return run_moveL_ind_ind(op, start, k)
        case .moveL_ind_inc: return run_moveL_ind_inc(op, start, k)
        case .moveL_ind_dec: return run_moveL_ind_dec(op, start, k)
        case .moveL_ind_disp: return run_moveL_ind_disp(op, start, k)
        case .moveL_ind_index: return run_moveL_ind_index(op, start, k)
        case .moveL_ind_absW: return run_moveL_ind_absW(op, start, k)
        case .moveL_ind_absL: return run_moveL_ind_absL(op, start, k)
        case .moveL_inc_dn: return run_moveL_inc_dn(op, start, k)
        case .moveL_inc_ind: return run_moveL_inc_ind(op, start, k)
        case .moveL_inc_inc: return run_moveL_inc_inc(op, start, k)
        case .moveL_inc_dec: return run_moveL_inc_dec(op, start, k)
        case .moveL_inc_disp: return run_moveL_inc_disp(op, start, k)
        case .moveL_inc_index: return run_moveL_inc_index(op, start, k)
        case .moveL_inc_absW: return run_moveL_inc_absW(op, start, k)
        case .moveL_inc_absL: return run_moveL_inc_absL(op, start, k)
        case .moveL_dec_dn: return run_moveL_dec_dn(op, start, k)
        case .moveL_dec_ind: return run_moveL_dec_ind(op, start, k)
        case .moveL_dec_inc: return run_moveL_dec_inc(op, start, k)
        case .moveL_dec_dec: return run_moveL_dec_dec(op, start, k)
        case .moveL_dec_disp: return run_moveL_dec_disp(op, start, k)
        case .moveL_dec_index: return run_moveL_dec_index(op, start, k)
        case .moveL_dec_absW: return run_moveL_dec_absW(op, start, k)
        case .moveL_dec_absL: return run_moveL_dec_absL(op, start, k)
        case .moveL_disp_dn: return run_moveL_disp_dn(op, start, k)
        case .moveL_disp_ind: return run_moveL_disp_ind(op, start, k)
        case .moveL_disp_inc: return run_moveL_disp_inc(op, start, k)
        case .moveL_disp_dec: return run_moveL_disp_dec(op, start, k)
        case .moveL_disp_disp: return run_moveL_disp_disp(op, start, k)
        case .moveL_disp_index: return run_moveL_disp_index(op, start, k)
        case .moveL_disp_absW: return run_moveL_disp_absW(op, start, k)
        case .moveL_disp_absL: return run_moveL_disp_absL(op, start, k)
        case .moveL_index_dn: return run_moveL_index_dn(op, start, k)
        case .moveL_index_ind: return run_moveL_index_ind(op, start, k)
        case .moveL_index_inc: return run_moveL_index_inc(op, start, k)
        case .moveL_index_dec: return run_moveL_index_dec(op, start, k)
        case .moveL_index_disp: return run_moveL_index_disp(op, start, k)
        case .moveL_index_index: return run_moveL_index_index(op, start, k)
        case .moveL_index_absW: return run_moveL_index_absW(op, start, k)
        case .moveL_index_absL: return run_moveL_index_absL(op, start, k)
        case .moveL_absW_dn: return run_moveL_absW_dn(op, start, k)
        case .moveL_absW_ind: return run_moveL_absW_ind(op, start, k)
        case .moveL_absW_inc: return run_moveL_absW_inc(op, start, k)
        case .moveL_absW_dec: return run_moveL_absW_dec(op, start, k)
        case .moveL_absW_disp: return run_moveL_absW_disp(op, start, k)
        case .moveL_absW_index: return run_moveL_absW_index(op, start, k)
        case .moveL_absW_absW: return run_moveL_absW_absW(op, start, k)
        case .moveL_absW_absL: return run_moveL_absW_absL(op, start, k)
        case .moveL_absL_dn: return run_moveL_absL_dn(op, start, k)
        case .moveL_absL_ind: return run_moveL_absL_ind(op, start, k)
        case .moveL_absL_inc: return run_moveL_absL_inc(op, start, k)
        case .moveL_absL_dec: return run_moveL_absL_dec(op, start, k)
        case .moveL_absL_disp: return run_moveL_absL_disp(op, start, k)
        case .moveL_absL_index: return run_moveL_absL_index(op, start, k)
        case .moveL_absL_absW: return run_moveL_absL_absW(op, start, k)
        case .moveL_absL_absL: return run_moveL_absL_absL(op, start, k)
        case .moveL_pcDisp_dn: return run_moveL_pcDisp_dn(op, start, k)
        case .moveL_pcDisp_ind: return run_moveL_pcDisp_ind(op, start, k)
        case .moveL_pcDisp_inc: return run_moveL_pcDisp_inc(op, start, k)
        case .moveL_pcDisp_dec: return run_moveL_pcDisp_dec(op, start, k)
        case .moveL_pcDisp_disp: return run_moveL_pcDisp_disp(op, start, k)
        case .moveL_pcDisp_index: return run_moveL_pcDisp_index(op, start, k)
        case .moveL_pcDisp_absW: return run_moveL_pcDisp_absW(op, start, k)
        case .moveL_pcDisp_absL: return run_moveL_pcDisp_absL(op, start, k)
        case .moveL_pcIndex_dn: return run_moveL_pcIndex_dn(op, start, k)
        case .moveL_pcIndex_ind: return run_moveL_pcIndex_ind(op, start, k)
        case .moveL_pcIndex_inc: return run_moveL_pcIndex_inc(op, start, k)
        case .moveL_pcIndex_dec: return run_moveL_pcIndex_dec(op, start, k)
        case .moveL_pcIndex_disp: return run_moveL_pcIndex_disp(op, start, k)
        case .moveL_pcIndex_index: return run_moveL_pcIndex_index(op, start, k)
        case .moveL_pcIndex_absW: return run_moveL_pcIndex_absW(op, start, k)
        case .moveL_pcIndex_absL: return run_moveL_pcIndex_absL(op, start, k)
        case .moveL_imm_dn: return run_moveL_imm_dn(op, start, k)
        case .moveL_imm_ind: return run_moveL_imm_ind(op, start, k)
        case .moveL_imm_inc: return run_moveL_imm_inc(op, start, k)
        case .moveL_imm_dec: return run_moveL_imm_dec(op, start, k)
        case .moveL_imm_disp: return run_moveL_imm_disp(op, start, k)
        case .moveL_imm_index: return run_moveL_imm_index(op, start, k)
        case .moveL_imm_absW: return run_moveL_imm_absW(op, start, k)
        case .moveL_imm_absL: return run_moveL_imm_absL(op, start, k)
        case .moveaW_dn: return run_moveaW_dn(op, start, k)
        case .moveaW_an: return run_moveaW_an(op, start, k)
        case .moveaW_ind: return run_moveaW_ind(op, start, k)
        case .moveaW_inc: return run_moveaW_inc(op, start, k)
        case .moveaW_dec: return run_moveaW_dec(op, start, k)
        case .moveaW_disp: return run_moveaW_disp(op, start, k)
        case .moveaW_index: return run_moveaW_index(op, start, k)
        case .moveaW_absW: return run_moveaW_absW(op, start, k)
        case .moveaW_absL: return run_moveaW_absL(op, start, k)
        case .moveaW_pcDisp: return run_moveaW_pcDisp(op, start, k)
        case .moveaW_pcIndex: return run_moveaW_pcIndex(op, start, k)
        case .moveaW_imm: return run_moveaW_imm(op, start, k)
        case .moveaL_dn: return run_moveaL_dn(op, start, k)
        case .moveaL_an: return run_moveaL_an(op, start, k)
        case .moveaL_ind: return run_moveaL_ind(op, start, k)
        case .moveaL_inc: return run_moveaL_inc(op, start, k)
        case .moveaL_dec: return run_moveaL_dec(op, start, k)
        case .moveaL_disp: return run_moveaL_disp(op, start, k)
        case .moveaL_index: return run_moveaL_index(op, start, k)
        case .moveaL_absW: return run_moveaL_absW(op, start, k)
        case .moveaL_absL: return run_moveaL_absL(op, start, k)
        case .moveaL_pcDisp: return run_moveaL_pcDisp(op, start, k)
        case .moveaL_pcIndex: return run_moveaL_pcIndex(op, start, k)
        case .moveaL_imm: return run_moveaL_imm(op, start, k)
        case .lea_ind: return run_lea_ind(op, start, k)
        case .lea_disp: return run_lea_disp(op, start, k)
        case .lea_index: return run_lea_index(op, start, k)
        case .lea_absW: return run_lea_absW(op, start, k)
        case .lea_absL: return run_lea_absL(op, start, k)
        case .lea_pcDisp: return run_lea_pcDisp(op, start, k)
        case .lea_pcIndex: return run_lea_pcIndex(op, start, k)
        case .pea_ind: return run_pea_ind(op, start, k)
        case .pea_disp: return run_pea_disp(op, start, k)
        case .pea_index: return run_pea_index(op, start, k)
        case .pea_absW: return run_pea_absW(op, start, k)
        case .pea_absL: return run_pea_absL(op, start, k)
        case .pea_pcDisp: return run_pea_pcDisp(op, start, k)
        case .pea_pcIndex: return run_pea_pcIndex(op, start, k)
        case .jsr_ind: return run_jsr_ind(op, start, k)
        case .jsr_disp: return run_jsr_disp(op, start, k)
        case .jsr_index: return run_jsr_index(op, start, k)
        case .jsr_absW: return run_jsr_absW(op, start, k)
        case .jsr_absL: return run_jsr_absL(op, start, k)
        case .jsr_pcDisp: return run_jsr_pcDisp(op, start, k)
        case .jsr_pcIndex: return run_jsr_pcIndex(op, start, k)
        case .jmp_ind: return run_jmp_ind(op, start, k)
        case .jmp_disp: return run_jmp_disp(op, start, k)
        case .jmp_index: return run_jmp_index(op, start, k)
        case .jmp_absW: return run_jmp_absW(op, start, k)
        case .jmp_absL: return run_jmp_absL(op, start, k)
        case .jmp_pcDisp: return run_jmp_pcDisp(op, start, k)
        case .jmp_pcIndex: return run_jmp_pcIndex(op, start, k)
        case .clrB_dn: return run_clrB_dn(op, start, k)
        case .clrB_ind: return run_clrB_ind(op, start, k)
        case .clrB_inc: return run_clrB_inc(op, start, k)
        case .clrB_dec: return run_clrB_dec(op, start, k)
        case .clrB_disp: return run_clrB_disp(op, start, k)
        case .clrB_index: return run_clrB_index(op, start, k)
        case .clrB_absW: return run_clrB_absW(op, start, k)
        case .clrB_absL: return run_clrB_absL(op, start, k)
        case .tstB_dn: return run_tstB_dn(op, start, k)
        case .tstB_ind: return run_tstB_ind(op, start, k)
        case .tstB_inc: return run_tstB_inc(op, start, k)
        case .tstB_dec: return run_tstB_dec(op, start, k)
        case .tstB_disp: return run_tstB_disp(op, start, k)
        case .tstB_index: return run_tstB_index(op, start, k)
        case .tstB_absW: return run_tstB_absW(op, start, k)
        case .tstB_absL: return run_tstB_absL(op, start, k)
        case .clrW_dn: return run_clrW_dn(op, start, k)
        case .clrW_ind: return run_clrW_ind(op, start, k)
        case .clrW_inc: return run_clrW_inc(op, start, k)
        case .clrW_dec: return run_clrW_dec(op, start, k)
        case .clrW_disp: return run_clrW_disp(op, start, k)
        case .clrW_index: return run_clrW_index(op, start, k)
        case .clrW_absW: return run_clrW_absW(op, start, k)
        case .clrW_absL: return run_clrW_absL(op, start, k)
        case .tstW_dn: return run_tstW_dn(op, start, k)
        case .tstW_ind: return run_tstW_ind(op, start, k)
        case .tstW_inc: return run_tstW_inc(op, start, k)
        case .tstW_dec: return run_tstW_dec(op, start, k)
        case .tstW_disp: return run_tstW_disp(op, start, k)
        case .tstW_index: return run_tstW_index(op, start, k)
        case .tstW_absW: return run_tstW_absW(op, start, k)
        case .tstW_absL: return run_tstW_absL(op, start, k)
        case .clrL_dn: return run_clrL_dn(op, start, k)
        case .clrL_ind: return run_clrL_ind(op, start, k)
        case .clrL_inc: return run_clrL_inc(op, start, k)
        case .clrL_dec: return run_clrL_dec(op, start, k)
        case .clrL_disp: return run_clrL_disp(op, start, k)
        case .clrL_index: return run_clrL_index(op, start, k)
        case .clrL_absW: return run_clrL_absW(op, start, k)
        case .clrL_absL: return run_clrL_absL(op, start, k)
        case .tstL_dn: return run_tstL_dn(op, start, k)
        case .tstL_ind: return run_tstL_ind(op, start, k)
        case .tstL_inc: return run_tstL_inc(op, start, k)
        case .tstL_dec: return run_tstL_dec(op, start, k)
        case .tstL_disp: return run_tstL_disp(op, start, k)
        case .tstL_index: return run_tstL_index(op, start, k)
        case .tstL_absW: return run_tstL_absW(op, start, k)
        case .tstL_absL: return run_tstL_absL(op, start, k)
        case .dbcc_t: return run_dbcc_t(op, start, k)
        case .dbcc_hi: return run_dbcc_hi(op, start, k)
        case .dbcc_ls: return run_dbcc_ls(op, start, k)
        case .dbcc_cc: return run_dbcc_cc(op, start, k)
        case .dbcc_cs: return run_dbcc_cs(op, start, k)
        case .dbcc_ne: return run_dbcc_ne(op, start, k)
        case .dbcc_eq: return run_dbcc_eq(op, start, k)
        case .dbcc_vc: return run_dbcc_vc(op, start, k)
        case .dbcc_vs: return run_dbcc_vs(op, start, k)
        case .dbcc_pl: return run_dbcc_pl(op, start, k)
        case .dbcc_mi: return run_dbcc_mi(op, start, k)
        case .dbcc_ge: return run_dbcc_ge(op, start, k)
        case .dbcc_lt: return run_dbcc_lt(op, start, k)
        case .dbcc_gt: return run_dbcc_gt(op, start, k)
        case .dbcc_le: return run_dbcc_le(op, start, k)
        case .addqB_dn: return run_addqB_dn(op, start, k)
        case .addqB_ind: return run_addqB_ind(op, start, k)
        case .addqB_inc: return run_addqB_inc(op, start, k)
        case .addqB_dec: return run_addqB_dec(op, start, k)
        case .addqB_disp: return run_addqB_disp(op, start, k)
        case .addqB_index: return run_addqB_index(op, start, k)
        case .addqB_absW: return run_addqB_absW(op, start, k)
        case .addqB_absL: return run_addqB_absL(op, start, k)
        case .subqB_dn: return run_subqB_dn(op, start, k)
        case .subqB_ind: return run_subqB_ind(op, start, k)
        case .subqB_inc: return run_subqB_inc(op, start, k)
        case .subqB_dec: return run_subqB_dec(op, start, k)
        case .subqB_disp: return run_subqB_disp(op, start, k)
        case .subqB_index: return run_subqB_index(op, start, k)
        case .subqB_absW: return run_subqB_absW(op, start, k)
        case .subqB_absL: return run_subqB_absL(op, start, k)
        case .addqW_dn: return run_addqW_dn(op, start, k)
        case .addqW_ind: return run_addqW_ind(op, start, k)
        case .addqW_inc: return run_addqW_inc(op, start, k)
        case .addqW_dec: return run_addqW_dec(op, start, k)
        case .addqW_disp: return run_addqW_disp(op, start, k)
        case .addqW_index: return run_addqW_index(op, start, k)
        case .addqW_absW: return run_addqW_absW(op, start, k)
        case .addqW_absL: return run_addqW_absL(op, start, k)
        case .subqW_dn: return run_subqW_dn(op, start, k)
        case .subqW_ind: return run_subqW_ind(op, start, k)
        case .subqW_inc: return run_subqW_inc(op, start, k)
        case .subqW_dec: return run_subqW_dec(op, start, k)
        case .subqW_disp: return run_subqW_disp(op, start, k)
        case .subqW_index: return run_subqW_index(op, start, k)
        case .subqW_absW: return run_subqW_absW(op, start, k)
        case .subqW_absL: return run_subqW_absL(op, start, k)
        case .addqL_dn: return run_addqL_dn(op, start, k)
        case .addqL_ind: return run_addqL_ind(op, start, k)
        case .addqL_inc: return run_addqL_inc(op, start, k)
        case .addqL_dec: return run_addqL_dec(op, start, k)
        case .addqL_disp: return run_addqL_disp(op, start, k)
        case .addqL_index: return run_addqL_index(op, start, k)
        case .addqL_absW: return run_addqL_absW(op, start, k)
        case .addqL_absL: return run_addqL_absL(op, start, k)
        case .subqL_dn: return run_subqL_dn(op, start, k)
        case .subqL_ind: return run_subqL_ind(op, start, k)
        case .subqL_inc: return run_subqL_inc(op, start, k)
        case .subqL_dec: return run_subqL_dec(op, start, k)
        case .subqL_disp: return run_subqL_disp(op, start, k)
        case .subqL_index: return run_subqL_index(op, start, k)
        case .subqL_absW: return run_subqL_absW(op, start, k)
        case .subqL_absL: return run_subqL_absL(op, start, k)
        case .orB_dn: return run_orB_dn(op, start, k)
        case .orB_ind: return run_orB_ind(op, start, k)
        case .orB_inc: return run_orB_inc(op, start, k)
        case .orB_dec: return run_orB_dec(op, start, k)
        case .orB_disp: return run_orB_disp(op, start, k)
        case .orB_index: return run_orB_index(op, start, k)
        case .orB_absW: return run_orB_absW(op, start, k)
        case .orB_absL: return run_orB_absL(op, start, k)
        case .orB_pcDisp: return run_orB_pcDisp(op, start, k)
        case .orB_pcIndex: return run_orB_pcIndex(op, start, k)
        case .orB_imm: return run_orB_imm(op, start, k)
        case .orEaB_ind: return run_orEaB_ind(op, start, k)
        case .orEaB_inc: return run_orEaB_inc(op, start, k)
        case .orEaB_dec: return run_orEaB_dec(op, start, k)
        case .orEaB_disp: return run_orEaB_disp(op, start, k)
        case .orEaB_index: return run_orEaB_index(op, start, k)
        case .orEaB_absW: return run_orEaB_absW(op, start, k)
        case .orEaB_absL: return run_orEaB_absL(op, start, k)
        case .orW_dn: return run_orW_dn(op, start, k)
        case .orW_ind: return run_orW_ind(op, start, k)
        case .orW_inc: return run_orW_inc(op, start, k)
        case .orW_dec: return run_orW_dec(op, start, k)
        case .orW_disp: return run_orW_disp(op, start, k)
        case .orW_index: return run_orW_index(op, start, k)
        case .orW_absW: return run_orW_absW(op, start, k)
        case .orW_absL: return run_orW_absL(op, start, k)
        case .orW_pcDisp: return run_orW_pcDisp(op, start, k)
        case .orW_pcIndex: return run_orW_pcIndex(op, start, k)
        case .orW_imm: return run_orW_imm(op, start, k)
        case .orEaW_ind: return run_orEaW_ind(op, start, k)
        case .orEaW_inc: return run_orEaW_inc(op, start, k)
        case .orEaW_dec: return run_orEaW_dec(op, start, k)
        case .orEaW_disp: return run_orEaW_disp(op, start, k)
        case .orEaW_index: return run_orEaW_index(op, start, k)
        case .orEaW_absW: return run_orEaW_absW(op, start, k)
        case .orEaW_absL: return run_orEaW_absL(op, start, k)
        case .orL_dn: return run_orL_dn(op, start, k)
        case .orL_ind: return run_orL_ind(op, start, k)
        case .orL_inc: return run_orL_inc(op, start, k)
        case .orL_dec: return run_orL_dec(op, start, k)
        case .orL_disp: return run_orL_disp(op, start, k)
        case .orL_index: return run_orL_index(op, start, k)
        case .orL_absW: return run_orL_absW(op, start, k)
        case .orL_absL: return run_orL_absL(op, start, k)
        case .orL_pcDisp: return run_orL_pcDisp(op, start, k)
        case .orL_pcIndex: return run_orL_pcIndex(op, start, k)
        case .orL_imm: return run_orL_imm(op, start, k)
        case .orEaL_ind: return run_orEaL_ind(op, start, k)
        case .orEaL_inc: return run_orEaL_inc(op, start, k)
        case .orEaL_dec: return run_orEaL_dec(op, start, k)
        case .orEaL_disp: return run_orEaL_disp(op, start, k)
        case .orEaL_index: return run_orEaL_index(op, start, k)
        case .orEaL_absW: return run_orEaL_absW(op, start, k)
        case .orEaL_absL: return run_orEaL_absL(op, start, k)
        case .andB_dn: return run_andB_dn(op, start, k)
        case .andB_ind: return run_andB_ind(op, start, k)
        case .andB_inc: return run_andB_inc(op, start, k)
        case .andB_dec: return run_andB_dec(op, start, k)
        case .andB_disp: return run_andB_disp(op, start, k)
        case .andB_index: return run_andB_index(op, start, k)
        case .andB_absW: return run_andB_absW(op, start, k)
        case .andB_absL: return run_andB_absL(op, start, k)
        case .andB_pcDisp: return run_andB_pcDisp(op, start, k)
        case .andB_pcIndex: return run_andB_pcIndex(op, start, k)
        case .andB_imm: return run_andB_imm(op, start, k)
        case .andEaB_ind: return run_andEaB_ind(op, start, k)
        case .andEaB_inc: return run_andEaB_inc(op, start, k)
        case .andEaB_dec: return run_andEaB_dec(op, start, k)
        case .andEaB_disp: return run_andEaB_disp(op, start, k)
        case .andEaB_index: return run_andEaB_index(op, start, k)
        case .andEaB_absW: return run_andEaB_absW(op, start, k)
        case .andEaB_absL: return run_andEaB_absL(op, start, k)
        case .andW_dn: return run_andW_dn(op, start, k)
        case .andW_ind: return run_andW_ind(op, start, k)
        case .andW_inc: return run_andW_inc(op, start, k)
        case .andW_dec: return run_andW_dec(op, start, k)
        case .andW_disp: return run_andW_disp(op, start, k)
        case .andW_index: return run_andW_index(op, start, k)
        case .andW_absW: return run_andW_absW(op, start, k)
        case .andW_absL: return run_andW_absL(op, start, k)
        case .andW_pcDisp: return run_andW_pcDisp(op, start, k)
        case .andW_pcIndex: return run_andW_pcIndex(op, start, k)
        case .andW_imm: return run_andW_imm(op, start, k)
        case .andEaW_ind: return run_andEaW_ind(op, start, k)
        case .andEaW_inc: return run_andEaW_inc(op, start, k)
        case .andEaW_dec: return run_andEaW_dec(op, start, k)
        case .andEaW_disp: return run_andEaW_disp(op, start, k)
        case .andEaW_index: return run_andEaW_index(op, start, k)
        case .andEaW_absW: return run_andEaW_absW(op, start, k)
        case .andEaW_absL: return run_andEaW_absL(op, start, k)
        case .andL_dn: return run_andL_dn(op, start, k)
        case .andL_ind: return run_andL_ind(op, start, k)
        case .andL_inc: return run_andL_inc(op, start, k)
        case .andL_dec: return run_andL_dec(op, start, k)
        case .andL_disp: return run_andL_disp(op, start, k)
        case .andL_index: return run_andL_index(op, start, k)
        case .andL_absW: return run_andL_absW(op, start, k)
        case .andL_absL: return run_andL_absL(op, start, k)
        case .andL_pcDisp: return run_andL_pcDisp(op, start, k)
        case .andL_pcIndex: return run_andL_pcIndex(op, start, k)
        case .andL_imm: return run_andL_imm(op, start, k)
        case .andEaL_ind: return run_andEaL_ind(op, start, k)
        case .andEaL_inc: return run_andEaL_inc(op, start, k)
        case .andEaL_dec: return run_andEaL_dec(op, start, k)
        case .andEaL_disp: return run_andEaL_disp(op, start, k)
        case .andEaL_index: return run_andEaL_index(op, start, k)
        case .andEaL_absW: return run_andEaL_absW(op, start, k)
        case .andEaL_absL: return run_andEaL_absL(op, start, k)
        case .addB_dn: return run_addB_dn(op, start, k)
        case .addB_ind: return run_addB_ind(op, start, k)
        case .addB_inc: return run_addB_inc(op, start, k)
        case .addB_dec: return run_addB_dec(op, start, k)
        case .addB_disp: return run_addB_disp(op, start, k)
        case .addB_index: return run_addB_index(op, start, k)
        case .addB_absW: return run_addB_absW(op, start, k)
        case .addB_absL: return run_addB_absL(op, start, k)
        case .addB_pcDisp: return run_addB_pcDisp(op, start, k)
        case .addB_pcIndex: return run_addB_pcIndex(op, start, k)
        case .addB_imm: return run_addB_imm(op, start, k)
        case .addEaB_ind: return run_addEaB_ind(op, start, k)
        case .addEaB_inc: return run_addEaB_inc(op, start, k)
        case .addEaB_dec: return run_addEaB_dec(op, start, k)
        case .addEaB_disp: return run_addEaB_disp(op, start, k)
        case .addEaB_index: return run_addEaB_index(op, start, k)
        case .addEaB_absW: return run_addEaB_absW(op, start, k)
        case .addEaB_absL: return run_addEaB_absL(op, start, k)
        case .addW_dn: return run_addW_dn(op, start, k)
        case .addW_an: return run_addW_an(op, start, k)
        case .addW_ind: return run_addW_ind(op, start, k)
        case .addW_inc: return run_addW_inc(op, start, k)
        case .addW_dec: return run_addW_dec(op, start, k)
        case .addW_disp: return run_addW_disp(op, start, k)
        case .addW_index: return run_addW_index(op, start, k)
        case .addW_absW: return run_addW_absW(op, start, k)
        case .addW_absL: return run_addW_absL(op, start, k)
        case .addW_pcDisp: return run_addW_pcDisp(op, start, k)
        case .addW_pcIndex: return run_addW_pcIndex(op, start, k)
        case .addW_imm: return run_addW_imm(op, start, k)
        case .addEaW_ind: return run_addEaW_ind(op, start, k)
        case .addEaW_inc: return run_addEaW_inc(op, start, k)
        case .addEaW_dec: return run_addEaW_dec(op, start, k)
        case .addEaW_disp: return run_addEaW_disp(op, start, k)
        case .addEaW_index: return run_addEaW_index(op, start, k)
        case .addEaW_absW: return run_addEaW_absW(op, start, k)
        case .addEaW_absL: return run_addEaW_absL(op, start, k)
        case .addL_dn: return run_addL_dn(op, start, k)
        case .addL_an: return run_addL_an(op, start, k)
        case .addL_ind: return run_addL_ind(op, start, k)
        case .addL_inc: return run_addL_inc(op, start, k)
        case .addL_dec: return run_addL_dec(op, start, k)
        case .addL_disp: return run_addL_disp(op, start, k)
        case .addL_index: return run_addL_index(op, start, k)
        case .addL_absW: return run_addL_absW(op, start, k)
        case .addL_absL: return run_addL_absL(op, start, k)
        case .addL_pcDisp: return run_addL_pcDisp(op, start, k)
        case .addL_pcIndex: return run_addL_pcIndex(op, start, k)
        case .addL_imm: return run_addL_imm(op, start, k)
        case .addEaL_ind: return run_addEaL_ind(op, start, k)
        case .addEaL_inc: return run_addEaL_inc(op, start, k)
        case .addEaL_dec: return run_addEaL_dec(op, start, k)
        case .addEaL_disp: return run_addEaL_disp(op, start, k)
        case .addEaL_index: return run_addEaL_index(op, start, k)
        case .addEaL_absW: return run_addEaL_absW(op, start, k)
        case .addEaL_absL: return run_addEaL_absL(op, start, k)
        case .subB_dn: return run_subB_dn(op, start, k)
        case .subB_ind: return run_subB_ind(op, start, k)
        case .subB_inc: return run_subB_inc(op, start, k)
        case .subB_dec: return run_subB_dec(op, start, k)
        case .subB_disp: return run_subB_disp(op, start, k)
        case .subB_index: return run_subB_index(op, start, k)
        case .subB_absW: return run_subB_absW(op, start, k)
        case .subB_absL: return run_subB_absL(op, start, k)
        case .subB_pcDisp: return run_subB_pcDisp(op, start, k)
        case .subB_pcIndex: return run_subB_pcIndex(op, start, k)
        case .subB_imm: return run_subB_imm(op, start, k)
        case .subEaB_ind: return run_subEaB_ind(op, start, k)
        case .subEaB_inc: return run_subEaB_inc(op, start, k)
        case .subEaB_dec: return run_subEaB_dec(op, start, k)
        case .subEaB_disp: return run_subEaB_disp(op, start, k)
        case .subEaB_index: return run_subEaB_index(op, start, k)
        case .subEaB_absW: return run_subEaB_absW(op, start, k)
        case .subEaB_absL: return run_subEaB_absL(op, start, k)
        case .subW_dn: return run_subW_dn(op, start, k)
        case .subW_an: return run_subW_an(op, start, k)
        case .subW_ind: return run_subW_ind(op, start, k)
        case .subW_inc: return run_subW_inc(op, start, k)
        case .subW_dec: return run_subW_dec(op, start, k)
        case .subW_disp: return run_subW_disp(op, start, k)
        case .subW_index: return run_subW_index(op, start, k)
        case .subW_absW: return run_subW_absW(op, start, k)
        case .subW_absL: return run_subW_absL(op, start, k)
        case .subW_pcDisp: return run_subW_pcDisp(op, start, k)
        case .subW_pcIndex: return run_subW_pcIndex(op, start, k)
        case .subW_imm: return run_subW_imm(op, start, k)
        case .subEaW_ind: return run_subEaW_ind(op, start, k)
        case .subEaW_inc: return run_subEaW_inc(op, start, k)
        case .subEaW_dec: return run_subEaW_dec(op, start, k)
        case .subEaW_disp: return run_subEaW_disp(op, start, k)
        case .subEaW_index: return run_subEaW_index(op, start, k)
        case .subEaW_absW: return run_subEaW_absW(op, start, k)
        case .subEaW_absL: return run_subEaW_absL(op, start, k)
        case .subL_dn: return run_subL_dn(op, start, k)
        case .subL_an: return run_subL_an(op, start, k)
        case .subL_ind: return run_subL_ind(op, start, k)
        case .subL_inc: return run_subL_inc(op, start, k)
        case .subL_dec: return run_subL_dec(op, start, k)
        case .subL_disp: return run_subL_disp(op, start, k)
        case .subL_index: return run_subL_index(op, start, k)
        case .subL_absW: return run_subL_absW(op, start, k)
        case .subL_absL: return run_subL_absL(op, start, k)
        case .subL_pcDisp: return run_subL_pcDisp(op, start, k)
        case .subL_pcIndex: return run_subL_pcIndex(op, start, k)
        case .subL_imm: return run_subL_imm(op, start, k)
        case .subEaL_ind: return run_subEaL_ind(op, start, k)
        case .subEaL_inc: return run_subEaL_inc(op, start, k)
        case .subEaL_dec: return run_subEaL_dec(op, start, k)
        case .subEaL_disp: return run_subEaL_disp(op, start, k)
        case .subEaL_index: return run_subEaL_index(op, start, k)
        case .subEaL_absW: return run_subEaL_absW(op, start, k)
        case .subEaL_absL: return run_subEaL_absL(op, start, k)
        case .addxB_registers: return run_addxB_registers(op, start, k)
        case .addxB_memory: return run_addxB_memory(op, start, k)
        case .subxB_registers: return run_subxB_registers(op, start, k)
        case .subxB_memory: return run_subxB_memory(op, start, k)
        case .addxW_registers: return run_addxW_registers(op, start, k)
        case .addxW_memory: return run_addxW_memory(op, start, k)
        case .subxW_registers: return run_subxW_registers(op, start, k)
        case .subxW_memory: return run_subxW_memory(op, start, k)
        case .addxL_registers: return run_addxL_registers(op, start, k)
        case .addxL_memory: return run_addxL_memory(op, start, k)
        case .subxL_registers: return run_subxL_registers(op, start, k)
        case .subxL_memory: return run_subxL_memory(op, start, k)
        case .eorB_dn: return run_eorB_dn(op, start, k)
        case .eorB_ind: return run_eorB_ind(op, start, k)
        case .eorB_inc: return run_eorB_inc(op, start, k)
        case .eorB_dec: return run_eorB_dec(op, start, k)
        case .eorB_disp: return run_eorB_disp(op, start, k)
        case .eorB_index: return run_eorB_index(op, start, k)
        case .eorB_absW: return run_eorB_absW(op, start, k)
        case .eorB_absL: return run_eorB_absL(op, start, k)
        case .cmpB_dn: return run_cmpB_dn(op, start, k)
        case .cmpB_ind: return run_cmpB_ind(op, start, k)
        case .cmpB_inc: return run_cmpB_inc(op, start, k)
        case .cmpB_dec: return run_cmpB_dec(op, start, k)
        case .cmpB_disp: return run_cmpB_disp(op, start, k)
        case .cmpB_index: return run_cmpB_index(op, start, k)
        case .cmpB_absW: return run_cmpB_absW(op, start, k)
        case .cmpB_absL: return run_cmpB_absL(op, start, k)
        case .cmpB_pcDisp: return run_cmpB_pcDisp(op, start, k)
        case .cmpB_pcIndex: return run_cmpB_pcIndex(op, start, k)
        case .cmpB_imm: return run_cmpB_imm(op, start, k)
        case .eorW_dn: return run_eorW_dn(op, start, k)
        case .eorW_ind: return run_eorW_ind(op, start, k)
        case .eorW_inc: return run_eorW_inc(op, start, k)
        case .eorW_dec: return run_eorW_dec(op, start, k)
        case .eorW_disp: return run_eorW_disp(op, start, k)
        case .eorW_index: return run_eorW_index(op, start, k)
        case .eorW_absW: return run_eorW_absW(op, start, k)
        case .eorW_absL: return run_eorW_absL(op, start, k)
        case .cmpW_dn: return run_cmpW_dn(op, start, k)
        case .cmpW_an: return run_cmpW_an(op, start, k)
        case .cmpW_ind: return run_cmpW_ind(op, start, k)
        case .cmpW_inc: return run_cmpW_inc(op, start, k)
        case .cmpW_dec: return run_cmpW_dec(op, start, k)
        case .cmpW_disp: return run_cmpW_disp(op, start, k)
        case .cmpW_index: return run_cmpW_index(op, start, k)
        case .cmpW_absW: return run_cmpW_absW(op, start, k)
        case .cmpW_absL: return run_cmpW_absL(op, start, k)
        case .cmpW_pcDisp: return run_cmpW_pcDisp(op, start, k)
        case .cmpW_pcIndex: return run_cmpW_pcIndex(op, start, k)
        case .cmpW_imm: return run_cmpW_imm(op, start, k)
        case .eorL_dn: return run_eorL_dn(op, start, k)
        case .eorL_ind: return run_eorL_ind(op, start, k)
        case .eorL_inc: return run_eorL_inc(op, start, k)
        case .eorL_dec: return run_eorL_dec(op, start, k)
        case .eorL_disp: return run_eorL_disp(op, start, k)
        case .eorL_index: return run_eorL_index(op, start, k)
        case .eorL_absW: return run_eorL_absW(op, start, k)
        case .eorL_absL: return run_eorL_absL(op, start, k)
        case .cmpL_dn: return run_cmpL_dn(op, start, k)
        case .cmpL_an: return run_cmpL_an(op, start, k)
        case .cmpL_ind: return run_cmpL_ind(op, start, k)
        case .cmpL_inc: return run_cmpL_inc(op, start, k)
        case .cmpL_dec: return run_cmpL_dec(op, start, k)
        case .cmpL_disp: return run_cmpL_disp(op, start, k)
        case .cmpL_index: return run_cmpL_index(op, start, k)
        case .cmpL_absW: return run_cmpL_absW(op, start, k)
        case .cmpL_absL: return run_cmpL_absL(op, start, k)
        case .cmpL_pcDisp: return run_cmpL_pcDisp(op, start, k)
        case .cmpL_pcIndex: return run_cmpL_pcIndex(op, start, k)
        case .cmpL_imm: return run_cmpL_imm(op, start, k)
        case .cmpaW_dn: return run_cmpaW_dn(op, start, k)
        case .cmpaW_an: return run_cmpaW_an(op, start, k)
        case .cmpaW_ind: return run_cmpaW_ind(op, start, k)
        case .cmpaW_inc: return run_cmpaW_inc(op, start, k)
        case .cmpaW_dec: return run_cmpaW_dec(op, start, k)
        case .cmpaW_disp: return run_cmpaW_disp(op, start, k)
        case .cmpaW_index: return run_cmpaW_index(op, start, k)
        case .cmpaW_absW: return run_cmpaW_absW(op, start, k)
        case .cmpaW_absL: return run_cmpaW_absL(op, start, k)
        case .cmpaW_pcDisp: return run_cmpaW_pcDisp(op, start, k)
        case .cmpaW_pcIndex: return run_cmpaW_pcIndex(op, start, k)
        case .cmpaW_imm: return run_cmpaW_imm(op, start, k)
        case .addaW_dn: return run_addaW_dn(op, start, k)
        case .addaW_an: return run_addaW_an(op, start, k)
        case .addaW_ind: return run_addaW_ind(op, start, k)
        case .addaW_inc: return run_addaW_inc(op, start, k)
        case .addaW_dec: return run_addaW_dec(op, start, k)
        case .addaW_disp: return run_addaW_disp(op, start, k)
        case .addaW_index: return run_addaW_index(op, start, k)
        case .addaW_absW: return run_addaW_absW(op, start, k)
        case .addaW_absL: return run_addaW_absL(op, start, k)
        case .addaW_pcDisp: return run_addaW_pcDisp(op, start, k)
        case .addaW_pcIndex: return run_addaW_pcIndex(op, start, k)
        case .addaW_imm: return run_addaW_imm(op, start, k)
        case .subaW_dn: return run_subaW_dn(op, start, k)
        case .subaW_an: return run_subaW_an(op, start, k)
        case .subaW_ind: return run_subaW_ind(op, start, k)
        case .subaW_inc: return run_subaW_inc(op, start, k)
        case .subaW_dec: return run_subaW_dec(op, start, k)
        case .subaW_disp: return run_subaW_disp(op, start, k)
        case .subaW_index: return run_subaW_index(op, start, k)
        case .subaW_absW: return run_subaW_absW(op, start, k)
        case .subaW_absL: return run_subaW_absL(op, start, k)
        case .subaW_pcDisp: return run_subaW_pcDisp(op, start, k)
        case .subaW_pcIndex: return run_subaW_pcIndex(op, start, k)
        case .subaW_imm: return run_subaW_imm(op, start, k)
        case .cmpaL_dn: return run_cmpaL_dn(op, start, k)
        case .cmpaL_an: return run_cmpaL_an(op, start, k)
        case .cmpaL_ind: return run_cmpaL_ind(op, start, k)
        case .cmpaL_inc: return run_cmpaL_inc(op, start, k)
        case .cmpaL_dec: return run_cmpaL_dec(op, start, k)
        case .cmpaL_disp: return run_cmpaL_disp(op, start, k)
        case .cmpaL_index: return run_cmpaL_index(op, start, k)
        case .cmpaL_absW: return run_cmpaL_absW(op, start, k)
        case .cmpaL_absL: return run_cmpaL_absL(op, start, k)
        case .cmpaL_pcDisp: return run_cmpaL_pcDisp(op, start, k)
        case .cmpaL_pcIndex: return run_cmpaL_pcIndex(op, start, k)
        case .cmpaL_imm: return run_cmpaL_imm(op, start, k)
        case .addaL_dn: return run_addaL_dn(op, start, k)
        case .addaL_an: return run_addaL_an(op, start, k)
        case .addaL_ind: return run_addaL_ind(op, start, k)
        case .addaL_inc: return run_addaL_inc(op, start, k)
        case .addaL_dec: return run_addaL_dec(op, start, k)
        case .addaL_disp: return run_addaL_disp(op, start, k)
        case .addaL_index: return run_addaL_index(op, start, k)
        case .addaL_absW: return run_addaL_absW(op, start, k)
        case .addaL_absL: return run_addaL_absL(op, start, k)
        case .addaL_pcDisp: return run_addaL_pcDisp(op, start, k)
        case .addaL_pcIndex: return run_addaL_pcIndex(op, start, k)
        case .addaL_imm: return run_addaL_imm(op, start, k)
        case .subaL_dn: return run_subaL_dn(op, start, k)
        case .subaL_an: return run_subaL_an(op, start, k)
        case .subaL_ind: return run_subaL_ind(op, start, k)
        case .subaL_inc: return run_subaL_inc(op, start, k)
        case .subaL_dec: return run_subaL_dec(op, start, k)
        case .subaL_disp: return run_subaL_disp(op, start, k)
        case .subaL_index: return run_subaL_index(op, start, k)
        case .subaL_absW: return run_subaL_absW(op, start, k)
        case .subaL_absL: return run_subaL_absL(op, start, k)
        case .subaL_pcDisp: return run_subaL_pcDisp(op, start, k)
        case .subaL_pcIndex: return run_subaL_pcIndex(op, start, k)
        case .subaL_imm: return run_subaL_imm(op, start, k)
        case .mulu_dn: return run_mulu_dn(op, start, k)
        case .mulu_ind: return run_mulu_ind(op, start, k)
        case .mulu_inc: return run_mulu_inc(op, start, k)
        case .mulu_dec: return run_mulu_dec(op, start, k)
        case .mulu_disp: return run_mulu_disp(op, start, k)
        case .mulu_index: return run_mulu_index(op, start, k)
        case .mulu_absW: return run_mulu_absW(op, start, k)
        case .mulu_absL: return run_mulu_absL(op, start, k)
        case .mulu_pcDisp: return run_mulu_pcDisp(op, start, k)
        case .mulu_pcIndex: return run_mulu_pcIndex(op, start, k)
        case .mulu_imm: return run_mulu_imm(op, start, k)
        case .muls_dn: return run_muls_dn(op, start, k)
        case .muls_ind: return run_muls_ind(op, start, k)
        case .muls_inc: return run_muls_inc(op, start, k)
        case .muls_dec: return run_muls_dec(op, start, k)
        case .muls_disp: return run_muls_disp(op, start, k)
        case .muls_index: return run_muls_index(op, start, k)
        case .muls_absW: return run_muls_absW(op, start, k)
        case .muls_absL: return run_muls_absL(op, start, k)
        case .muls_pcDisp: return run_muls_pcDisp(op, start, k)
        case .muls_pcIndex: return run_muls_pcIndex(op, start, k)
        case .muls_imm: return run_muls_imm(op, start, k)
        case .shiftRegister_as_r_B_byCount: return run_shiftRegister_as_r_B_byCount(op, start, k)
        case .shiftRegister_as_r_B_byRegister: return run_shiftRegister_as_r_B_byRegister(op, start, k)
        case .shiftRegister_as_r_W_byCount: return run_shiftRegister_as_r_W_byCount(op, start, k)
        case .shiftRegister_as_r_W_byRegister: return run_shiftRegister_as_r_W_byRegister(op, start, k)
        case .shiftRegister_as_r_L_byCount: return run_shiftRegister_as_r_L_byCount(op, start, k)
        case .shiftRegister_as_r_L_byRegister: return run_shiftRegister_as_r_L_byRegister(op, start, k)
        case .shiftRegister_as_l_B_byCount: return run_shiftRegister_as_l_B_byCount(op, start, k)
        case .shiftRegister_as_l_B_byRegister: return run_shiftRegister_as_l_B_byRegister(op, start, k)
        case .shiftRegister_as_l_W_byCount: return run_shiftRegister_as_l_W_byCount(op, start, k)
        case .shiftRegister_as_l_W_byRegister: return run_shiftRegister_as_l_W_byRegister(op, start, k)
        case .shiftRegister_as_l_L_byCount: return run_shiftRegister_as_l_L_byCount(op, start, k)
        case .shiftRegister_as_l_L_byRegister: return run_shiftRegister_as_l_L_byRegister(op, start, k)
        case .shiftRegister_ls_r_B_byCount: return run_shiftRegister_ls_r_B_byCount(op, start, k)
        case .shiftRegister_ls_r_B_byRegister: return run_shiftRegister_ls_r_B_byRegister(op, start, k)
        case .shiftRegister_ls_r_W_byCount: return run_shiftRegister_ls_r_W_byCount(op, start, k)
        case .shiftRegister_ls_r_W_byRegister: return run_shiftRegister_ls_r_W_byRegister(op, start, k)
        case .shiftRegister_ls_r_L_byCount: return run_shiftRegister_ls_r_L_byCount(op, start, k)
        case .shiftRegister_ls_r_L_byRegister: return run_shiftRegister_ls_r_L_byRegister(op, start, k)
        case .shiftRegister_ls_l_B_byCount: return run_shiftRegister_ls_l_B_byCount(op, start, k)
        case .shiftRegister_ls_l_B_byRegister: return run_shiftRegister_ls_l_B_byRegister(op, start, k)
        case .shiftRegister_ls_l_W_byCount: return run_shiftRegister_ls_l_W_byCount(op, start, k)
        case .shiftRegister_ls_l_W_byRegister: return run_shiftRegister_ls_l_W_byRegister(op, start, k)
        case .shiftRegister_ls_l_L_byCount: return run_shiftRegister_ls_l_L_byCount(op, start, k)
        case .shiftRegister_ls_l_L_byRegister: return run_shiftRegister_ls_l_L_byRegister(op, start, k)
        case .shiftRegister_rox_r_B_byCount: return run_shiftRegister_rox_r_B_byCount(op, start, k)
        case .shiftRegister_rox_r_B_byRegister: return run_shiftRegister_rox_r_B_byRegister(op, start, k)
        case .shiftRegister_rox_r_W_byCount: return run_shiftRegister_rox_r_W_byCount(op, start, k)
        case .shiftRegister_rox_r_W_byRegister: return run_shiftRegister_rox_r_W_byRegister(op, start, k)
        case .shiftRegister_rox_r_L_byCount: return run_shiftRegister_rox_r_L_byCount(op, start, k)
        case .shiftRegister_rox_r_L_byRegister: return run_shiftRegister_rox_r_L_byRegister(op, start, k)
        case .shiftRegister_rox_l_B_byCount: return run_shiftRegister_rox_l_B_byCount(op, start, k)
        case .shiftRegister_rox_l_B_byRegister: return run_shiftRegister_rox_l_B_byRegister(op, start, k)
        case .shiftRegister_rox_l_W_byCount: return run_shiftRegister_rox_l_W_byCount(op, start, k)
        case .shiftRegister_rox_l_W_byRegister: return run_shiftRegister_rox_l_W_byRegister(op, start, k)
        case .shiftRegister_rox_l_L_byCount: return run_shiftRegister_rox_l_L_byCount(op, start, k)
        case .shiftRegister_rox_l_L_byRegister: return run_shiftRegister_rox_l_L_byRegister(op, start, k)
        case .shiftRegister_ro_r_B_byCount: return run_shiftRegister_ro_r_B_byCount(op, start, k)
        case .shiftRegister_ro_r_B_byRegister: return run_shiftRegister_ro_r_B_byRegister(op, start, k)
        case .shiftRegister_ro_r_W_byCount: return run_shiftRegister_ro_r_W_byCount(op, start, k)
        case .shiftRegister_ro_r_W_byRegister: return run_shiftRegister_ro_r_W_byRegister(op, start, k)
        case .shiftRegister_ro_r_L_byCount: return run_shiftRegister_ro_r_L_byCount(op, start, k)
        case .shiftRegister_ro_r_L_byRegister: return run_shiftRegister_ro_r_L_byRegister(op, start, k)
        case .shiftRegister_ro_l_B_byCount: return run_shiftRegister_ro_l_B_byCount(op, start, k)
        case .shiftRegister_ro_l_B_byRegister: return run_shiftRegister_ro_l_B_byRegister(op, start, k)
        case .shiftRegister_ro_l_W_byCount: return run_shiftRegister_ro_l_W_byCount(op, start, k)
        case .shiftRegister_ro_l_W_byRegister: return run_shiftRegister_ro_l_W_byRegister(op, start, k)
        case .shiftRegister_ro_l_L_byCount: return run_shiftRegister_ro_l_L_byCount(op, start, k)
        case .shiftRegister_ro_l_L_byRegister: return run_shiftRegister_ro_l_L_byRegister(op, start, k)
        case .movep, .immediateToStatus, .chk, .moveFromStatus, .negx, .moveToConditions, .moveToStatus, .nbcd, .tas, .trap, .link, .unlink, .moveUserStack, .resetInstruction, .stopInstruction, .trapv, .rtr, .divide, .decimal, .cmpm, .exchange, .shiftMemory, .unimplemented, .illegal:
            return seldom(step, op, start, k)
        }
    }

    @export(interface) @inline(never) mutating func run_oriB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 0, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 1, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 2, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 0, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 1, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 2, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 0, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 1, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 2, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 0, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 1, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 2, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 0, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 1, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 2, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 0, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 1, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 2, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, (op >> 6) & 3, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, (op >> 6) & 3, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: M68000Step.sourceMode(op), to: M68000Step.targetMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: M68000Step.sourceMode(op), to: M68000Step.targetMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: M68000Step.sourceMode(op), to: M68000Step.targetMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 0, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_lea(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        loadAddress(op, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_pea(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        pushAddress(op, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jsr(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jumpToSubroutine(op, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jmp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jump(op, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 0, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 0, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 1, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 1, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 2, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 2, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_neg(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        negate(op, (op >> 6) & 3, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_not(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        complement(op, (op >> 6) & 3, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_swap(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        swapHalves(op, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_extW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extend(op, long: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_extL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extend(op, long: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_movemStoreW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveMultiple(toMemory: true, long: false, op, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_movemStoreL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveMultiple(toMemory: true, long: true, op, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_movemLoadW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveMultiple(toMemory: false, long: false, op, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_movemLoadL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveMultiple(toMemory: false, long: true, op, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_nop(_: UInt32, _: UInt32, _ k: M68000Pace) -> M68000Pace { k }

    @export(interface) @inline(never) mutating func run_rts(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        returnFromSubroutine(&k)
        return k
    }

    @export(interface) @inline(never) mutating func run_rte(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        returnFromException(op, start, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbra(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, (op >> 8) & 15, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_scc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        set(op, (op >> 8) & 15, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqA(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quickAddress(op, subtracting: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqA(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quickAddress(op, subtracting: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: false, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: true, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: false, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: true, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: false, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: true, to: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bra(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bsr(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bhi(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bls(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bcc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bcs(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bne(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_beq(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bvc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bvs(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bpl(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bmi(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bge(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 12, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_blt(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 13, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bgt(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 14, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_ble(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        branch(op, 15, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveq(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveQuick(op, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addxB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: true, 0, memory: op & 8 != 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subxB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: false, 0, memory: op & 8 != 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addxW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: true, 1, memory: op & 8 != 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subxW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: false, 1, memory: op & 8 != 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addxL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: true, 2, memory: op & 8 != 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subxL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: false, 2, memory: op & 8 != 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 0, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 1, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 2, intoRegister: false, M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: M68000Step.sourceMode(op), &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, (op >> 3) & 3, left: op & 0x100 != 0, (op >> 6) & 3, byRegister: op & 0x20 != 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_oriL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 0, 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andiL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 1, 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subiL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 2, 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addiL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 3, 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eoriL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 5, 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpiL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        immediate(op, 6, 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_btst_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_btst_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_btst_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_btst_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_btst_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_btst_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_btst_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_btst_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bchg_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bchg_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bchg_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bchg_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bchg_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bchg_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bchg_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bchg_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bclr_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bclr_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bclr_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bclr_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bclr_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bclr_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bclr_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bclr_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bset_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 3, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bset_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 3, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bset_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 3, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bset_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 3, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bset_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 3, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bset_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 3, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bset_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 3, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitDynamic_bset_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitDynamic(op, 3, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_btst_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_btst_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_btst_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_btst_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_btst_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_btst_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_btst_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_btst_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bchg_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bchg_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bchg_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bchg_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bchg_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bchg_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bchg_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bchg_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bclr_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bclr_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bclr_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bclr_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bclr_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bclr_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bclr_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bclr_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bset_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 3, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bset_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 3, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bset_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 3, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bset_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 3, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bset_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 3, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bset_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 3, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bset_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 3, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_bitStatic_bset_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        bitStatic(op, 3, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dn_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dn_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dn_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dn_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dn_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dn_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dn_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dn_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_ind_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_ind_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_ind_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_ind_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_ind_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_ind_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_ind_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_ind_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_inc_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 3, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_inc_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 3, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_inc_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 3, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_inc_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 3, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_inc_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 3, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_inc_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 3, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_inc_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 3, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_inc_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 3, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dec_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 4, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dec_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 4, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dec_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 4, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dec_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 4, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dec_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 4, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dec_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 4, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dec_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 4, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_dec_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 4, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_disp_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 5, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_disp_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 5, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_disp_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 5, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_disp_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 5, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_disp_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 5, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_disp_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 5, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_disp_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 5, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_disp_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 5, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_index_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 6, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_index_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 6, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_index_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 6, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_index_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 6, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_index_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 6, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_index_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 6, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_index_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 6, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_index_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 6, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 7, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 7, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 7, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 7, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 7, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 7, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 7, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 7, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 8, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 8, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 8, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 8, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 8, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 8, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 8, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_absL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 8, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcDisp_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 9, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcDisp_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 9, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcDisp_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 9, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcDisp_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 9, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcDisp_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 9, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcDisp_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 9, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcDisp_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 9, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcDisp_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 9, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcIndex_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 10, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcIndex_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 10, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcIndex_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 10, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcIndex_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 10, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcIndex_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 10, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcIndex_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 10, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcIndex_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 10, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_pcIndex_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 10, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_imm_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 11, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_imm_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 11, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_imm_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 11, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_imm_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 11, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_imm_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 11, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_imm_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 11, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_imm_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 11, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveB_imm_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 0, from: 11, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dn_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dn_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dn_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dn_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dn_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dn_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dn_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dn_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_an_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_an_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_an_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_an_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_an_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_an_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_an_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_an_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_ind_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_ind_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_ind_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_ind_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_ind_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_ind_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_ind_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_ind_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_inc_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 3, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_inc_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 3, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_inc_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 3, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_inc_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 3, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_inc_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 3, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_inc_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 3, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_inc_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 3, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_inc_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 3, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dec_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 4, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dec_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 4, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dec_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 4, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dec_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 4, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dec_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 4, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dec_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 4, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dec_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 4, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_dec_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 4, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_disp_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 5, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_disp_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 5, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_disp_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 5, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_disp_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 5, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_disp_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 5, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_disp_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 5, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_disp_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 5, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_disp_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 5, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_index_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 6, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_index_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 6, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_index_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 6, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_index_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 6, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_index_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 6, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_index_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 6, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_index_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 6, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_index_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 6, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 7, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 7, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 7, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 7, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 7, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 7, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 7, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 7, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 8, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 8, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 8, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 8, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 8, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 8, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 8, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_absL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 8, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcDisp_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 9, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcDisp_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 9, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcDisp_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 9, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcDisp_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 9, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcDisp_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 9, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcDisp_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 9, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcDisp_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 9, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcDisp_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 9, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcIndex_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 10, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcIndex_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 10, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcIndex_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 10, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcIndex_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 10, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcIndex_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 10, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcIndex_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 10, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcIndex_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 10, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_pcIndex_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 10, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_imm_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 11, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_imm_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 11, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_imm_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 11, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_imm_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 11, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_imm_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 11, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_imm_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 11, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_imm_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 11, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveW_imm_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 1, from: 11, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dn_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dn_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dn_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dn_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dn_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dn_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dn_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dn_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_an_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_an_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_an_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_an_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_an_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_an_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_an_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_an_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_ind_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_ind_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_ind_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_ind_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_ind_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_ind_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_ind_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_ind_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_inc_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 3, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_inc_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 3, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_inc_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 3, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_inc_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 3, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_inc_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 3, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_inc_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 3, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_inc_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 3, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_inc_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 3, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dec_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 4, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dec_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 4, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dec_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 4, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dec_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 4, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dec_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 4, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dec_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 4, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dec_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 4, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_dec_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 4, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_disp_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 5, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_disp_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 5, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_disp_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 5, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_disp_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 5, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_disp_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 5, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_disp_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 5, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_disp_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 5, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_disp_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 5, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_index_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 6, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_index_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 6, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_index_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 6, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_index_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 6, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_index_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 6, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_index_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 6, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_index_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 6, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_index_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 6, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 7, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 7, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 7, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 7, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 7, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 7, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 7, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 7, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 8, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 8, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 8, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 8, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 8, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 8, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 8, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_absL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 8, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcDisp_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 9, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcDisp_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 9, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcDisp_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 9, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcDisp_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 9, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcDisp_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 9, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcDisp_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 9, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcDisp_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 9, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcDisp_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 9, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcIndex_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 10, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcIndex_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 10, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcIndex_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 10, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcIndex_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 10, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcIndex_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 10, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcIndex_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 10, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcIndex_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 10, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_pcIndex_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 10, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_imm_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 11, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_imm_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 11, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_imm_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 11, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_imm_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 11, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_imm_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 11, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_imm_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 11, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_imm_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 11, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveL_imm_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        move(op, 2, from: 11, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaW_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 1, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_moveaL_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        moveAddress(op, 2, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_lea_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        loadAddress(op, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_lea_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        loadAddress(op, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_lea_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        loadAddress(op, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_lea_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        loadAddress(op, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_lea_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        loadAddress(op, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_lea_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        loadAddress(op, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_lea_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        loadAddress(op, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_pea_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        pushAddress(op, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_pea_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        pushAddress(op, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_pea_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        pushAddress(op, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_pea_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        pushAddress(op, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_pea_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        pushAddress(op, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_pea_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        pushAddress(op, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_pea_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        pushAddress(op, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jsr_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jumpToSubroutine(op, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jsr_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jumpToSubroutine(op, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jsr_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jumpToSubroutine(op, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jsr_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jumpToSubroutine(op, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jsr_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jumpToSubroutine(op, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jsr_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jumpToSubroutine(op, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jsr_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jumpToSubroutine(op, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jmp_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jump(op, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jmp_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jump(op, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jmp_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jump(op, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jmp_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jump(op, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jmp_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jump(op, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jmp_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jump(op, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_jmp_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        jump(op, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 0, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 0, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 0, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 0, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 0, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 0, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 0, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 0, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 0, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 0, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 0, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 0, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 0, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 0, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 0, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 0, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 1, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 1, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 1, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 1, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 1, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 1, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 1, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 1, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 1, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 1, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 1, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 1, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 1, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 1, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 1, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 1, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 2, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 2, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 2, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 2, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 2, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 2, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 2, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_clrL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        clear(op, 2, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 2, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 2, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 2, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 2, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 2, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 2, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 2, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_tstL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        test(op, 2, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_t(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_hi(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_ls(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_cc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_cs(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_ne(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_eq(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_vc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_vs(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_pl(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_mi(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_ge(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 12, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_lt(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 13, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_gt(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 14, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_dbcc_le(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        decrementAndBranch(op, 15, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: false, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: false, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: false, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: false, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: false, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: false, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: false, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: false, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: true, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: true, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: true, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: true, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: true, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: true, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: true, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 0, subtracting: true, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: false, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: false, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: false, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: false, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: false, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: false, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: false, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: false, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: true, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: true, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: true, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: true, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: true, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: true, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: true, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 1, subtracting: true, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: false, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: false, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: false, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: false, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: false, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: false, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: false, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addqL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: false, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: true, to: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: true, to: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: true, to: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: true, to: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: true, to: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: true, to: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: true, to: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subqL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        quick(op, 2, subtracting: true, to: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orB_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 0, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orW_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 1, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orL_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_orEaL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .or, 2, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andB_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 0, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andW_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 1, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andL_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_andEaL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .and, 2, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addB_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 0, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addW_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 1, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addL_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addEaL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .add, 2, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subB_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 0, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subW_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 1, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subL_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: true, 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subEaL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .subtract, 2, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addxB_registers(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: true, 0, memory: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addxB_memory(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: true, 0, memory: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subxB_registers(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: false, 0, memory: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subxB_memory(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: false, 0, memory: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addxW_registers(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: true, 1, memory: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addxW_memory(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: true, 1, memory: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subxW_registers(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: false, 1, memory: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subxW_memory(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: false, 1, memory: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addxL_registers(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: true, 2, memory: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addxL_memory(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: true, 2, memory: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subxL_registers(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: false, 2, memory: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subxL_memory(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        extended(op, adding: false, 2, memory: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 0, intoRegister: false, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 0, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 0, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 0, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 0, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 0, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 0, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 0, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpB_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 0, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 1, intoRegister: false, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 1, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 1, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 1, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 1, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 1, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 1, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 1, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpW_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 1, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 2, intoRegister: false, 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 2, intoRegister: false, 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 2, intoRegister: false, 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 2, intoRegister: false, 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 2, intoRegister: false, 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 2, intoRegister: false, 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 2, intoRegister: false, 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_eorL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        combine(op, .eor, 2, intoRegister: false, 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpL_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compare(op, 2, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaW_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 1, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaW_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: false, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaW_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 1, subtracting: true, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_cmpaL_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        compareAddress(op, 2, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_addaL_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: false, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_an(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 1, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_subaL_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        addAddress(op, 2, subtracting: true, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_mulu_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: false, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_dn(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 0, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_ind(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 2, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_inc(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 3, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_dec(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 4, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_disp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 5, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_index(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 6, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_absW(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 7, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_absL(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 8, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_pcDisp(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 9, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_pcIndex(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 10, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_muls_imm(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        multiply(op, signed: true, from: 11, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_r_B_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: false, 0, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_r_B_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: false, 0, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_r_W_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: false, 1, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_r_W_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: false, 1, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_r_L_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: false, 2, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_r_L_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: false, 2, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_l_B_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: true, 0, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_l_B_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: true, 0, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_l_W_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: true, 1, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_l_W_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: true, 1, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_l_L_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: true, 2, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_as_l_L_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 0, left: true, 2, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_r_B_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: false, 0, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_r_B_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: false, 0, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_r_W_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: false, 1, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_r_W_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: false, 1, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_r_L_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: false, 2, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_r_L_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: false, 2, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_l_B_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: true, 0, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_l_B_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: true, 0, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_l_W_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: true, 1, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_l_W_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: true, 1, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_l_L_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: true, 2, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ls_l_L_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 1, left: true, 2, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_r_B_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: false, 0, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_r_B_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: false, 0, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_r_W_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: false, 1, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_r_W_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: false, 1, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_r_L_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: false, 2, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_r_L_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: false, 2, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_l_B_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: true, 0, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_l_B_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: true, 0, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_l_W_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: true, 1, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_l_W_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: true, 1, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_l_L_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: true, 2, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_rox_l_L_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 2, left: true, 2, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_r_B_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: false, 0, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_r_B_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: false, 0, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_r_W_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: false, 1, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_r_W_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: false, 1, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_r_L_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: false, 2, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_r_L_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: false, 2, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_l_B_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: true, 0, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_l_B_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: true, 0, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_l_W_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: true, 1, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_l_W_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: true, 1, byRegister: true, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_l_L_byCount(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: true, 2, byRegister: false, &k)
        return k
    }

    @export(interface) @inline(never) mutating func run_shiftRegister_ro_l_L_byRegister(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        var k = k
        shiftRegister(op, 3, left: true, 2, byRegister: true, &k)
        return k
    }
}
