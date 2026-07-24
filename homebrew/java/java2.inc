{ JAVA2.INC - the runtime: console I/O, 32-bit pair arithmetic
  (hand-written 8086: TP3 has no 32-bit integers and its software Real
  is hundreds of instructions), number formatting via Real (exact to
  2^31, and printing is not hot), and the StringBuilder arena. }

procedure AddV;                       { (VHA:VLA) := VA + VB }
begin
  inline(
    $8B/$06/VLA/$03/$06/VLB/$A3/VLA/
    $8B/$06/VHA/$13/$06/VHB/$A3/VHA);
end;

procedure SubV;                       { (VHA:VLA) := VA - VB }
begin
  inline(
    $8B/$06/VLA/$2B/$06/VLB/$A3/VLA/
    $8B/$06/VHA/$1B/$06/VHB/$A3/VHA);
end;

procedure MulV;                       { (VHA:VLA) := low32(VA * VB) }
begin
  inline(
    $8B/$06/VLA/$F7/$26/VLB/$A3/VRL/$8B/$CA/
    $8B/$06/VHA/$F7/$26/VLB/$03/$C8/
    $8B/$06/VLA/$F7/$26/VHB/$03/$C8/$89/$0E/VRH);
  VLA := VRL;
  VHA := VRH;
end;

function Cmp32(H1, L1, H2, L2: Integer): Integer;
{ signed 32-bit compare: -1 / 0 / +1. Lo words compare unsigned - the
  xor $8000 trick maps unsigned order onto the signed comparator. }
begin
  if H1 = H2 then
  begin
    L1 := L1 xor $8000;
    L2 := L2 xor $8000;
    if L1 = L2 then Cmp32 := 0
    else if L1 < L2 then Cmp32 := -1
    else Cmp32 := 1;
  end
  else if H1 < H2 then Cmp32 := -1
  else Cmp32 := 1;
end;

procedure I32Str(H, L: Integer);      { -> S16, via exact Real math }
var
  X: Real;
begin
  X := H * 65536.0;
  if L < 0 then X := X + (L + 65536.0)
  else X := X + L;
  Str(X:1:0, S16);
end;

procedure OutCh(C: Byte);
begin
  Write(Chr(C));
end;

procedure OutUtf(U: Integer);         { print a constant-pool Utf8 }
var
  O, L, K: Integer;
begin
  O := CpOfs[U];
  L := U2(O);
  for K := 1 to L do OutCh(Buf[O + 1 + K]);
end;

procedure OutSB(SL: Integer);
var
  K: Integer;
begin
  for K := 0 to SBLen[SL] - 1 do OutCh(SBBuf[SL, K]);
end;

procedure OutRef(H, L: Integer);      { print any string-ish value }
begin
  if H = $7F02 then OutUtf(L)
  else if (H = $7F03) or (H = $7F04) then OutSB(L)
  else if (H = 0) and (L = 0) then Write('null')
  else Fail('not a string');
end;

procedure SBAddCh(SL: Integer; C: Byte);
begin
  if SBLen[SL] > 190 then Fail('string too long');
  SBBuf[SL, SBLen[SL]] := C;
  SBLen[SL] := SBLen[SL] + 1;
end;

procedure SBAddUtf(SL, U: Integer);
var
  O, L, K: Integer;
begin
  O := CpOfs[U];
  L := U2(O);
  for K := 1 to L do SBAddCh(SL, Buf[O + 1 + K]);
end;

procedure SBAddStr(SL: Integer);      { append S16 }
var
  K: Integer;
begin
  for K := 1 to Length(S16) do SBAddCh(SL, Ord(S16[K]));
end;

function KeyIn: Integer;              { System.in.read(): DOS AH=01 }
begin
  R.AX := $0100;
  MsDos(R);
  KeyIn := R.AX and $FF;
end;
