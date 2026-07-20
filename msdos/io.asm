	TITLE	IO.SYS for snes86 (IBM-PC BIOS, MS-DOS 2.0)

; snes86 IO.SYS — the machine-dependent half of MS-DOS 2.0, written for the
; snes86 HLE BIOS (INT 10h/13h/16h/1Ah). Structure adapted from Microsoft's
; SKELIO.ASM (the Altos ACS-86C skeleton in the microsoft/MS-DOS v2.0 source);
; the Altos ROM/1793-controller code is replaced with IBM-PC BIOS calls.
; Links with the MIT MS-DOS 2.0 SYSINIT.OBJ. The boot sector loads this at
; BIOSSEG:0000 and jumps to offset 0 (INIT).

BIOSSEG	EQU	60H		; segment IO.SYS is loaded at
BIOSIZS	EQU	200H		; paras from IO.SYS start to MSDOS.SYS (8 KB budget)

	EXTRN	SYSINIT:FAR
	EXTRN	CURRENT_DOS_LOCATION:WORD
	EXTRN	FINAL_DOS_LOCATION:WORD
	EXTRN	DEVICE_LIST:DWORD
	EXTRN	MEMORY_SIZE:WORD
	EXTRN	DEFAULT_DRIVE:BYTE
	EXTRN	BUFFERS:BYTE

	PUBLIC	RE_INIT

CODE	SEGMENT
	ASSUME	CS:CODE,DS:CODE,ES:CODE,SS:CODE
	OPTION	OLDSTRUCTS
	ORG	0

INIT:	JMP	HWINIT

;----------------------------------------------------------------------
; Device driver headers (CON, AUX, PRN, CLOCK, DISK)
;----------------------------------------------------------------------
DEVSTART LABEL	WORD
CONDEV	DW	AUXDEV,BIOSSEG
	DW	8003H		; char: sti+sto (no INT29 fast path -> output via CON write)
	DW	STRATEGY
	DW	CON_INT
	DB	"CON     "
AUXDEV	DW	PRNDEV,BIOSSEG
	DW	8000H
	DW	STRATEGY
	DW	AUX_INT
	DB	"AUX     "
PRNDEV	DW	TIMDEV,BIOSSEG
	DW	8000H
	DW	STRATEGY
	DW	PRN_INT
	DB	"PRN     "
TIMDEV	DW	DSKDEV,BIOSSEG
	DW	8008H		; char: clock
	DW	STRATEGY
	DW	TIM_INT
	DB	"CLOCK   "
DSKDEV	DW	-1,-1
	DW	2000H		; block device
	DW	STRATEGY
	DW	DSK_INT
DRVMAX	DB	1		; number of block units (A: for now)
	DB	7 DUP (?)

;----------------------------------------------------------------------
; Per-device command dispatch tables (commands 0..12)
;----------------------------------------------------------------------
DSKTBL	DW	DSK_INIT,MEDIAC,GET_BPB,CMDERR,DSK_RED,BUS_EXIT,EXIT,EXIT
	DW	DSK_WRT,DSK_WRT,EXIT,EXIT,EXIT
CONTBL	DW	EXIT,EXIT,EXIT,CMDERR,CON_READ,CON_RDND,EXIT,CON_FLSH
	DW	CON_WRIT,CON_WRIT,CON_WRST,EXIT,EXIT
AUXTBL	DW	EXIT,EXIT,EXIT,CMDERR,EXIT,BUS_EXIT,EXIT,EXIT
	DW	AUX_WRIT,AUX_WRIT,EXIT,EXIT,EXIT
TIMTBL	DW	EXIT,EXIT,EXIT,CMDERR,TIM_RED,BUS_EXIT,EXIT,EXIT
	DW	TIM_WRT,TIM_WRT,EXIT,EXIT,EXIT
PRNTBL	DW	EXIT,EXIT,EXIT,CMDERR,EXIT,BUS_EXIT,EXIT,EXIT
	DW	PRN_WRT,PRN_WRT,PRN_STA,EXIT,EXIT

