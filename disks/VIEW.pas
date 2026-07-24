program View;
{ VIEW - a BMP/PCX viewer for snes86 (or any CGA PC).
  Usage:  VIEW picture.bmp        640x200 mono, ordered dither (CGA mode 6)
          VIEW picture.pcx 4      320x200 four-colour dither  (CGA mode 4)
          VIEW *.BMP              slideshow: any key advances, ESC quits
  Any key exits. On the SNES, L/R pan the 512px window across the 640.

  Reads 8-bit palettised, 24-bit and 32-bit uncompressed BMPs (top-down
  or bottom-up) and 8-bit RLE PCX, up to 2048 pixels wide. Rows are
  streamed strictly forward in whatever order the file stores them
  (Turbo Pascal 3 has no 32-bit integers, so there are no big seeks),
  read in buffer-sized batches, scaled with integer steppers, and
  dithered/packed/blitted by hand-written 8086 machine code - see
  tools/mkviewasm.py for the inline() blocks. }

const
  { 4x4 ordered-dither thresholds: canonical Bayer * 16 + 7 }
  Bayer: array[0..3, 0..3] of Integer =
    ((7, 135, 39, 167),
     (199, 71, 231, 103),
     (55, 183, 23, 151),
     (247, 119, 215, 87));
  { r*4+g*2+b after per-channel threshold -> CGA palette-1 colour }
  ColorMap: array[0..7] of Byte = (0, 2, 1, 1, 2, 2, 3, 3);
  BufMax = 8191;

type
  Str80 = string[80];
  Regs = record
    AX, BX, CX, DX, BP, SI, DI, DS, ES, Flags: Integer;
  end;

