program View;
{ VIEW - a BMP viewer for snes86 (or any CGA PC).
  Usage:  VIEW picture.bmp      640x200 mono, ordered dither (CGA mode 6)
          VIEW picture.bmp 4    320x200 four-colour dither  (CGA mode 4)
  Any key exits. On the SNES, L/R pan the 512px window across the 640.

  Handles 8-bit palettised, 24-bit and 32-bit uncompressed BMPs, top-down
  or bottom-up, up to 2048 pixels wide. Rows are streamed one at a time
  and the file is read strictly forward (Turbo Pascal 3 has no 32-bit
  integers, so every seek is a small relative skip - the trick is to walk
  target rows in the order the file stores them). }

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
  FName: string[64];
  Nm: string[65];
  Hdr: array[0..137] of Byte;
  Pal: array[0..255, 0..2] of Byte;   { palettised BMPs: B,G,R }
  Lum: array[0..255] of Byte;         { per-palette-index luminance }
  IdTab: array[0..255] of Byte;       { identity for pre-lumified rows }
  LumRow: array[0..2047] of Byte;     { 24/32bpp rows reduced to luma }
  LumTgt: array[0..511] of Byte;      { pass A output: scaled luma row }
  ThrTab: array[0..3, 0..511] of Byte; { Bayer expanded per row phase }
  { state for the inline loops. Globals, deliberately: TP3 keeps SS <> DS,
    so locals (SS:[BP+x]) are invisible to DS-relative machine code }
  VSrc, VDst, VCnt, VSw, VTw, VErr, VLut, VThrRow: Integer;
  Buf: array[0..BufMax] of Byte;
  Row: array[0..79] of Byte;          { one packed CGA scanline }
  Mode6: Boolean;
  TopDown: Boolean;
  Bits, Cmp: Integer;
  SrcW, SrcH, RowBytes: Integer;
  TgtW, TgtH, XOfs, YOfs: Integer;
  ScrW: Integer;                      { 512 (mode 6) or 320 (mode 4) }
  I, J: Integer;

procedure Fail(S: Str80);
begin
  R.AX := $0003; Intr($10, R);        { back to text before complaining }
  WriteLn('VIEW: ', S);
  Halt;
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
  if ((R.Flags and 1) <> 0) or (R.AX < Count) then Fail('short read');
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

procedure ParseHeader;
var
  DibSize, DataOfs, HdrRead: Integer;
begin
  ReadBytes(Ofs(Hdr), 18);            { file header + biSize }
  if (Hdr[0] <> Ord('B')) or (Hdr[1] <> Ord('M')) then Fail('not a BMP');
  DataOfs := WordAt(10);              { < 32K in any sane BMP }
  DibSize := WordAt(14);
  if DibSize < 40 then Fail('ancient BMP header');
  if DibSize > 124 then Fail('weird BMP header');
  ReadBytes(Ofs(Hdr) + 18, DibSize - 4);
  HdrRead := 14 + DibSize;
  SrcW := WordAt(18);
  SrcH := WordAt(22);
  TopDown := WordAt(24) = $FFFF;      { negative height = top-down rows }
  if TopDown then SrcH := -SrcH;
  if (SrcW <= 0) or (SrcH <= 0) then Fail('bad dimensions');
  if SrcW > 2048 then Fail('wider than 2048');
  Bits := WordAt(28);
  Cmp := WordAt(30);
  if (Cmp <> 0) and (Cmp <> 3) then Fail('compressed BMP');
  if (Bits <> 8) and (Bits <> 24) and (Bits <> 32) then
    Fail('need an 8/24/32-bit BMP');
  case Bits of
    8: RowBytes := (SrcW + 3) and (not 3);
    24: RowBytes := (SrcW * 3 + 3) and (not 3);
    32: RowBytes := SrcW * 4;         { always aligned }
  end;
  if RowBytes > BufMax then Fail('row too long');
  if Bits = 8 then
  begin
    ReadBytes(Ofs(Buf), 1024);        { BGRA quads }
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

procedure PixelRGB(SX: Integer; var PR, PG, PB: Byte);
var
  O: Integer;
