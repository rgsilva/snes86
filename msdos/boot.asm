	TITLE	snes86 MS-DOS 2.0 boot sector
; Loaded by the HLE at 0000:7C00 (CS=0, IP=7C00), DL = boot drive. Loads
; IO.SYS to 0060:0000 and MSDOS.SYS to 0260:0000 (0060 + BIOSIZS 200h),
; then far-jumps to 0060:0000 (IO.SYS INIT). The load parameters come from
; the generated bootparams.inc (filled in by mkmsdos.py).

	INCLUDE	bootparams.inc		; IO_LBA, IO_SECS, DOS_LBA, DOS_SECS

IOSEG	EQU	60H
MSDSEG	EQU	260H

CODE	SEGMENT
	ASSUME	CS:CODE,DS:CODE
	ORG	7C00H

start:	JMP	SHORT boot
	NOP
	DB	"SNES86  "	; OEM name
	DW	512		; bytes/sector
	DB	2		; sectors/cluster
	DW	1		; reserved sectors
	DB	2		; FATs
	DW	112		; root entries
	DW	720		; total sectors
	DB	0FDH		; media
	DW	2		; sectors/FAT
	DW	9		; sectors/track
	DW	2		; heads
	DW	0		; hidden sectors

boot:	CLI
	XOR	AX,AX
	MOV	DS,AX
	MOV	SS,AX
	MOV	SP,7C00H
	STI
	MOV	[DRIVE],DL

	MOV	AX,IO_LBA
	MOV	CX,IO_SECS
	MOV	BX,IOSEG
	CALL	loadfile

	MOV	AX,DOS_LBA
	MOV	CX,DOS_SECS
	MOV	BX,MSDSEG
	CALL	loadfile

	MOV	DL,[DRIVE]
	DB	0EAH		; JMP FAR IOSEG:0000
	DW	0
	DW	IOSEG

; loadfile: AX=start LBA, CX=sector count, BX=dest segment.
loadfile:
	MOV	[curLBA],AX
	MOV	[curCNT],CX
	MOV	[curSEG],BX
lf1:	CMP	WORD PTR [curCNT],0
	JZ	lf_done
	MOV	AX,[curLBA]	; LBA -> CHS
	XOR	DX,DX
	MOV	BX,9
	DIV	BX		; AX=LBA/9, DX=sector index
	MOV	CL,DL
	INC	CL		; CL = sector (1-based)
	XOR	DX,DX
	MOV	BX,2
	DIV	BX		; AX=cyl, DX=head
	MOV	CH,AL		; CH = cylinder
	MOV	DH,DL		; DH = head
	MOV	DL,[DRIVE]
	MOV	ES,[curSEG]
	XOR	BX,BX
	MOV	AX,0201H	; AH=2 read, AL=1 sector
	INT	13H
	JC	lf_err
	INC	WORD PTR [curLBA]
	DEC	WORD PTR [curCNT]
	ADD	WORD PTR [curSEG],20H
	JMP	lf1
lf_done:
	RET

lf_err:	MOV	SI,OFFSET emsg
pe:	MOV	AL,[SI]
	OR	AL,AL
	JZ	hang
	MOV	AH,0EH
	MOV	BX,7
	INT	10H
	INC	SI
	JMP	pe
hang:	JMP	hang

emsg	DB	"IO ERR",0
DRIVE	DB	0
curLBA	DW	0
curCNT	DW	0
curSEG	DW	0

	ORG	7C00H+510
	DW	0AA55H

CODE	ENDS
	END	start