;----------------------------------------------------------------------
; Request packet layout + strategy/interrupt entry (MS-DOS 2.0 driver ABI)
;----------------------------------------------------------------------
IODAT	STRUC
CMDLEN	DB	?
IUNIT	DB	?
CMD	DB	?
STAT	DW	?
	DB	8 DUP (?)
MEDIA	DB	?
TRANS	DD	?
CCOUNT	DW	?
STARTS	DW	?
IODAT	ENDS

PTRSAV	DD	0

STRATEGY:			; DOS far-calls this — must RETF
	MOV	WORD PTR CS:[PTRSAV],BX
	MOV	WORD PTR CS:[PTRSAV+2],ES
	RETF

CON_INT: PUSH	SI
	MOV	SI,OFFSET CONTBL
	JMP	SHORT ENTRY
AUX_INT: PUSH	SI
	MOV	SI,OFFSET AUXTBL
	JMP	SHORT ENTRY
PRN_INT: PUSH	SI
	MOV	SI,OFFSET PRNTBL
	JMP	SHORT ENTRY
TIM_INT: PUSH	SI
	MOV	SI,OFFSET TIMTBL
	JMP	SHORT ENTRY
DSK_INT: PUSH	SI
	MOV	SI,OFFSET DSKTBL

ENTRY:	PUSH	AX
	PUSH	CX
	PUSH	DX
	PUSH	DI
	PUSH	BP
	PUSH	DS
	PUSH	ES
	PUSH	BX
	LDS	BX,CS:[PTRSAV]
	MOV	AL,[BX.IUNIT]
	MOV	AH,[BX.MEDIA]
	MOV	CX,[BX.CCOUNT]
	MOV	DX,[BX.STARTS]
	XCHG	DI,AX
	MOV	AL,[BX.CMD]
	XOR	AH,AH
	ADD	SI,AX
	ADD	SI,AX
	CMP	AL,12
	JA	CMDERR
	XCHG	AX,DI
	LES	DI,[BX.TRANS]
	PUSH	CS
	POP	DS
	JMP	WORD PTR [SI]

;----------------------------------------------------------------------
; Common exits
;----------------------------------------------------------------------
BUS_EXIT: MOV	AH,00000011B	; busy + done
	JMP	SHORT EXIT1
CMDERR:	MOV	AL,3		; unknown command
ERR_EXIT: MOV	AH,10000001B	; error + done
	JMP	SHORT EXIT1
EXIT:	MOV	AH,00000001B	; done
EXIT1:	LDS	BX,CS:[PTRSAV]
	MOV	[BX.STAT],AX
	POP	BX
	POP	ES
	POP	DS
	POP	BP
	POP	DI
	POP	DX
	POP	CX
	POP	AX
	POP	SI
	RETF			; DOS far-calls the interrupt routine

;----------------------------------------------------------------------
; Console — keyboard via INT 16h, screen via INT 10h teletype
;----------------------------------------------------------------------
CHAR	DB	0		; one-byte type-ahead

; CISTAT: on return, ZF=0 and AL=char if one is ready, else ZF=1.
CISTAT:	PUSH	CX
	PUSH	DX
	MOV	AL,CS:[CHAR]
	OR	AL,AL
	JNZ	CIST9
	MOV	AH,1
	INT	16H		; ZF=1 if no key
	JZ	CIST9
	MOV	AH,0
	INT	16H		; AL=ascii, AH=scan
	OR	AL,AL
	JNZ	CIST8
	MOV	AL,AH		; extended key: surface the scan code
CIST8:	MOV	CS:[CHAR],AL
CIST9:	OR	AL,AL
	POP	DX
	POP	CX
	RET

CINP:	CALL	CISTAT
	JZ	CINP
	MOV	BYTE PTR CS:[CHAR],0
	RET

CON_RDND: CALL	CISTAT
	JZ	CON_RDN2
	LDS	BX,CS:[PTRSAV]
	MOV	[BX.MEDIA],AL
	JMP	EXIT
