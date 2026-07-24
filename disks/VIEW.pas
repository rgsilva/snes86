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
      for J := 0 to 2 do Pal[I, J] := Buf[I * 4 + J];
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
          O := SX * 3;
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
  for TX := 0 to TgtW - 1 do
  begin
    PixelRGB(SX, PR, PG, PB);
    SErr := SErr + SrcW;
    while SErr >= TgtW do
    begin
      SErr := SErr - TgtW; SX := SX + 1;
    end;
    Thr := Bayer[TX and 3, TY and 3];
    if Mode6 then
    begin
      L := (PR * 2 + PG * 5 + PB) shr 3;
      B := B shl 1;
      if L > Thr then B := B or 1;
      BI := BI + 1;
      if BI = 8 then
      begin
        Row[XOfs + (TX shr 3)] := B; B := 0; BI := 0;
      end;
    end
    else
    begin
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
      for I := 1 to K - PrevK - 1 do SkipBytes(RowBytes);
      ReadBytes(Ofs(Buf), RowBytes);
      PrevK := K;
    end;
    RenderRow(TY);
  end;
end;

begin
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
