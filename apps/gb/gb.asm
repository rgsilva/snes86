; GB.COM - a Game Boy (DMG) emulator for the 8086, as a DOS .COM program.
; Runs real GB software inside snes86's emulated PC (see docs/FUTURE.md,
; "Nested emulation"). Assemble: nasm -f bin -Ibuild/ -o build/GB.COM gb.asm
;
; Machine model
; -------------
; The full 64 KB GB address space lives flat in one 8086 segment (GBSEG),
; allocated right after this program. DS=ES=GBSEG at all times while the
; core runs, so instruction fetch is `lodsb` and memory READS are direct
; ([bx]/[si]/[di]). All WRITES go through wr8 (ROM protect, echo RAM, IO).
;
; Register mapping (fixed):  A->AL  F->AH  BC->CX  DE->DX  HL->BX
;                            SP->BP (DS-prefixed)  PC->SI  DI=scratch
; GB F is kept in 8086 LAHF format: Z=bit6(ZF) H=bit4(AF) C=bit0(CF), and
; GB's N flag lives in bit3, which LAHF always returns as 0 on our cores
; (core-c x86.c canon() / snes cpu2.asm), so `lahf` + `or ah,8` after
; subtract-class ops is the whole flag model. SAHF before ADC/SBC/RL
; restores the GB carry into CF. INC/DEC preserve CF on both CPUs, so
; sahf/inc/lahf keeps GB semantics for free.
;
; Timing: T-cycles, batched per 456-cycle scanline (do_sync): LY advance,
; VBlank IF, DIV/TIMA, interrupt dispatch, HALT idle-skip. Coarse (nothing
; sub-scanline), which is fine for the M1 target: Blargg's cpu_instrs.
;
; Known M1 simplifications: no PPU rendering yet (M2), echo RAM coherent
; only for writes through E000-FDFF, INC/DEC (HL) honour wr8 but plain
; reads never trap, HALT-bug byte-skip not modelled, serial is an instant
; wire to the DOS console (that is how Blargg's ROMs print).

cpu 8086
bits 16
org 0x100

start:
    cli
    mov sp, stktop
    sti
    cld

    ; ---- command line: GB [-t] [-b] [-rN] ROMFILE
    mov si, 0x81
.argl:
    lodsb
    cmp al, ' '
    je  .argl
    cmp al, 13
    je  .argsdone
    cmp al, '-'
    je  .flag
    mov di, namebuf                 ; ROM name token
.cpn:
    stosb
    lodsb
    cmp al, ' '
    je  .cpe
    cmp al, 13
    jne .cpn
.cpe:
    mov byte [di], 0
    cmp al, 13
    je  .argsdone
    jmp .argl
.flag:
    lodsb
    or  al, 0x20                    ; lowercase
    cmp al, 't'
    je  .ft
    cmp al, 'b'
    je  .fb
    cmp al, 'f'
    je  .ff
    cmp al, 'o'
    je  .fo
    cmp al, 's'
    je  .fs
    cmp al, 'r'
    je  .fr
    jmp err_usage
.ft:
    mov byte [cs:textmode], 1
    jmp .argl
.fb:
    mov byte [cs:useboot], 1
    jmp .argl
.ff:
    mov byte [cs:fastspin], 1
    jmp .argl
.fo:
    mov byte [cs:serfile], 1
    jmp .argl
.fs:                                ; -sN: after N GB frames, dump the CGA
    mov word [cs:shotf], 0          ; framebuffer to GBSHOT.RAW and exit
.fsd:
    lodsb
    cmp al, '0'
    jb  .fsdone
    cmp al, '9'
    ja  .fsdone
    sub al, '0'
    mov cx, [cs:shotf]              ; shotf = shotf*10 + digit
    mov dx, cx
    shl cx, 1
    shl cx, 1
    add cx, dx
    shl cx, 1
    mov ah, 0
    add cx, ax
    mov [cs:shotf], cx
    jmp .fsd
.fsdone:
    cmp word [cs:shotf], 0          ; -s with no number: sensible default
    jne .fsx
    mov word [cs:shotf], 600
.fsx:
    cmp al, 13
    je  .argsdone
    jmp .argl
.fr:
    mov byte [cs:rn], 0
.frd:
    lodsb
    cmp al, '0'
    jb  .frdone
    cmp al, '9'
    ja  .frdone
    sub al, '0'
    mov dl, [cs:rn]                 ; rn = rn*10 + digit
    mov dh, dl
    shl dl, 1
    shl dl, 1
    add dl, dh
    shl dl, 1
    add dl, al
    mov [cs:rn], dl
    jmp .frd
.frdone:
    cmp al, 13
    je  .argsdone
    jmp .argl
.argsdone:
    cmp byte [cs:namebuf], 0
    je  err_usage

    ; ---- carve out GBSEG right after the program, check it fits
    mov ax, cs
    add ax, PROGPARA
    mov [cs:gbseg], ax
    mov dx, [0x0002]            ; top of our memory block (PSP field)
    sub dx, ax
    cmp dx, 0x1000              ; need a full 64 KB
    jb  err_mem

    ; ---- optional DMG boot ROM (-b): 256 bytes from DMGBOOT.BIN
    cmp byte [cs:useboot], 0
    je  .noboot
    mov dx, bootname
    mov ax, 0x3D00
    int 0x21
    jc  err_boot
    mov bx, ax
    mov dx, bootbuf
    mov cx, 256
    mov ah, 0x3F
    int 0x21
    jc  err_boot
    cmp ax, 256
    jne err_boot
    mov ah, 0x3E
    int 0x21
.noboot:

    ; ---- load the ROM at GBSEG:0000 (32 KB max: no-MBC carts only)
    mov dx, namebuf
    mov ax, 0x3D00
    int 0x21
    jc  err_open
    mov bx, ax
    mov ds, [cs:gbseg]
    xor dx, dx
    mov cx, 0x8000
    mov ah, 0x3F
    int 0x21
    jc  err_read
    cmp ax, 0x0150
    jb  err_read                ; smaller than a cart header: not a ROM
    mov cx, 1                   ; anything left? then it needs an MBC
    mov dx, 0xFFFF              ; scratch byte, zeroed below anyway
    mov ah, 0x3F
    int 0x21
    jc  err_read
    or  ax, ax
    jnz err_big
    mov ah, 0x3E
    int 0x21

    ; ---- clear 8000-FFFF (VRAM/WRAM/OAM/IO), set post-boot IO defaults
    push ds
    pop  es
    mov di, 0x8000
    mov cx, 0x4000
    xor ax, ax
    rep stosw
    mov byte [0xFF00], 0xCF     ; JOYP: nothing pressed
    mov byte [0xFF07], 0xF8     ; TAC
    mov byte [0xFF48], 0xFF     ; OBP0/1 power-on pattern
    mov byte [0xFF49], 0xFF
    mov al, 0xFF
    mov bx, obpv0
    call obp_build
    mov al, 0xFF
    mov bx, obpv1
    call obp_build
    call install9               ; joypad: track make/break via INT 9

    ; ---- -o: create GBOUT.TXT for the serial log (headless test rigs
    ; like DOSBox have no serial-to-stdout; they read this file)
    cmp byte [cs:serfile], 0
    je  .noso
    push ds
    push cs
    pop  ds
    mov dx, sername
    xor cx, cx
    mov ah, 0x3C
    int 0x21
    pop ds
    jc  .nosf
    mov [cs:sfh], ax
    jmp .noso
.nosf:
    mov byte [cs:serfile], 0
.noso:

    ; ---- CGA 320x200x4 unless -t; palette 1 bright on black background
    ; (GB shades map to v: 0->3 white, 1->1 cyan, 2->2 magenta, 3->0 black)
    cmp byte [cs:textmode], 0
    jne .txt
    mov ax, 0x0004
    int 0x10
    mov dx, 0x03D9
    mov al, 0x30
    out dx, al
    mov byte [cs:gfxon], 1
.txt:

    mov word [cs:slcyc], 456
    cmp byte [cs:useboot], 0
    jne .bootstart

    ; ---- post-boot register state (as the DMG boot ROM leaves it)
    mov byte [0xFF0F], 0xE1     ; IF
    mov byte [0xFF40], 0x91     ; LCDC: on, BG on
    mov byte [0xFF41], 0x85     ; STAT
    mov byte [0xFF47], 0xFC     ; BGP
    mov ax, 0x5101              ; A=01, F=B0 -> LAHF format Z|H|C = 0x51
    mov bx, 0x014D
    mov cx, 0x0013
    mov dx, 0x00D8
    mov bp, 0xFFFE
    mov si, 0x0100
    jmp fetch

.bootstart:
    ; stash cart 0000-00FF, overlay the boot ROM, start cold at PC=0
    mov byte [0xFF0F], 0xE0
    push es
    push cs
    pop  es
    xor si, si
    mov di, stashbuf
    mov cx, 128
    rep movsw                   ; GBSEG:0 -> CS:stashbuf
    pop es
    push ds
    push cs
    pop  ds
    mov si, bootbuf
    xor di, di
    mov cx, 128
    rep movsw                   ; CS:bootbuf -> GBSEG:0
    pop ds
    xor ax, ax
    xor bx, bx
    xor cx, cx
    xor dx, dx
    xor bp, bp
    xor si, si
    jmp fetch

; ==========================================================================
; Epilogue ladder + dispatcher. Every handler ends `jmp epiN` (charge N
; T-cycles); a scanline's budget going negative drops into do_sync.
epi24: sub word [cs:slcyc], 24
       jmp epchk
epi20: sub word [cs:slcyc], 20
       jmp epchk
epi16: sub word [cs:slcyc], 16
       jmp epchk
epi12: sub word [cs:slcyc], 12
       jmp epchk
epi8:  sub word [cs:slcyc], 8
       jmp epchk
epi4:  sub word [cs:slcyc], 4
epchk: js  do_sync
fetch: mov di, [si]              ; opcode in the low byte; AL is GB A and
       inc si                    ; must survive the fetch, so no lodsb here
       and di, 0x00FF
       shl di, 1
       jmp word [cs:optab+di]

; ==========================================================================
; Scanline boundary: LY, VBlank, DIV, TIMA, interrupts, HALT idle-skip.
; AX (incl. the flag byte AH) is pushed for the duration; BX pushed locally.
do_sync:
    push ax
    cmp byte [cs:eihack], 0     ; EI's one-instruction delay window?
    je  sync_norm
    mov byte [cs:eihack], 0
    mov ax, [cs:slcyc]          ; = 3 - n, n = cycles of the delayed instr
    add ax, [cs:slsave]
    sub ax, 3
    mov [cs:slcyc], ax
    or  ax, ax
    jg  int_check               ; still mid-scanline: just check interrupts
sync_norm:
    add word [cs:slcyc], 456
    mov di, 0xFF44              ; LY
    mov al, [di]
    inc al
    cmp al, 154
    jb  .st
    xor al, al
.st:
    mov [di], al
    mov ah, [di-3]              ; STAT: coarse mode (1=VBlank else 0) + LYC
    and ah, 0xF8
    or  ah, 0x80
    cmp al, 144
    jb  .m0
    or  ah, 1
.m0:
    cmp al, [di+1]              ; LYC (FF45)
    jne .nlyc
    or  ah, 4
    test ah, 0x40
    jz  .nlyc
    or  byte [di-0x35], 2       ; STAT interrupt
.nlyc:
    mov [di-3], ah
    cmp al, 144                 ; log per-scanline render registers so the
    jae .nolog                  ; renderer can honour mid-frame changes
    push bx                     ; (window toggles, status-bar scrolls)
    mov bl, al
    mov bh, 0
    shl bx, 1
    shl bx, 1
    shl bx, 1
    mov ah, [di-4]              ; LCDC
    mov [cs:slog+bx], ah
    mov ah, [di-2]              ; SCY
    mov [cs:slog+bx+1], ah
    mov ah, [di-1]              ; SCX
    mov [cs:slog+bx+2], ah
    mov ah, [di+6]              ; WY
    mov [cs:slog+bx+3], ah
    mov ah, [di+7]              ; WX
    mov [cs:slog+bx+4], ah
    pop bx
.nolog:
    or  al, al
    jnz .nf
    call frame_tick             ; once per frame: host keyboard poll
.nf:
    cmp al, 144
    jne .nv
    mov di, 0xFF0F
    or  byte [di], 1            ; request VBlank
.nv:
    mov ax, [cs:divacc]         ; DIV: one tick per 256 T-cycles
    add ax, 456
    mov di, 0xFF04
    add [di], ah
    xor ah, ah
    mov [cs:divacc], ax
    mov di, 0xFF07              ; TIMA, if TAC enable bit set
    mov al, [di]
    test al, 4
    jz  int_check
    and ax, 3
    mov di, ax
    shl di, 1
    mov di, [cs:ratetab+di]     ; T-cycles per TIMA tick
    mov ax, [cs:timacc]
    add ax, 456
    push bx
    mov bx, 0xFF05
.tl:
    cmp ax, di
    jb  .td
    sub ax, di
    inc byte [bx]
    jnz .tl
    push ax                     ; overflow: TIMA=TMA, request timer int
    mov al, [bx+1]
    mov [bx], al
    pop ax
    or  byte [bx+0x0A], 4       ; IF is FF05+0x0A
    jmp .tl
.td:
    pop bx
    mov [cs:timacc], ax
    cmp byte [cs:serialcnt], 0  ; pending serial transfer?
    je  int_check
    dec byte [cs:serialcnt]
    jnz int_check
    mov di, 0xFF02
    and byte [di], 0x7F         ; done: SC idle, no cable clocks in 0xFF
    mov byte [di-1], 0xFF
    or  byte [di+0x0D], 8       ; serial interrupt

int_check:
    mov di, 0xFF0F
    mov al, [di]
    and al, [di+0x00F0]         ; IE (FFFF)
    and al, 0x1F
    jz  .idle
    mov byte [cs:halted], 0
    cmp byte [cs:ime], 0
    je  .resume
    mov byte [cs:ime], 0        ; service highest-priority pending
    mov ah, 0x01
    mov di, 0x0040
    test al, ah
    jnz .svc
    mov ah, 0x02
    mov di, 0x0048
    test al, ah
    jnz .svc
    mov ah, 0x04
    mov di, 0x0050
    test al, ah
    jnz .svc
    mov ah, 0x08
    mov di, 0x0058
    test al, ah
    jnz .svc
    mov ah, 0x10
    mov di, 0x0060
.svc:
    not ah
    push bx
    mov bx, 0xFF0F
    and [bx], ah
    pop bx
    dec bp
    dec bp
    mov [ds:bp], si
    mov si, di
    sub word [cs:slcyc], 20
    cmp si, 0x0040
    jne .n40
    inc word [cs:d40]
.n40:
    cmp si, 0x0058
    jne .n58
    inc word [cs:d58]
.n58:
.resume:
    pop ax
    jmp fetch
.idle:
    cmp byte [cs:halted], 0
    je  .resume
    jmp sync_norm               ; halted, nothing pending: burn a scanline

frame_tick:
    push bx
    push cx
    push dx
    push di
    cmp byte [cs:escflag], 0    ; set by our INT 9 handler; INT 16h must
    jne exit_esc                ; never be called while it is installed
    mov al, [cs:kdr]            ; apply deferred key releases
    or  al, [cs:kbr]
    jz  .norel
    mov al, [cs:kdr]
    not al
    and [cs:kd], al
    mov byte [cs:kdr], 0
    mov al, [cs:kbr]
    not al
    and [cs:kb], al
    mov byte [cs:kbr], 0
    call joyp_upd
.norel:
    inc word [cs:frames]
    mov ax, [cs:shotf]         ; -sN: dump the framebuffer at frame N, exit
    or  ax, ax
    jz  .nshot
    cmp [cs:frames], ax
    jb  .nshot
    call save_shot
    jmp exit_shot
.nshot:
    cmp byte [cs:gfxon], 0      ; render every rn-th GB frame
    je  .nr
    mov al, [cs:rn]
    or  al, al
    jz  .nr
    dec byte [cs:rcnt]
    jnz .nr
    mov [cs:rcnt], al
    call render_frame
.nr:
    pop di
    pop dx
    pop cx
    pop bx
    ret

; ==========================================================================
; wr8: DI=GB address, AL=value. Preserves AH and all GB registers.
wr8:
    cmp di, 0x8000
    jb  .ret                    ; ROM / MBC register: no MBC, ignore
    cmp di, 0xE000
    jb  .st                     ; VRAM / (phantom) ext RAM / WRAM
    cmp di, 0xFE00
    jb  .echo
    cmp di, 0xFF00
    jb  .st                     ; OAM + the FEA0 dead zone
    cmp di, 0xFF80
    jb  io_wr
    cmp di, 0xFFFF
    je  .ie
.st:
    cmp di, 0xC000              ; WRAM writes mirror into E000-FDFF so
    jb  .stp                    ; direct READS of echo addresses stay
    cmp di, 0xDE00              ; coherent (games do read the echo -
    jae .stp                    ; Tetris's board logic, for one)
    mov [di], al
    add di, 0x2000
.stp:
    mov [di], al                ; HRAM ends up here too
.ret:
    ret
.ie:
    mov [di], al                ; IE write: a newly-unmasked pending
    call int_poke               ; interrupt fires before the next instr
    ret
.echo:
    mov [di], al
    sub di, 0x2000
    mov [di], al
    ret

io_wr:
    cmp di, 0xFF02
    je  .sc
    cmp di, 0xFF04
    je  .div
    cmp di, 0xFF0F
    je  .if
    cmp di, 0xFF46
    je  .dma
    cmp di, 0xFF45
    je  .lyc
    cmp di, 0xFF47
    je  .bgp
    cmp di, 0xFF48
    je  .obp0
    cmp di, 0xFF49
    je  .obp1
    cmp di, 0xFF50
    je  .b50
    cmp di, 0xFF00
    je  .joyp
    mov [di], al                ; everything else stores plain (LCDC, SCY,
    ret                         ; sound... the renderer reads them back)
.lyc:
    mov [di], al                ; hardware re-checks the coincidence the
    cmp al, [di-1]              ; moment LYC changes (acid2 chains its
    jne .lycn                   ; scanline IRQs that way)
    push ax
    mov al, [di-4]              ; STAT
    or  al, 4
    mov [di-4], al
    test al, 0x40
    jz  .lycp
    or  byte [di-0x36], 2       ; IF |= STAT (dispatched at the next sync:
.lycp:                          ; immediate mid-row IRQs desync acid2)
    pop ax
    ret
.lycn:
    and byte [di-4], 0xFB
    ret
.bgp:
    mov [di], al
    mov byte [cs:bgpdirty], 1
    ret
.obp0:
    mov [di], al
    push bx
    mov bx, obpv0
    call obp_build
    pop bx
    ret
.obp1:
    mov [di], al
    push bx
    mov bx, obpv1
    call obp_build
    pop bx
    ret
.b50:                           ; boot ROM done: restore cart 0000-00FF
    mov [di], al
    push si
    push di
    push cx
    push ds
    push cs
    pop  ds
    mov si, stashbuf
    xor di, di
    mov cx, 128
    rep movsw                   ; CS:stashbuf -> ES(=GBSEG):0
    pop ds
    pop cx
    pop di
    pop si
    ret
.sc:                            ; serial: internal-clock transfers take ~9
    test al, 0x80               ; scanlines (~4096 cyc), then complete in
    jz  .scst                   ; do_sync. External clock with no cable
    test al, 0x01               ; NEVER completes (SC stays busy) - Tetris
    jz  .scst                   ; arms one per title frame and an IRQ storm
    mov byte [cs:serialcnt], 10 ; here walks it into phantom 2P mode.
    cmp byte [cs:serfile], 0
    je  .nsf
    push ax                     ; -o: append the SB byte to GBOUT.TXT
    push bx                     ; (DS=GBSEG, so DX=FF01 addresses SB
    push cx                     ; directly); dup+close flushes the dir
    push dx                     ; entry so the log survives an external
    mov ah, 0x40                ; kill of the emulator process
    mov bx, [cs:sfh]
    mov cx, 1
    mov dx, 0xFF01
    int 0x21
    mov ah, 0x45
    mov bx, [cs:sfh]
    int 0x21
    jc  .nfl
    mov bx, ax
    mov ah, 0x3E
    int 0x21
.nfl:
    pop dx
    pop cx
    pop bx
    pop ax
.nsf:
    cmp byte [cs:gfxon], 0      ; In text mode SB still echoes to the DOS
    jne .scst                   ; console for Blargg's ROMs.
    push ax
    push dx
    mov dl, [di-1]              ; SB
    cmp dl, 10
    jne .nolf
    push dx
    mov dl, 13
    mov ah, 2
    int 0x21
    pop dx
.nolf:
    mov ah, 2
    int 0x21
    pop dx
    pop ax
.scst:
    mov [di], al
    ret
.div:
    mov byte [di], 0            ; any write resets DIV
    mov word [cs:divacc], 0
    ret
.if:
    or  al, 0xE0
    mov [di], al                ; IF write with IME on: service now (the
    call int_poke               ; 02-interrupts ROM checks the pushed PC)
    ret
.dma:                           ; OAM DMA: 160 bytes from AL<<8 to FE00
    push ax
    push cx
    push si
    push di
    mov ah, al
    mov al, 0
    mov si, ax
    mov di, 0xFE00
    mov cx, 80
    rep movsw
    pop di
    pop si
    pop cx
    pop ax
    mov [di], al
    ret
.joyp:
    push ax
    and al, 0x30                ; latch the select lines, then rebuild the
    mov [cs:joypsel], al        ; readable JOYP byte from live key state
    call joyp_upd
    pop ax
    ret

; ==========================================================================
; int_poke: immediate interrupt dispatch, called wherever the guest can
; make an interrupt due mid-scanline (IF/IE writes, RETI). SI is already
; the address of the next instruction, which is exactly the PC to push.
; Preserves AX (incl. the live flag byte in AH) and all GB registers.
int_poke:
    cmp byte [cs:ime], 0
    je  .no
    push ax
    mov di, 0xFF0F
    mov al, [di]
    and al, [di+0x00F0]         ; IE
    and al, 0x1F
    jz  .pop
    mov byte [cs:ime], 0
    mov byte [cs:halted], 0
    mov ah, 0x01
    mov di, 0x0040
    test al, ah
    jnz .s
    mov ah, 0x02
    mov di, 0x0048
    test al, ah
    jnz .s
    mov ah, 0x04
    mov di, 0x0050
    test al, ah
    jnz .s
    mov ah, 0x08
    mov di, 0x0058
    test al, ah
    jnz .s
    mov ah, 0x10
    mov di, 0x0060
.s:
    not ah
    push bx
    mov bx, 0xFF0F
    and [bx], ah
    pop bx
    dec bp
    dec bp
    mov [ds:bp], si
    mov si, di
    sub word [cs:slcyc], 20
    cmp si, 0x0040
    jne .p40
    inc word [cs:d40]
.p40:
    cmp si, 0x0058
    jne .p58
    inc word [cs:d58]
.p58:
.pop:
    pop ax
.no:
    ret

; ==========================================================================
; render_frame: paint the BG (160x144, centered) into CGA 320x200x4.
; Called from frame_tick, which saved AX/BX/CX/DX/DI; BP is never touched.
; DS stays GBSEG for VRAM reads; rowbuf/LUTs live in CS; CGA via ES=B800.
render_frame:
    push si
    push ds
    push es
    cmp byte [cs:bgpdirty], 0
    je  .lutok
    call build_bgplut
.lutok:
    mov byte [cs:wline], 0      ; window internal line counter
    mov byte [cs:r_y], 0
.rowl:
    mov al, [cs:r_y]            ; per-row registers from the scanline log
    mov ah, 0
    mov si, ax
    shl si, 1
    shl si, 1
    shl si, 1
    mov al, [cs:slog+si]
    mov [cs:r_lcdc], al
    mov ah, [cs:slog+si+1]
    mov [cs:r_scy], ah
    mov ah, [cs:slog+si+2]
    mov [cs:r_scx], ah
    mov ah, [cs:slog+si+3]
    mov [cs:r_wy], ah
    mov ah, [cs:slog+si+4]
    mov [cs:r_wx], ah
    test al, 0x80               ; LCD off this row -> white
    jz  .whiterow
    test al, 0x01               ; BG+window disabled -> white (OBJ later)
    jz  .whiterow
    mov dx, 0x9800
    test al, 0x08
    jz  .mb
    mov dx, 0x9C00
.mb:
    mov [cs:r_mapb], dx
    mov al, [cs:r_y]            ; sy = (y + SCY) & 255
    add al, [cs:r_scy]
    mov ah, 0
    mov si, ax
    and si, 7
    shl si, 1
    mov [cs:r_trow], si         ; byte offset of the row inside a tile
    mov cl, 3
    shr ax, cl
    mov cl, 5
    shl ax, cl                  ; (sy>>3)*32
    add ax, [cs:r_mapb]
    mov [cs:r_mapr], ax
    mov al, [cs:r_scx]
    mov cl, 3
    shr al, cl
    mov ah, 0
    mov [cs:r_col], ax          ; coarse start column
    mov di, rowbuf
    mov cx, 22                  ; 22 tiles cover 160 px at any fine scroll
.tilel:
    mov si, [cs:r_mapr]
    add si, [cs:r_col]
    mov bl, [si]                ; tile index
    mov ax, [cs:r_col]
    inc ax
    and ax, 31
    mov [cs:r_col], ax
    mov bh, 0
    test byte [cs:r_lcdc], 0x10
    jnz .uns
    xor bl, 0x80                ; signed 8800-mode == unsigned from 0x8800
    mov ax, 0x8800
    jmp .ta
.uns:
    mov ax, 0x8000
.ta:
    shl bx, 1
    shl bx, 1
    shl bx, 1
    shl bx, 1
    add ax, bx
    add ax, [cs:r_trow]
    mov si, ax
    lodsw                       ; AL=plane0, AH=plane1
    mov bl, al
    mov bh, 0
    shl bx, 1
    mov dx, [cs:spread0+bx]
    mov bl, ah
    mov bh, 0
    shl bx, 1
    or  dx, [cs:spread1+bx]     ; packed colour indices, 8 px
    mov bl, dl
    mov bh, 0
    mov dl, [cs:bgplut+bx]      ; BGP + shade->CGA-v mapping per byte
    mov bl, dh
    mov dh, [cs:bgplut+bx]
    mov [cs:di], dx
    inc di
    inc di
    loop .tilel
    call row_out
    test byte [cs:r_lcdc], 0x20 ; window on this row?
    jz  .nextrow
    mov al, [cs:r_y]
    cmp al, [cs:r_wy]
    jb  .nextrow
    call win_row
    jmp .nextrow
.whiterow:
    call row_addr
    mov al, 0xFF                ; v3 = white
    mov cx, 40
    rep stosb
.nextrow:
    inc byte [cs:r_y]
    cmp byte [cs:r_y], 144
    jb  .rowl
    call spr_pass               ; per-row OBJ gating happens inside
.done:
    pop es
    pop ds
    pop si
    ret

row_addr:                       ; ES:DI = CGA address of GB row r_y, col 0
    mov al, [cs:r_y]
    add al, 28                  ; (200-144)/2
    mov ah, 0
    mov di, 0
    shr ax, 1
    jnc .even
    mov di, 0x2000              ; odd scanlines: second CGA bank
.even:
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    mov cx, ax
    shl ax, 1
    shl ax, 1
    add ax, cx                  ; *80
    add di, ax
    add di, 20                  ; (320-160)/2 px = 20 bytes
    mov ax, 0xB800
    mov es, ax
    ret

row_out:                        ; rowbuf -> CGA, shifted by SCX&7 pixels.
    call row_addr               ; 2*fine can pass 8 bits, so absorb whole
    mov si, rowbuf              ; bytes into the start pointer first and
    mov al, [cs:r_scx]          ; keep the residual shift <= 6 bits
    and al, 7
    cmp al, 4
    jb  .k0
    inc si
.k0:
    mov cl, al
    shl cl, 1
    and cl, 7
    jz  .fast
    mov dl, 40
.sl:
    mov ax, [cs:si]
    xchg al, ah                 ; AX = buf[i]:buf[i+1] big-endian
    shl ax, cl
    mov [es:di], ah
    inc di
    inc si
    dec dl
    jnz .sl
    ret
.fast:
    mov cx, 20
    push ds
    push cs
    pop  ds
    rep movsw
    pop ds
    ret

build_bgplut:                   ; BGP (FF47) -> 256-byte packed-pixel LUT
    mov byte [cs:bgpdirty], 0
    mov dl, [0xFF47]
    mov di, 0
.p4:                            ; pal4[idx] = shade2v[(BGP>>2idx)&3]
    mov bl, dl
    and bl, 3
    mov bh, 0
    mov al, [cs:shade2v+bx]
    mov [cs:pal4+di], al
    inc di
    shr dl, 1
    shr dl, 1
    cmp di, 4
    jb  .p4
    xor bx, bx
.pb:                            ; expand to every possible packed byte
    mov dh, 0
    mov dl, bl
    mov cx, 4
.pf:
    shl dh, 1
    shl dh, 1
    rol dl, 1
    rol dl, 1
    mov al, dl
    and al, 3
    push bx
    mov bh, 0
    mov bl, al
    mov al, [cs:pal4+bx]
    pop bx
    or  dh, al
    loop .pf
    mov [cs:bgplut+bx], dh
    inc bx
    cmp bx, 256
    jb  .pb
    ret

save_shot:                      ; dump the live CGA framebuffer (B800:0000,
    push cs                     ; 16 KB = two 8000-byte banks) to GBSHOT.RAW.
    pop  ds                     ; Called while still in graphics mode, so it
    mov dx, shotname            ; captures exactly what the display shows;
    xor cx, cx                  ; test/raw2png.py + the CGA palette turn it
    mov ah, 0x3C                ; into a PNG on the host.
    int 0x21
    jc  .done
    mov bx, ax
    mov ax, 0xB800
    mov ds, ax
    xor dx, dx
    mov cx, 0x4000
    mov ah, 0x40
    int 0x21
    mov ah, 0x3E
    int 0x21
.done:
    ret

restore_txt:                    ; undo our system hooks: INT 9 vector first,
    cmp byte [cs:hooked], 0     ; then back to 80x25 text
    je  .nv
    mov byte [cs:hooked], 0
    push es
    xor ax, ax
    mov es, ax
    cli
    mov ax, [cs:old9o]
    mov [es:0x24], ax
    mov ax, [cs:old9s]
    mov [es:0x26], ax
    sti
    pop es
.nv:
    cmp byte [cs:gfxon], 0
    je  .n
    mov byte [cs:gfxon], 0
    mov ax, 0x0003
    int 0x10
.n: ret

install9:                       ; hook IRQ1 so we see key make/break codes
    push es
    xor ax, ax
    mov es, ax
    mov ax, [es:0x24]
    mov [cs:old9o], ax
    mov ax, [es:0x26]
    mov [cs:old9s], ax
    cli
    mov word [es:0x24], int9h
    mov [es:0x26], cs
    sti
    pop es
    mov byte [cs:hooked], 1
    ret

int9h:                          ; arrows=dpad, A/X=A, B/Z=B, Bksp/Space=
    push ax                     ; Select, Enter=Start, ESC=quit. All keys
    push bx                     ; swallowed (no BIOS chain): an INT 16h
    in  al, 0x60                ; call anywhere would steal the host's
    mov ah, al                  ; type-ahead from the scancode pump
    and al, 0x7F
    cmp al, 0x01                ; ESC
    jne .nesc
    mov byte [cs:escflag], 1
.nesc:
    mov bl, 1
    cmp al, 0x4D                ; right
    je  .dp
    mov bl, 2
    cmp al, 0x4B                ; left
    je  .dp
    mov bl, 4
    cmp al, 0x48                ; up
    je  .dp
    mov bl, 8
    cmp al, 0x50                ; down
    je  .dp
    mov bl, 1
    cmp al, 0x1E                ; A -> A
    je  .bt
    cmp al, 0x2D                ; X -> A
    je  .bt
    mov bl, 2
    cmp al, 0x30                ; B -> B
    je  .bt
    cmp al, 0x2C                ; Z -> B
    je  .bt
    mov bl, 4
    cmp al, 0x0E                ; Backspace -> Select
    je  .bt
    cmp al, 0x39                ; Space -> Select
    je  .bt
    mov bl, 8
    cmp al, 0x1C                ; Enter -> Start
    je  .bt
    jmp .out
.dp:
    test ah, 0x80
    jnz .dpu
    or  [cs:kd], bl
    not bl
    and [cs:kdr], bl
    jmp .upd
.dpu:
    or  [cs:kdr], bl            ; releases are deferred to the next frame
    jmp .out                    ; tick so even sub-frame taps span a poll
.bt:
    test ah, 0x80
    jnz .btu
    or  [cs:kb], bl
    not bl
    and [cs:kbr], bl
    jmp .upd
.btu:
    or  [cs:kbr], bl
    jmp .out
.upd:
    call joyp_upd
.out:
    in  al, 0x61                ; XT keyboard ack + EOI, then done -
    mov ah, al                  ; the BIOS never sees the key
    or  al, 0x80
    out 0x61, al
    mov al, ah
    out 0x61, al
    mov al, 0x20
    out 0x20, al
    pop bx
    pop ax
    iret

joyp_upd:                       ; GB FF00 = select bits + live key nibble
    push ax
    push bx
    push di
    push ds
    mov ds, [cs:gbseg]
    mov di, 0xFF00
    mov al, [cs:joypsel]
    mov bl, 0x0F
    test al, 0x10               ; P14 low: dpad selected
    jnz .nd
    mov bh, [cs:kd]
    not bh
    and bl, bh
.nd:
    test al, 0x20               ; P15 low: buttons selected
    jnz .nb
    mov bh, [cs:kb]
    not bh
    and bl, bh
.nb:
    or  al, 0xC0
    or  al, bl
    mov [di], al
    pop ds
    pop di
    pop bx
    pop ax
    ret

obp_build:                      ; AL = OBP byte -> 4-byte shade table at
    push ax                     ; CS:BX (index 0 unused: colour 0 is
    push bx                     ; transparent for sprites)
    push cx
    push dx
    mov dl, al
    mov cx, 4
.ob:
    mov al, dl
    and al, 3
    push bx
    mov bh, 0
    mov bl, al
    mov al, [cs:shade2v+bx]
    pop bx
    mov [cs:bx], al
    inc bx
    shr dl, 1
    shr dl, 1
    loop .ob
    pop dx
    pop cx
    pop bx
    pop ax
    ret

plot_px:                        ; ES:DI = CGA row base (GB col 0),
    push ax                     ; BX = GB x, AL = CGA v. Preserves all.
    push cx
    push bx
    mov cl, bl
    and cl, 3
    shl cl, 1
    mov ch, 6
    sub ch, cl
    mov cl, ch                  ; bit position of the pixel pair
    shr bx, 1
    shr bx, 1
    mov ah, 3
    shl ah, cl
    shl al, cl
    not ah
    and [es:bx+di], ah
    or  [es:bx+di], al
    pop bx
    pop cx
    pop ax
    ret

win_row:                        ; window tiles for row r_y, fed by the
    mov al, [cs:r_wx]           ; internal wline counter (increments only
    cmp al, 7                   ; on rows where the window really drew)
    jae .wx
    mov al, 7
.wx:
    sub al, 7
    cmp al, 160
    jae .ret
    mov [cs:w_x0], al
    mov dx, 0x9800
    test byte [cs:r_lcdc], 0x40
    jz  .mb
    mov dx, 0x9C00
.mb:
    mov [cs:w_map], dx
    mov al, [cs:wline]
    mov ah, 0
    mov si, ax
    and si, 7
    shl si, 1
    mov [cs:w_trow], si
    mov cl, 3
    shr ax, cl
    mov cl, 5
    shl ax, cl
    add ax, [cs:w_map]
    mov [cs:w_mapr], ax
    call row_addr
    mov bl, [cs:w_x0]
    mov bh, 0
    mov word [cs:w_tc], 0
.tl:
    mov si, [cs:w_mapr]
    add si, [cs:w_tc]
    push bx
    mov bl, [si]
    mov bh, 0
    test byte [cs:r_lcdc], 0x10
    jnz .u
    xor bl, 0x80
    mov ax, 0x8800
    jmp .t
.u:
    mov ax, 0x8000
.t:
    shl bx, 1
    shl bx, 1
    shl bx, 1
    shl bx, 1
    add ax, bx
    add ax, [cs:w_trow]
    mov si, ax
    pop bx
    lodsw                       ; AL=plane0, AH=plane1
    mov dl, al
    mov dh, ah
    mov cx, 8
.px:
    shl dh, 1
    mov al, 0
    adc al, 0
    shl dl, 1
    adc al, al                  ; colour index
    push bx
    mov bh, 0
    mov bl, al
    mov al, [cs:pal4+bx]
    pop bx
    call plot_px
    inc bx
    cmp bx, 160
    jae .rowdone
    loop .px
    inc word [cs:w_tc]
    cmp word [cs:w_tc], 32
    jae .rowdone
    jmp .tl
.rowdone:
    inc byte [cs:wline]
.ret:
    ret

spr_pass:                       ; OBJ layer, drawn per-pixel post-palette
    push es                     ; clear the per-scanline object counters
    push cs                     ; (hardware takes the first 10 per line in
    pop  es                     ; OAM order and drops the rest)
    mov di, s_rowcnt
    mov cx, 72
    xor ax, ax
    rep stosw
    pop es
    mov byte [cs:s_h], 8
    mov al, [0xFF40]
    test al, 0x04
    jz  .h8
    mov byte [cs:s_h], 16
.h8:
    mov word [cs:s_oam], 0xFE00
.spl:
    mov si, [cs:s_oam]
    mov al, [si+3]
    mov [cs:s_attr], al
    mov al, [si+2]
    cmp byte [cs:s_h], 16
    jne .t8
    and al, 0xFE                ; 8x16: even tile number
.t8:
    mov [cs:s_tile], al
    mov byte [cs:s_r], 0
.rowl:
    mov al, [si]                ; OAM Y (screen y + 16)
    mov ah, 0
    add al, [cs:s_r]
    adc ah, 0
    sub ax, 16
    jc  .nextrow                ; above the screen
    cmp ax, 144
    jae .nextrow
    mov [cs:r_y], al
    push bx
    mov bl, al
    mov bh, 0
    mov ah, [cs:s_rowcnt+bx]    ; 10-per-line limit, counted per selected
    inc byte [cs:s_rowcnt+bx]   ; sprite row whether or not pixels land
    shl bx, 1
    shl bx, 1
    shl bx, 1
    mov al, [cs:slog+bx]        ; this row's LCDC: LCD + OBJ enable
    pop bx
    cmp ah, 10
    jae .nextrow
    test al, 0x80
    jz  .nextrow
    test al, 0x02
    jz  .nextrow
    ; fetch the tile row (respecting Y flip)
    mov al, [cs:s_r]
    test byte [cs:s_attr], 0x40
    jz  .nyf
    mov ah, [cs:s_h]
    dec ah
    sub ah, al
    mov al, ah
.nyf:
    mov ah, 0
    shl ax, 1
    mov dx, ax                  ; row*2
    mov al, [cs:s_tile]
    mov ah, 0
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    add ax, dx
    add ax, 0x8000
    push si
    mov si, ax
    lodsw                       ; AL=plane0, AH=plane1
    pop si
    test byte [cs:s_attr], 0x20
    jz  .nxf
    push bx                     ; X flip: reverse both plane bytes
    mov bl, al
    mov bh, 0
    mov al, [cs:bitrev+bx]
    mov bl, ah
    mov ah, [cs:bitrev+bx]
    pop bx
.nxf:
    mov dl, al
    mov dh, ah
    call row_addr               ; ES:DI row base (clobbers AX,CX)
    mov cx, 8
.px:
    shl dh, 1
    mov al, 0
    adc al, 0
    shl dl, 1
    adc al, al                  ; colour index; 0 = transparent
    or  al, al
    jz  .nextpx
    ; x = OAM X - 8 + (pixel index)
    mov bl, [si+1]
    mov bh, 0
    add bx, 8
    sub bx, cx                  ; +(8-cx) = pixel 0..7
    sub bx, 8                   ; -8 OAM bias
    jc  .nextpx
    cmp bx, 160
    jae .nextpx
    ; behind-BG priority: only draw over BG colour 0
    test byte [cs:s_attr], 0x80
    jz  .pal
    push cx
    push bx
    mov cl, bl
    and cl, 3
    shl cl, 1
    mov ch, 6
    sub ch, cl
    mov cl, ch
    shr bx, 1
    shr bx, 1
    mov ah, [es:bx+di]
    shr ah, cl
    and ah, 3
    pop bx
    pop cx
    cmp ah, [cs:pal4]           ; BG colour 0's CGA value
    jne .nextpx
.pal:
    push bx
    mov bh, 0
    mov bl, al
    test byte [cs:s_attr], 0x10
    jnz .p1
    mov al, [cs:obpv0+bx]
    jmp .pw
.p1:
    mov al, [cs:obpv1+bx]
.pw:
    pop bx
    call plot_px
.nextpx:
    loop .px
.nextrow:
    inc byte [cs:s_r]
    mov al, [cs:s_r]
    cmp al, [cs:s_h]
    jb  .rowl
    add word [cs:s_oam], 4
    cmp word [cs:s_oam], 0xFEA0
    jb  .spl
    ret

; ==========================================================================
; GB F <-> LAHF-format conversion (only PUSH/POP AF and DAA care).
mkF:                            ; AH: flags86 -> GB F byte, AL preserved
    mov byte [cs:fb], 0
    test ah, 0x40
    jz  .a
    or  byte [cs:fb], 0x80
.a: test ah, 0x08
    jz  .b
    or  byte [cs:fb], 0x40
.b: test ah, 0x10
    jz  .c
    or  byte [cs:fb], 0x20
.c: test ah, 0x01
    jz  .d
    or  byte [cs:fb], 0x10
.d: mov ah, [cs:fb]
    ret

unmkF:                          ; AH: GB F byte -> flags86, AL preserved
    mov byte [cs:fb], 0
    test ah, 0x80
    jz  .a
    or  byte [cs:fb], 0x40
.a: test ah, 0x40
    jz  .b
    or  byte [cs:fb], 0x08
.b: test ah, 0x20
    jz  .c
    or  byte [cs:fb], 0x10
.c: test ah, 0x10
    jz  .d
    or  byte [cs:fb], 0x01
.d: mov ah, [cs:fb]
    ret

; ==========================================================================
; Irregular opcodes (the dispatch tables in sm83.inc point here).
o_nop:
    jmp epi4

o_stop:
    inc si                      ; skip the padding byte
    jmp exit_stop

o_halt:
    mov byte [cs:halted], 1
    jmp do_sync                 ; sync absorbs the rest of the scanline

o_di:
    mov byte [cs:ime], 0
    jmp epi4

o_ei:                           ; takes effect after ONE more instruction:
    mov byte [cs:ime], 1        ; plant slcyc=3 so the next epilogue goes
    mov di, [cs:slcyc]          ; negative and do_sync's eihack path
    sub di, 4                   ; restores the borrowed remainder
    mov [cs:slsave], di
    mov word [cs:slcyc], 3
    mov byte [cs:eihack], 1
    jmp fetch

o_cpl:
    not al
    or  ah, 0x18                ; N=1 H=1, Z/C unchanged
    jmp epi4

o_scf:
    and ah, 0x40
    or  ah, 1
    jmp epi4

o_ccf:
    and ah, 0x41
    xor ah, 1
    jmp epi4

o_daa:
    mov [cs:tmp8], ah           ; N=bit3 H=bit4 C=bit0
    mov byte [cs:fb], 0         ; BCD adjust amount
    test ah, 0x10
    jz  .noh
    mov byte [cs:fb], 6
.noh:
    test byte [cs:tmp8], 8
    jnz .subp
    push ax                     ; --- after an addition
    and al, 0x0F
    cmp al, 9
    pop ax
    jbe .lo
    or  byte [cs:fb], 6
.lo:
    test byte [cs:tmp8], 1
    jnz .cs
    cmp al, 0x99
    jbe .hi
.cs:
    or  byte [cs:fb], 0x60
.hi:
    add al, [cs:fb]
    jmp .fl
.subp:                          ; --- after a subtraction
    test byte [cs:tmp8], 1
    jz  .snc
    or  byte [cs:fb], 0x60
.snc:
    sub al, [cs:fb]
.fl:                            ; Z from result, N kept, H=0, C if 0x60 used
    mov ah, 0
    or  al, al
    jnz .nz
    or  ah, 0x40
.nz:
    test byte [cs:tmp8], 8
    jz  .nn
    or  ah, 8
.nn:
    test byte [cs:fb], 0x60
    jz  .nc
    or  ah, 1
.nc:
    jmp epi4

o_jp:
    mov si, [si]
    jmp epi16

o_jr:
    xchg ax, di
    lodsb
    cbw
    add si, ax
    xchg ax, di
    jmp jr_taken

; -f spin-skip: games that busy-poll a flag instead of HALTing (Tetris's
; wait-for-VBlank) burn a full frame of host work per GB frame. When the
; same backward JR keeps hitting, charge the rest of the scanline per
; iteration - the loop still executes, interrupts still fire, but idle
; time costs ~1 iteration per scanline instead of ~30.
jr_taken:
    cmp byte [cs:fastspin], 0
    je  epi12
    cmp si, [cs:lastjr]
    je  .same
    mov [cs:lastjr], si
    mov byte [cs:spincnt], 0
    jmp epi12
.same:
    cmp byte [cs:spincnt], 32
    jae .skip
    inc byte [cs:spincnt]
    jmp epi12
.skip:
    mov word [cs:slcyc], 3
    jmp epi12

o_jp_hl:
    mov si, bx
    jmp epi4

o_call:
    mov di, [si]
    inc si
    inc si
    dec bp
    dec bp
    mov [ds:bp], si
    mov si, di
    jmp epi24

o_ret:
    mov si, [ds:bp]
    inc bp
    inc bp
    jmp epi16

o_reti:
    mov si, [ds:bp]
    inc bp
    inc bp
    mov byte [cs:ime], 1
    call int_poke               ; pending IRQ resumes before the next instr
    jmp epi16

o_push_af:
    mov [cs:tmpw], ax
    call mkF
    xchg al, ah                 ; word = A:F (F in the low byte)
    dec bp
    dec bp
    mov [ds:bp], ax
    mov ax, [cs:tmpw]
    jmp epi16

o_pop_af:
    mov ax, [ds:bp]
    inc bp
    inc bp
    xchg al, ah                 ; AL=A, AH=F (low nibble drops out here:
    call unmkF                  ; unmkF only reads bits 7-4)
    jmp epi12

o_ld_sp_hl:
    mov bp, bx
    jmp epi8

o_ld_a16_sp:
    mov di, [si]
    inc si
    inc si
    push ax
    mov ax, bp
    push di
    call wr8                    ; SP low
    pop di
    inc di
    mov al, ah
    call wr8                    ; SP high
    pop ax
    jmp epi20

o_add_sp_r8:                    ; Z=0 N=0, H/C from the LOW byte add
    push cx
    mov cl, [si]
    inc si
    mov [cs:tmpw], ax
    mov ax, bp
    add al, cl
    lahf
    and ah, 0x11
    mov [cs:tmp8], ah
    mov ch, 0
    test cl, 0x80
    jz  .p
    mov ch, 0xFF
.p:
    add bp, cx
    mov ax, [cs:tmpw]
    mov ah, [cs:tmp8]
    pop cx
    jmp epi16

o_ld_hl_spr8:                   ; same flags, result to HL
    push cx
    mov cl, [si]
    inc si
    mov [cs:tmpw], ax
    mov ax, bp
    add al, cl
    lahf
    and ah, 0x11
    mov [cs:tmp8], ah
    mov ch, 0
    test cl, 0x80
    jz  .p
    mov ch, 0xFF
.p:
    mov bx, bp
    add bx, cx
    mov ax, [cs:tmpw]
    mov ah, [cs:tmp8]
    pop cx
    jmp epi12

o_ld_a16_a:
    mov di, [si]
    inc si
    inc si
    call wr8
    jmp epi16

o_ld_a_a16:
    mov di, [si]
    inc si
    inc si
    mov al, [di]
    jmp epi16

o_ldh_a8_a:
    mov di, [si]
    inc si
    and di, 0x00FF
    add di, 0xFF00
    call wr8
    jmp epi12

o_ldh_a_a8:
    mov di, [si]
    inc si
    and di, 0x00FF
    add di, 0xFF00
    mov al, [di]
    jmp epi12

o_ldh_c_a:
    mov di, cx
    and di, 0x00FF
    add di, 0xFF00
    call wr8
    jmp epi8

o_ldh_a_c:
    mov di, cx
    and di, 0x00FF
    add di, 0xFF00
    mov al, [di]
    jmp epi8

o_cb:
    mov di, [si]                ; same no-lodsb rule as fetch
    inc si
    and di, 0x00FF
    shl di, 1
    jmp word [cs:cbtab+di]

o_illegal:
    dec si                      ; SI-1 = the offending byte
    call restore_txt
    push cs
    pop  ds
    mov dx, m_ill
    mov ah, 9
    int 0x21
    mov al, [es:si]             ; ES still = GBSEG
    call phex8
    mov dx, m_at
    mov ah, 9
    int 0x21
    mov ax, si
    call phex16
    mov ax, 0x4C01
    int 0x21

; ==========================================================================
; Exits and errors
exit_shot:
    call restore_txt
    push cs
    pop  ds
    mov dx, m_shot
    jmp exit_msg
exit_stop:
    call restore_txt
    push cs
    pop  ds
    mov dx, m_stop
    jmp exit_msg
exit_esc:
    call restore_txt
    push cs
    pop  ds
    mov dx, m_esc
exit_msg:
    mov ah, 9
    int 0x21
    mov ax, [cs:frames]
    call pdec
    mov dl, '/'
    mov ah, 2
    int 0x21
    mov ax, [cs:d40]            ; frames/VBlank-IRQs/serial-IRQs
    call pdec
    mov dl, '/'
    mov ah, 2
    int 0x21
    mov ax, [cs:d58]
    call pdec
    mov dx, m_frames
    mov ah, 9
    int 0x21
    mov ax, 0x4C00
    int 0x21

err_usage:
    mov dx, m_usage
    jmp err_out
err_open:
    mov dx, m_open
    jmp err_out
err_read:
    mov dx, m_read
    jmp err_out
err_big:
    mov dx, m_big
    jmp err_out
err_boot:
    mov dx, m_boot
    jmp err_out
err_mem:
    mov dx, m_mem
err_out:
    push cs
    pop  ds
    mov ah, 9
    int 0x21
    mov ax, 0x4C01
    int 0x21

; ---- tiny printers (exit paths only; AX free there)
phex16:
    push ax
    mov al, ah
    call phex8
    pop ax
phex8:
    push ax
    push cx
    mov cl, 4
    shr al, cl
    call .nib
    pop cx
    pop ax
    push ax
    and al, 0x0F
    call .nib
    pop ax
    ret
.nib:
    add al, 0x90
    daa
    adc al, 0x40
    daa
    push dx
    mov dl, al
    mov ah, 2
    int 0x21
    pop dx
    ret

pdec:                           ; print AX in decimal
    push ax
    push cx
    push dx
    mov cx, 0
    mov di, 10
.dv:
    xor dx, dx
    div di
    push dx
    inc cx
    or  ax, ax
    jnz .dv
.pr:
    pop dx
    add dl, '0'
    mov ah, 2
    int 0x21
    loop .pr
    pop dx
    pop cx
    pop ax
    ret

; ==========================================================================
%include "sm83.inc"

; ==========================================================================
m_usage:  db "usage: GB [-t] [-b] [-f] [-o] [-rN] ROMFILE.GB (32 KB, no-MBC)"
          db 13, 10
          db "  -t   text mode, never render   -b  run DMGBOOT.BIN first"
          db 13, 10
          db "  -rN  render every N GB frames (default 6, 0=never)"
          db 13, 10
          db "  -o   log serial output to GBOUT.TXT (for test rigs)"
          db 13, 10
          db "  -sN  dump the CGA frame to GBSHOT.RAW at frame N, then exit"
          db 13, 10
          db "  -f   skip busy-wait loops (warps timers/serial: breaks"
          db 13, 10
          db "       link-sensitive games like Tetris; capture use only)"
          db 13, 10
          db "  keys: arrows=dpad  A/X=A  B/Z=B  Bksp/Space=Select"
          db 13, 10
          db "        Enter=Start  ESC=quit"
          db 13, 10, "$"
m_open:   db "cannot open ROM", 13, 10, "$"
m_read:   db "cannot read ROM (or not a GB ROM)", 13, 10, "$"
m_big:    db "ROM larger than 32 KB: MBC carts not supported", 13, 10, "$"
m_mem:    db "not enough memory (need 64 KB free)", 13, 10, "$"
m_boot:   db "cannot read DMGBOOT.BIN (need 256 bytes)", 13, 10, "$"
m_ill:    db 13, 10, "illegal SM83 opcode $"
m_at:     db " at PC=$"
m_stop:   db 13, 10, "STOP executed. $"
m_esc:    db 13, 10, "ESC. $"
m_shot:   db 13, 10, "GBSHOT.RAW written. $"
m_frames: db " GB frames run.", 13, 10, "$"

gbseg:   dw 0
slcyc:   dw 0
slsave:  dw 0
divacc:  dw 0
timacc:  dw 0
frames:  dw 0
tmpw:    dw 0
tmp8:    db 0
fb:      db 0
ime:     db 0
halted:  db 0
eihack:  db 0
serialcnt: db 0
d40:     dw 0
d58:     dw 0
fastspin: db 0
lastjr:  dw 0
spincnt: db 0
serfile: db 0
sfh:     dw 0
sername: db "GBOUT.TXT", 0
shotf:   dw 0
shotname: db "GBSHOT.RAW", 0
ratetab: dw 1024, 16, 64, 256
textmode: db 0
useboot:  db 0
gfxon:    db 0
rn:       db 6
rcnt:     db 1
bgpdirty: db 1
r_lcdc:   db 0
r_scy:    db 0
r_scx:    db 0
r_wy:     db 0
r_wx:     db 0
r_y:      db 0
wline:    db 0
slog:     times 144*8 db 0
r_mapb:   dw 0
r_mapr:   dw 0
r_trow:   dw 0
r_col:    dw 0
shade2v:  db 3, 1, 2, 0
pal4:     times 4 db 0
obpv0:    times 4 db 0
obpv1:    times 4 db 0
old9o:    dw 0
old9s:    dw 0
hooked:   db 0
escflag:  db 0
kd:       db 0
kb:       db 0
kdr:      db 0
kbr:      db 0
joypsel:  db 0x30
w_x0:     db 0
w_map:    dw 0
w_mapr:   dw 0
w_trow:   dw 0
w_tc:     dw 0
s_oam:    dw 0
s_h:      db 0
s_r:      db 0
s_tile:   db 0
s_attr:   db 0
s_rowcnt: times 144 db 0
bgplut:   times 256 db 0
rowbuf:   times 44 db 0
bootname: db "DMGBOOT.BIN", 0
bootbuf:  times 256 db 0
stashbuf: times 256 db 0
namebuf: times 80 db 0
         align 2
         times 256 dw 0
stktop:
progend:
PROGPARA equ ((progend - $$) + 0x100 + 15) >> 4