CON_RDN2: JMP	BUS_EXIT

CON_READ: CALL	CINP
	STOSB
	LOOP	CON_READ
	JMP	EXIT

CON_FLSH: MOV	BYTE PTR CS:[CHAR],0
	JMP	EXIT

CON_WRST: JMP	EXIT

CON_WRIT: MOV	SI,DI
CON_WRI1: MOV	AL,ES:[SI]
	INC	SI
	PUSH	CX
	CALL	OUTCHR
	POP	CX
	LOOP	CON_WRI1
	JMP	EXIT

OUTCHR:	PUSH	BX
	MOV	AH,0EH
	MOV	BX,0007H
	INT	10H
	POP	BX
	RET

;----------------------------------------------------------------------
; AUX (sink) + PRN (INT 17h)
;----------------------------------------------------------------------
AUX_WRIT: JMP	EXIT
PRN_STA: JMP	EXIT
PRN_WRT: MOV	SI,DI
PRN_WR1: MOV	AL,ES:[SI]
	INC	SI
	PUSH	CX
	MOV	AH,0
	XOR	DX,DX
	INT	17H
	POP	CX
	LOOP	PRN_WR1
	JMP	EXIT

;----------------------------------------------------------------------
; CLOCK — 6-byte packet: word days-since-1980, min, hr, hundredths, sec
;----------------------------------------------------------------------
TIMBUF	DW	0		; days since 1980-01-01
	DB	0		; minutes
	DB	0		; hours
	DB	0		; hundredths
	DB	0		; seconds

TIM_RED: MOV	SI,OFFSET TIMBUF
	MOV	CX,6
TR1:	MOV	AL,CS:[SI]
	STOSB
	INC	SI
	LOOP	TR1
	JMP	EXIT

TIM_WRT: MOV	SI,DI
	MOV	DI,OFFSET TIMBUF
	PUSH	ES
	PUSH	DS
	POP	ES		; ES=CS (we are in CS as DS already)
	MOV	CX,6
TW1:	MOV	AL,DS:[SI]	; note: caller buffer was ES:DI, now swapped
	MOV	CS:[DI],AL
	INC	SI
	INC	DI
	LOOP	TW1
	POP	ES
	JMP	EXIT

;----------------------------------------------------------------------
; DISK — INT 13h floppy read/write, logical sector -> CHS
;----------------------------------------------------------------------
SPT	EQU	9		; sectors/track (360 KB)
NHEADS	EQU	2

; BPB for a 360 KB 5.25" floppy (matches our A: image)
FLOPPY_BPB:
	DW	512		; bytes per sector
	DB	2		; sectors per cluster
	DW	1		; reserved sectors
	DB	2		; number of FATs
	DW	112		; root directory entries
	DW	720		; total sectors
	DB	0FDH		; media descriptor
	DW	2		; sectors per FAT
BPB_TAB DW	FLOPPY_BPB	; array of BPB pointers (1 unit)

MEDIAC:	LDS	BX,CS:[PTRSAV]
	MOV	BYTE PTR [BX+14],1	; media-status flag = not changed
	MOV	AX,0100H		; AL=0 ok, AH=done set below
	JMP	EXIT

GET_BPB: LDS	BX,CS:[PTRSAV]
	MOV	BYTE PTR [BX+13],0FDH	; media byte
	MOV	WORD PTR [BX+18],OFFSET FLOPPY_BPB
	MOV	[BX+20],CS
	JMP	EXIT

DSK_INIT: LDS	BX,CS:[PTRSAV]
	MOV	BYTE PTR [BX+13],1	; number of block units
	MOV	WORD PTR [BX+14],OFFSET IO_END	; break address (end of resident)
	MOV	[BX+16],CS
	MOV	WORD PTR [BX+18],OFFSET BPB_TAB	; BPB pointer array
	MOV	[BX+20],CS
	JMP	EXIT