var
  R: Regs;
  Handle: Integer;
  FName: string[78];
  Nm: string[79];
  Pattern: string[78];
  Prefix: string[78];
  SName: string[16];
  EMsg: Str80;
  Hdr: array[0..137] of Byte;
  DTA: array[0..42] of Byte;          { FindFirst state; name at 30 }
  Pal: array[0..255, 0..2] of Byte;   { palette: B,G,R }
  Lum: array[0..255] of Byte;         { per-palette-index luminance }
  IdTab: array[0..255] of Byte;       { identity for pre-lumified rows }
  LumRow: array[0..2047] of Byte;     { 24/32bpp luma rows + PCX rows }
  LumTgt: array[0..511] of Byte;      { pass A output: scaled luma row }
  ThrTab: array[0..3, 0..511] of Byte; { Bayer expanded per row phase }
  { state for the inline loops. Globals, deliberately: TP3 keeps SS <> DS,
    so locals (SS:[BP+x]) are invisible to DS-relative machine code }
  VSrc, VDst, VCnt, VSw, VTw, VErr, VLut, VThrRow, VBlt: Integer;
  PSrc, PSrcEnd, PDst, PDstEnd, PRun, PVal: Integer;
  Buf: array[0..BufMax] of Byte;
  Row: array[0..79] of Byte;          { one packed CGA scanline }
  Mode6: Boolean;
  TopDown: Boolean;
  IsPCX: Boolean;
  BadImg: Boolean;
  Bits, Cmp: Integer;
  SrcW, SrcH, RowBytes: Integer;
  TgtW, TgtH, XOfs, YOfs: Integer;
  ScrW: Integer;                      { 512 (mode 6) or 320 (mode 4) }
  BOfs: Integer;                      { current row's offset inside Buf }
  WinN: Integer;                      { BMP rows per buffered read }
  I, J: Integer;

procedure Fail(S: Str80);
begin
  R.AX := $0003; Intr($10, R);        { back to text before complaining }
  WriteLn('VIEW: ', S);
  Halt;
end;

procedure Bad(S: Str80);              { soft failure: skippable in a }
begin                                 { slideshow, fatal for one file }
  EMsg := S;
  BadImg := True;
end;

function OpenFile: Boolean;
begin
  Nm := FName + #0;
  R.AX := $3D00;
  R.DS := DSeg; R.DX := Ofs(Nm[1]);
  MsDos(R);
  OpenFile := (R.Flags and 1) = 0;
  Handle := R.AX;
end;

procedure ReadBytes(Ofst, Count: Integer);
begin
  R.AX := $3F00; R.BX := Handle; R.CX := Count;
  R.DS := DSeg; R.DX := Ofst;
  MsDos(R);
  if ((R.Flags and 1) <> 0) or (R.AX < Count) then Bad('short read');
end;

procedure SkipBytes(Count: Integer);  { forward only }
begin
  while Count > 0 do
  begin
    R.AX := $4201; R.BX := Handle;    { lseek, relative }
    R.CX := 0;
    if Count > 30000 then R.DX := 30000 else R.DX := Count;
    Count := Count - R.DX;
    MsDos(R);
  end;
end;

function WordAt(O: Integer): Integer;
begin
  WordAt := Hdr[O] + Hdr[O + 1] shl 8;
end;

procedure ParsePcx;
begin
  ReadBytes(Ofs(Hdr) + 18, 110);      { the rest of the 128-byte header }
  if BadImg then Exit;
  if (Hdr[2] <> 1) or (Hdr[3] <> 8) or (Hdr[65] <> 1) then
  begin
    Bad('need an 8-bit RLE PCX'); Exit;
  end;
  SrcW := WordAt(8) - WordAt(4) + 1;
  SrcH := WordAt(10) - WordAt(6) + 1;
  if (SrcW <= 0) or (SrcH <= 0) then begin Bad('bad dimensions'); Exit; end;
  if SrcW > 2048 then begin Bad('wider than 2048'); Exit; end;
  RowBytes := WordAt(66);
  if (RowBytes < SrcW) or (RowBytes > 2048) then
  begin
    Bad('bad PCX row size'); Exit;
  end;
  { the 256-colour palette lives at EOF-769: marker $0C + RGB triples }
  R.AX := $4202; R.BX := Handle;
  R.CX := $FFFF; R.DX := $FCFF;       { seek -769 from end }
  MsDos(R);
  ReadBytes(Ofs(Buf), 769);
  if BadImg then Exit;
  if Buf[0] <> $0C then begin Bad('PCX palette missing'); Exit; end;
  for I := 0 to 255 do
  begin
    Pal[I, 2] := Buf[1 + I * 3];      { PCX is RGB, our table is B,G,R }
    Pal[I, 1] := Buf[2 + I * 3];
    Pal[I, 0] := Buf[3 + I * 3];
    Lum[I] := (Pal[I, 2] * 2 + Pal[I, 1] * 5 + Pal[I, 0]) shr 3;
  end;
  R.AX := $4200; R.BX := Handle;      { back to the pixel data }
  R.CX := 0; R.DX := 128;
  MsDos(R);
  PSrc := 0; PSrcEnd := 0;            { compressed window: empty }
  PRun := 0;
  TopDown := True;                    { PCX rows are stored top-down }
  IsPCX := True;
  Bits := 8;
end;

procedure ParseHeader;
var
  DibSize, DataOfs, HdrRead: Integer;
begin
  ReadBytes(Ofs(Hdr), 18);            { enough to tell BMP from PCX }
  if BadImg then Exit;
  if (Hdr[0] = $0A) and (Hdr[2] = 1) then
  begin
    ParsePcx;
    Exit;
  end;
  if (Hdr[0] <> Ord('B')) or (Hdr[1] <> Ord('M')) then
  begin
    Bad('not a BMP or PCX'); Exit;
  end;
  DataOfs := WordAt(10);              { < 32K in any sane BMP }
  DibSize := WordAt(14);
  if (DibSize < 40) or (DibSize > 124) then
  begin
    Bad('odd BMP header'); Exit;
  end;
  ReadBytes(Ofs(Hdr) + 18, DibSize - 4);
  if BadImg then Exit;
  HdrRead := 14 + DibSize;
  SrcW := WordAt(18);
  SrcH := WordAt(22);
  TopDown := WordAt(24) = $FFFF;      { negative height = top-down rows }
  if TopDown then SrcH := -SrcH;
  if (SrcW <= 0) or (SrcH <= 0) then begin Bad('bad dimensions'); Exit; end;
  if SrcW > 2048 then begin Bad('wider than 2048'); Exit; end;
  Bits := WordAt(28);
  Cmp := WordAt(30);
  if (Cmp <> 0) and (Cmp <> 3) then begin Bad('compressed BMP'); Exit; end;
  if (Bits <> 8) and (Bits <> 24) and (Bits <> 32) then
  begin
    Bad('need an 8/24/32-bit BMP'); Exit;
  end;
  case Bits of
    8: RowBytes := (SrcW + 3) and (not 3);
    24: RowBytes := (SrcW * 3 + 3) and (not 3);
    32: RowBytes := SrcW * 4;         { always aligned }
  end;
  if RowBytes > BufMax then begin Bad('row too long'); Exit; end;
  WinN := (BufMax + 1) div RowBytes;  { rows per buffered read }
  if Bits = 8 then
  begin
    ReadBytes(Ofs(Buf), 1024);        { BGRA quads }
    if BadImg then Exit;
    for I := 0 to 255 do
    begin
      for J := 0 to 2 do Pal[I, J] := Buf[I * 4 + J];
      Lum[I] := (Pal[I, 2] * 2 + Pal[I, 1] * 5 + Pal[I, 0]) shr 3;
    end;
    HdrRead := HdrRead + 1024;
  end;
  SkipBytes(DataOfs - HdrRead);       { bitfield masks, odd palettes... }
end;

procedure FitBox;
{ preserve the displayed aspect: CGA pixels are not square. In mode 6 a
  pixel is 1:2.4 (640x200 on a 4:3 screen), in mode 4 it is 1:1.2, so the
  corrected width/height ratio is PixTall * SrcW / SrcH. Real math, once
  per image - the MIDCONV precedent. }
var
  IdealW, PixTall: Real;
begin
  if Mode6 then PixTall := 2.4 else PixTall := 1.2;
  TgtH := 200;
  IdealW := PixTall * SrcW / SrcH * TgtH;
  if IdealW > ScrW * 1.0 then
  begin
    TgtW := ScrW;
    TgtH := Trunc(200 * (ScrW / IdealW));
    if TgtH < 1 then TgtH := 1;
  end
  else
  begin
    TgtW := Trunc(IdealW);
    if TgtW < 1 then TgtW := 1;
  end;
  if Mode6 then XOfs := ((640 - TgtW) div 2) div 8
  else XOfs := ((320 - TgtW) div 2) div 4;
  YOfs := (200 - TgtH) div 2;
  for J := 0 to 3 do                  { Bayer rows expanded for pass B }
    for I := 0 to TgtW - 1 do
      ThrTab[J, I] := Bayer[I and 3, J];
end;

procedure PcxRow;
{ decode the next source row into LumRow. The RLE stepper is machine
  code; it stops on row-complete or input-exhausted, and a run carries
  across both row boundaries and buffer refills (PRun/PVal). }
begin
  PDst := Ofs(LumRow); PDstEnd := PDst + RowBytes;
  repeat
    inline(
    $06/$1E/$07/$FC/$8B/$36/PSrc/$8B/$3E/
    PDst/$8B/$0E/PRun/$E3/$16/$A1/PDstEnd/$2B/
    $C7/$74/$3E/$3B/$C8/$76/$02/$8B/$C8/
    $29/$0E/PRun/$A0/PVal/$F3/$AA/$3B/$3E/
    PDstEnd/$73/$29/$3B/$36/PSrcEnd/$73/$23/$AC/
    $8A/$E0/$80/$E4/$C0/$80/$FC/$C0/$75/
    $15/$3B/$36/PSrcEnd/$72/$03/$4E/$EB/$0F/
    $24/$3F/$98/$A3/PRun/$AC/$A2/PVal/$EB/
    $B8/$AA/$EB/$D1/$89/$36/PSrc/$89/$3E/
    PDst/$07);
    if PDst < PDstEnd then
    begin                             { out of compressed bytes: refill.
      A count byte split from its value byte gets un-read (PSrc backs
      up one) - carry that tail byte over, or it is lost to the read }
      J := PSrcEnd - PSrc;
      if J > 0 then Buf[0] := Buf[PSrc - Ofs(Buf)];
      R.AX := $3F00; R.BX := Handle; R.CX := BufMax + 1 - J;
      R.DS := DSeg; R.DX := Ofs(Buf) + J;
      MsDos(R);
      if ((R.Flags and 1) <> 0) or (R.AX = 0) then
      begin
        Bad('truncated PCX'); Exit;
      end;
      PSrc := Ofs(Buf); PSrcEnd := Ofs(Buf) + J + R.AX;
    end;
  until PDst >= PDstEnd;
end;

procedure PixelRGB(SX: Integer; var PR, PG, PB: Byte);
var
  O: Integer;
begin
  if IsPCX then
  begin
    O := LumRow[SX];
    PB := Pal[O, 0]; PG := Pal[O, 1]; PR := Pal[O, 2];
    Exit;
  end;
  case Bits of
    8: begin
         O := Buf[BOfs + SX];
         PB := Pal[O, 0]; PG := Pal[O, 1]; PR := Pal[O, 2];
       end;
    24: begin
          O := BOfs + SX + SX + SX;  { TP3 compiles *3 to a real MUL }
          PB := Buf[O]; PG := Buf[O + 1]; PR := Buf[O + 2];
        end;
    32: begin
          O := BOfs + (SX shl 2);
          PB := Buf[O]; PG := Buf[O + 1]; PR := Buf[O + 2];
        end;
  end;
end;

procedure RenderRow(TY: Integer);
{ the current source row (Buf[BOfs..] or LumRow for PCX) -> packed
  target row TY -> B800 }
var
  TX, SX, SErr, B, Thr, BI: Integer;
  PR, PG, PB, C: Byte;
begin
  FillChar(Row, SizeOf(Row), 0);
  SX := 0; SErr := 0;
  B := 0; BI := 0;                    { pairs (mode 4) }
  if Mode6 then
  begin
    { the whole fetch/DDA/dither/pack loop is hand-written 8086 machine
      code (generated by tools/mkviewasm.py, ~18 instructions/pixel vs
      TP3's ~130 - at SNES speed that is the paint time). 8bpp sources
      XLAT through Lum; 24/32bpp rows are first reduced to LumRow and
      go through an identity table instead. }
    if IsPCX then
    begin
      VSrc := Ofs(LumRow); VLut := Ofs(Lum);
    end
    else if Bits = 8 then
    begin
      VSrc := Ofs(Buf) + BOfs; VLut := Ofs(Lum);
    end
    else
    begin
      SX := BOfs;
      for TX := 0 to SrcW - 1 do
      begin
        LumRow[TX] := (Buf[SX + 2] * 2 + Buf[SX + 1] * 5 + Buf[SX]) shr 3;
        if Bits = 24 then SX := SX + 3 else SX := SX + 4;
      end;
      VSrc := Ofs(LumRow); VLut := Ofs(IdTab);
    end;
    VCnt := TgtW; VSw := SrcW; VTw := TgtW; VErr := 0;
    { pass A: fetch + luma (XLAT) + DDA -> LumTgt }
    inline(
    $06/$1E/$07/$8B/$36/VSrc/$BF/LumTgt/$8B/
    $1E/VLut/$8B/$0E/VCnt/$FC/$8A/$04/$D7/
    $AA/$8B/$06/VSw/$01/$06/VErr/$8B/$06/
    VErr/$3B/$06/VTw/$72/$0B/$8B/$06/VTw/
    $29/$06/VErr/$46/$EB/$EB/$E2/$DD/$07);
    VThrRow := Ofs(ThrTab) + (TY and 3) * 512;
    VDst := Ofs(Row) + XOfs;
    { pass B: LumTgt vs the Bayer row -> packed bits -> Row }
    inline(
    $06/$1E/$07/$BE/LumTgt/$8B/$1E/VThrRow/$8B/
    $3E/VDst/$8B/$0E/VCnt/$FC/$31/$D2/$AC/
    $38/$07/$D0/$D2/$43/$FE/$C6/$80/$FE/
    $08/$75/$05/$8A/$C2/$AA/$31/$D2/$E2/
    $EC/$80/$FE/$00/$74/$0C/$D0/$E2/$FE/
    $C6/$80/$FE/$08/$75/$F7/$8A/$C2/$AA/
    $07);
  end
  else
  begin
    for TX := 0 to TgtW - 1 do
    begin
      PixelRGB(SX, PR, PG, PB);
      SErr := SErr + SrcW;
      while SErr >= TgtW do
      begin
        SErr := SErr - TgtW; SX := SX + 1;
      end;
      Thr := Bayer[TX and 3, TY and 3];
      C := 0;
      if PR > Thr then C := 4;
      if PG > Thr then C := C or 2;
      if PB > Thr then C := C or 1;
      B := (B shl 2) or ColorMap[C];
      BI := BI + 1;
      if BI = 4 then
      begin
        Row[XOfs + (TX shr 2)] := B; B := 0; BI := 0;
      end;
    end;
    if BI > 0 then                    { flush a ragged right edge }
      Row[XOfs + ((TgtW - 1) shr 2)] := B shl (2 * (4 - BI));
  end;
  VBlt := ((YOfs + TY) shr 1) * 80;
  if ((YOfs + TY) and 1) = 1 then VBlt := VBlt + $2000;
  { blit: Row -> B800, 40 words }
  inline(
  $06/$B8/$00/$B8/$8E/$C0/$BE/Row/$8B/
  $3E/VBlt/$FC/$B9/$28/$00/$F3/$A5/$07);
end;

procedure ShowImage;
{ walk target rows in the order their source rows sit in the file:
  bottom-up BMPs render bottom row first (file index k = SrcH-1-sy),
  top-down BMPs and PCX render top row first. Source rows arrive in
  buffered batches (WinN rows per DOS read; skipped rows just flow
  through the window), and SY = floor(TY*SrcH/TgtH) is stepped with
  integer Bresenham - no per-row float. }
var
  N, TY, K, PrevK, N2, NewBase: Integer;
  WBase, WCount: Integer;
  RQ, RR, RSY, RRem: Integer;
begin
  if Mode6 then R.AX := $0006 else R.AX := $0004;
  Intr($10, R);
  if not Mode6 then
  begin
    R.AX := $0B01; R.BX := $0101;     { palette 1: cyan/magenta/white }
    Intr($10, R);
  end;
  RQ := SrcH div TgtH; RR := SrcH mod TgtH;
  RSY := 0; RRem := 0;
  if not TopDown then                 { start at TY = TgtH-1 }
    for N := 1 to TgtH - 1 do
    begin
      RSY := RSY + RQ; RRem := RRem + RR;
      if RRem >= TgtH then begin RRem := RRem - TgtH; RSY := RSY + 1; end;
    end;
  WBase := 0; WCount := 0;
  PrevK := -1;
  for N := 0 to TgtH - 1 do
  begin
    if BadImg then Exit;
    if TopDown then TY := N else TY := TgtH - 1 - N;
    if TopDown then K := RSY else K := SrcH - 1 - RSY;
    if IsPCX then
    begin
      while PrevK < K do
      begin
        PcxRow;
        if BadImg then Exit;
        PrevK := PrevK + 1;
      end;
    end
    else
    begin
      while K >= WBase + WCount do
      begin
        NewBase := WBase + WCount;
        N2 := SrcH - NewBase;
        if N2 > WinN then N2 := WinN;
        if N2 < 1 then begin Bad('row underflow'); Exit; end;
        ReadBytes(Ofs(Buf), N2 * RowBytes);
        if BadImg then Exit;
        WBase := NewBase; WCount := N2;
      end;
      BOfs := (K - WBase) * RowBytes;
    end;
    RenderRow(TY);
    if TopDown then
    begin
      RSY := RSY + RQ; RRem := RRem + RR;
      if RRem >= TgtH then begin RRem := RRem - TgtH; RSY := RSY + 1; end;
    end
    else
    begin
      RSY := RSY - RQ; RRem := RRem - RR;
      if RRem < 0 then begin RRem := RRem + TgtH; RSY := RSY - 1; end;
    end;
  end;
end;

function WaitKey: Integer;
begin
  R.AX := $0000; Intr($16, R);
  WaitKey := R.AX and $00FF;
end;

function ShowOne: Boolean;
{ open FName, parse, render. False = skipped/broken (EMsg says why). }
begin
  ShowOne := False;
  BadImg := False;
  IsPCX := False;
  if not OpenFile then
  begin
    EMsg := 'cannot open ' + FName;
    Exit;
  end;
  ParseHeader;
  if not BadImg then
  begin
    FitBox;
    ShowImage;
  end;
  R.AX := $3E00; R.BX := Handle; MsDos(R);
  ShowOne := not BadImg;
end;

var
  Wild, Quit, Found: Boolean;
  Shown, K: Integer;

begin
  for I := 0 to 255 do IdTab[I] := I;
  Mode6 := True; ScrW := 512;
  if ParamCount < 1 then
  begin
    WriteLn('usage: VIEW picture[.bmp|.pcx] [4]');
    WriteLn('  640x200 mono by default; "4" = 320x200 colour');
    WriteLn('  wildcards slideshow: VIEW *.BMP  (any key = next, ESC = quit)');
    Halt;
  end;
  FName := ParamStr(1);
  if ParamCount >= 2 then
    if ParamStr(2) = '4' then
    begin
      Mode6 := False; ScrW := 320;
    end;
  Wild := False;
  for I := 1 to Length(FName) do
    if (FName[I] = '*') or (FName[I] = '?') then Wild := True;
  if not Wild then
  begin
    if not ShowOne then Fail(EMsg);
    K := WaitKey;
    R.AX := $0003; Intr($10, R);
  end
  else
  begin
    Pattern := FName;
    Prefix := '';
    for I := Length(Pattern) downto 1 do
      if (Prefix = '') and ((Pattern[I] = '\') or (Pattern[I] = ':')) then
        Prefix := Copy(Pattern, 1, I);
    R.AX := $1A00;                    { our own DTA }
    R.DS := DSeg; R.DX := Ofs(DTA);
    MsDos(R);
    Nm := Pattern + #0;
    R.AX := $4E00; R.CX := 0;         { find first }
    R.DS := DSeg; R.DX := Ofs(Nm[1]);
    MsDos(R);
    Found := (R.Flags and 1) = 0;
    Shown := 0;
    Quit := False;
    while Found and not Quit do
    begin
      SName := '';
      I := 30;
      while (DTA[I] <> 0) and (I < 43) do
      begin
        SName := SName + Chr(DTA[I]);
        I := I + 1;
      end;
      if (Pos('.BMP', SName) > 0) or (Pos('.PCX', SName) > 0) then
      begin
        FName := Prefix + SName;
        if ShowOne then
        begin
          Shown := Shown + 1;
          if WaitKey = 27 then Quit := True;
        end;
      end;
      R.AX := $4F00;                  { find next }
      MsDos(R);
      Found := (R.Flags and 1) = 0;
    end;
    R.AX := $0003; Intr($10, R);
    if Shown = 0 then WriteLn('VIEW: nothing viewable matched ', Pattern);
  end;
end.
