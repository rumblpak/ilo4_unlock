/*
 * Minimal read-only probe for the V4 fan-restore build.
 *
 * This probe is a 12-function dependency closure of the `fan` handler,
 * designed to be read-only (no modifications to existing Health code).
 *
 * It uses the fn_handler.S calling convention documented in
 * patches/277/asm/fn_handler.S to invoke health_ipc_call (0x3e420).
 *
 * Calling convention:
 *   PUSH {R11, R12, LR, PC}       ; save context
 *   SUB    R11, R12, #4           ; compute exit address
 *   SUB    SP, SP, #0xA00         ; 0xA00-byte IPC struct
 *   STR    R0, [SP]               ; service ID at [SP+0]
 *   ... (build input struct) ...
 *   health_ipc_call(SP, SP+0x500) ; R0=SP, R1=SP+0x500
 *   LDR    R0, [SP, #0x500]       ; read result
 *   LDMDB  R11, {R11, SP, PC}     ; exit
 *
 * Input struct layout (0xA00 bytes at SP):
 *   [SP+0]:   service ID (5=health, 6=fan, 7=ocsd, 8=ocbb)
 *   [SP+4]:   input string (space-stripped from 0x1000+R7)
 *   [SP+0x500]: result area (output from health_ipc_call)
 */

.equ FAN_SERVICE_ID, 6
.equ HEALTH_SERVICE_ID, 5
.equ IPC_STRUCT_SIZE, 0xA00
.equ HEALTH_IPC_CALL, 0x3e420

/*
 * probe_fan_status:
 *   Calls "fan t" (thermal query) via health_ipc_call.
 *   Returns result in R0.
 *
 * This is a read-only probe -- it does not modify any fans,
 * does not write to hardware registers, and only reads back
 * what health_ipc_call returns.
 */
probe_fan_status:
    MOV     R12, SP                     ; initialize
    PUSH    {R11, R12, LR, PC}          ; save context
    SUB     R11, R12, #4                ; compute exit address

    SUB     SP, SP, #IPC_STRUCT_SIZE    ; 0xA00-byte IPC struct

    /* Set up input struct: [SP+0] = service ID, [SP+4] = command string */
    MOV     R0, #FAN_SERVICE_ID         ; service ID = 6 (fan)
    STR     R0, [SP]                    ; [SP+0] = fan service ID

    /* Input string: "t\0" (fan thermal query, space-stripped) */
    LDR     R0, _probe_cmd              ; R0 = address of command string
    ADD     R1, SP, #4                  ; R1 = target buffer (SP+4)
    BL      _probe_strcpy               ; copy null-terminated string

    /* Output buffer: [SP+0x500] */
    ADD     R1, SP, #IPC_STRUCT_SIZE    ; R1 = SP + 0x500

    /* Call health_ipc_call(SP, SP+0x500) */
    MOV     R0, SP                      ; arg1 = input struct pointer
    BL      _health_ipc_call            ; BL health_ipc_call

    /* Read result: R0 = [SP+0x500] */
    LDR     R0, [SP, #IPC_STRUCT_SIZE]  ; R0 = result value
    LDMDB   R11, {R11, SP, PC}          ; exit

    /* Command string: "t\0" (fan thermal query) */
    .word   _probe_cmd_data

_probe_cmd_data:
    .ascii  "t\0"
    .align  2

/*
 * Simple null-terminated string copy.
 * Input:  R0 = source, R1 = destination
 * Output: R1 = destination + strlen + 1
 * Clobbers: R2, R3
 */
_probe_strcpy:
    MOV     R2, #0                      ; R2 = counter (strlen)
_probe_strcpy_loop:
    LDRB    R3, [R0], #1                ; load byte, post-inc R0
    CMP     R3, #0                      ; check for null
    STRBEQ  R3, [R1], #1                ; store null, post-inc R1
    BNE     _probe_strcpy_store         ; if not null, store it
    SUB     R1, R1, #1                  ; undo null store
    MOV     PC, LR                      ; return

_probe_strcpy_store:
    STRB    R3, [R1], #1                ; store byte, post-inc R1
    ADD     R2, R2, #1                  ; advance counter
    CMP     R3, #0                      ; check for null
    BNE     _probe_strcpy_loop          ; continue if more bytes
    SUB     R1, R1, #1                  ; undo last increment
    MOV     PC, LR                      ; return

/*
 * health_ipc_call function-pointer literal.
 * health_ipc_call lives at in-partition address 0x3e420
 * (true vaddr = 0x3e420, confirmed as valid ARM code in 2.80 ELF).
 *
 * No direct BL to 0x3e420 exists in the 2.80 ELF.
 * All calls must go through the function-pointer lookup pattern.
 */
_health_ipc_call:
    LDR     R12, _health_ipc_call_addr
    BX      R12

_health_ipc_call_addr:
    .word   0x3e420