; DSK_RED/DSK_WRT entry (from ENTRY): AL=unit, AH=media, CX=sector count,
; DX=start logical sector, ES:DI=transfer address.
DSK_RED: MOV	BYTE PTR CS:[RWOP],2	; INT13 read
	JMP	SHORT DSK_COM
DSK_WRT: MOV	BYTE PTR CS:[RWOP],3	; INT13 write
DSK_COM:
	MOV	CS:[RWCNT],CX
	MOV	CS:[RWLBA],DX
	MOV	CS:[RWSEG],ES
	MOV	CS:[RWOFF],DI
DSK_LOOP:
	MOV	CX,CS:[RWCNT]
	JCXZ	DSK_DONE
	; logical LBA -> CHS: sector = LBA mod SPT + 1, tmp = LBA / SPT
	MOV	AX,CS:[RWLBA]
	XOR	DX,DX
	MOV	BX,SPT
	DIV	BX		; AX=LBA/SPT, DX=sector index
	MOV	CL,DL
	INC	CL		; CL = sector (1-based)
	; head = tmp mod NHEADS, cyl = tmp / NHEADS
	XOR	DX,DX
	MOV	BX,NHEADS
	DIV	BX		; AX=cyl, DX=head
	MOV	CH,AL		; CH = cylinder low 8 bits
	MOV	DH,DL		; DH = head
	MOV	DL,0		; DL = drive 0 (A:)
	MOV	AH,CS:[RWOP]
	MOV	AL,1		; one sector
	MOV	ES,CS:[RWSEG]
	MOV	BX,CS:[RWOFF]
	INT	13H
	JC	DSK_ERR
	; advance
	INC	WORD PTR CS:[RWLBA]
	DEC	WORD PTR CS:[RWCNT]
	ADD	WORD PTR CS:[RWOFF],512
	JNC	DSK_LOOP
	MOV	AX,CS:[RWSEG]	; offset wrapped: bump segment
	ADD	AX,1000H
	MOV	CS:[RWSEG],AX
	JMP	DSK_LOOP
DSK_DONE:
	MOV	AL,0
	JMP	EXIT
DSK_ERR:
	; report count actually transferred = 0, general error
	LDS	BX,CS:[PTRSAV]
	MOV	[BX.CCOUNT],0
	MOV	AL,12
	JMP	ERR_EXIT

RWOP	DB	0
RWCNT	DW	0
RWLBA	DW	0
RWSEG	DW	0
RWOFF	DW	0

; RE_INIT — SYSINIT re-calls the BIOS once DOS is up (MS non-IBM version).
; Nothing extra to do on our HLE machine; just return.
RE_INIT	PROC	FAR
	RET
RE_INIT	ENDP

IO_END	LABEL	WORD		; end of resident driver code

;----------------------------------------------------------------------
; One-time hardware init -> hand off to SYSINIT (overlaid afterwards)
;----------------------------------------------------------------------
WRKSTK	DB	128 DUP (?)

HWINIT:	XOR	BP,BP
	MOV	SS,BP
	MOV	SP,OFFSET WRKSTK+126
	PUSH	CS
	POP	ES
	INT	12H		; AX = conventional memory in KB
	MOV	CL,6
	SHL	AX,CL		; KB*64 = paragraphs
	MOV	DI,AX		; DI = memory size in paragraphs
	MOV	AX,SEG SYSINIT
	MOV	DS,AX
	ASSUME	DS:SEG SYSINIT
	MOV	AX,CS
	ADD	AX,BIOSIZS
	MOV	DS:[CURRENT_DOS_LOCATION],AX
	MOV	DS:[MEMORY_SIZE],DI
	MOV	AX,CS
	MOV	WORD PTR DS:[DEVICE_LIST+2],AX
	MOV	WORD PTR DS:[DEVICE_LIST],OFFSET DEVSTART
	MOV	AX,CS
	ADD	AX,((OFFSET WRKSTK - OFFSET INIT)+50)/16
	MOV	DS:[FINAL_DOS_LOCATION],AX
	JMP	SYSINIT

CODE	ENDS
	END