begin
  case Bits of
    8: begin
         O := Buf[SX];
         PB := Pal[O, 0]; PG := Pal[O, 1]; PR := Pal[O, 2];
       end;
    24: begin
          O := SX + SX + SX;   { TP3 compiles *3 to a real 8086 MUL }
          PB := Buf[O]; PG := Buf[O + 1]; PR := Buf[O + 2];
        end;
    32: begin
          O := SX shl 2;
          PB := Buf[O]; PG := Buf[O + 1]; PR := Buf[O + 2];
        end;
  end;
end;

procedure RenderRow(TY: Integer);
{ Buf holds the source row; pack target row TY, blit it to B800 }
var
  TX, SX, SErr, B, Shift, Thr, BI, L: Integer;
  PR, PG, PB, C: Byte;
begin
  for TX := 0 to 79 do Row[TX] := 0;
  SX := 0; SErr := 0;
  B := 0; BI := 0;                    { bits (mode 6) / pairs (mode 4) }
  if Mode6 then
  begin
    { the whole fetch/DDA/dither/pack loop is hand-written 8086 machine
      code (generated by tools/mkviewasm.py, ~18 instructions/pixel vs
      TP3's ~130 - at SNES speed that is the paint time). 8bpp sources
      XLAT through Lum; 24/32bpp rows are first reduced to LumRow and
      go through an identity table instead. }
    if Bits = 8 then
    begin
      VSrc := Ofs(Buf); VLut := Ofs(Lum);
    end
    else
    begin
      SX := 0;
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
  if BI > 0 then                      { flush a ragged right edge }
  begin
    if Mode6 then Row[XOfs + ((TgtW - 1) shr 3)] := B shl (8 - BI)
    else Row[XOfs + ((TgtW - 1) shr 2)] := B shl (2 * (4 - BI));
  end;
  Shift := ((YOfs + TY) shr 1) * 80;
  if ((YOfs + TY) and 1) = 1 then Shift := Shift + $2000;
  for TX := 0 to 79 do Mem[$B800:Shift + TX] := Row[TX];
end;

procedure ShowImage;
{ walk target rows in the order their source rows sit in the file:
  bottom-up BMPs render bottom row first (file index k = SrcH-1-sy),
  top-down ones top row first. Every file access is a forward read or a
  small forward skip; upscaled rows reuse the buffered source row. }
var
  N, TY, SYImg, K, PrevK: Integer;
begin
  if Mode6 then R.AX := $0006 else R.AX := $0004;
  Intr($10, R);
  if not Mode6 then
  begin
    R.AX := $0B01; R.BX := $0101;     { palette 1: cyan/magenta/white }
    Intr($10, R);
  end;
  PrevK := -1;
  for N := 0 to TgtH - 1 do
  begin
    if TopDown then TY := N else TY := TgtH - 1 - N;
    SYImg := Trunc(TY * (SrcH * 1.0) / TgtH);
    if SYImg > SrcH - 1 then SYImg := SrcH - 1;
    if TopDown then K := SYImg else K := SrcH - 1 - SYImg;
    if K > PrevK then
    begin
      { skip unused rows by READING them: DOS 2.0 re-walks the whole
        FAT chain after every lseek, so sequential reads are cheaper }
      for I := 1 to K - PrevK - 1 do ReadBytes(Ofs(Buf), RowBytes);
      ReadBytes(Ofs(Buf), RowBytes);
      PrevK := K;
    end;
    RenderRow(TY);
  end;
end;

begin
  for I := 0 to 255 do IdTab[I] := I;
  Mode6 := True; ScrW := 512;
  if ParamCount < 1 then
  begin
    WriteLn('usage: VIEW picture.bmp [4]');
    WriteLn('  640x200 mono by default; "4" = 320x200 colour');
    Halt;
  end;
  FName := ParamStr(1);
  if ParamCount >= 2 then
    if ParamStr(2) = '4' then
    begin
      Mode6 := False; ScrW := 320;
    end;
  if not OpenFile then Fail('cannot open ' + FName);
  ParseHeader;
  FitBox;
  ShowImage;
  R.AX := $0000; Intr($16, R);        { any key }
  R.AX := $0003; Intr($10, R);
  R.AX := $3E00; R.BX := Handle; MsDos(R);
end.
