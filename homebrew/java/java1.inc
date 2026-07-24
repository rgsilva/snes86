{ JAVA1.INC - class-file loading and parsing. Big-endian throughout:
  U2 assembles byte pairs (bit-exact into the 16-bit Integer), and the
  only u4 values we accept must have a zero high word. }

procedure Fail(S: Str48);
begin
  WriteLn('JAVA: ', S);
  Halt;
end;

procedure FailB(S: Str48; B: Integer);
begin
  WriteLn('JAVA: ', S, B);
  Halt;
end;

function U2(O: Integer): Integer;
begin
  U2 := (Buf[O] shl 8) or Buf[O + 1];
end;

procedure LoadFile;
begin
  Nm := FName + #0;
  R.AX := $3D00;
  R.DS := DSeg; R.DX := Ofs(Nm[1]);
  MsDos(R);
  if (R.Flags and 1) <> 0 then Fail('cannot open ' + FName);
  I := R.AX;                          { handle }
  R.AX := $3F00; R.BX := I; R.CX := BUFSZ + 1;
  R.DS := DSeg; R.DX := Ofs(Buf);
  MsDos(R);
  if (R.Flags and 1) <> 0 then Fail('read error');
  FSize := R.AX;
  if FSize > BUFSZ then Fail('class file too big');
  R.AX := $3E00; R.BX := I; MsDos(R);
  if (U2(0) <> $CAFE) or (U2(2) <> $BABE) then Fail('not a class file');
end;

function UtfIs(U: Integer; S: Str48): Boolean;
var
  O, L, K: Integer;
begin
  UtfIs := False;
  if CpTag[U] <> 1 then Exit;
  O := CpOfs[U];
  L := U2(O);
  if L <> Length(S) then Exit;
  for K := 1 to L do
    if Buf[O + 1 + K] <> Ord(S[K]) then Exit;
  UtfIs := True;
end;

function ArgSlots(U: Integer): Integer;
{ count argument slots in a method descriptor "(...)X" }
var
  O, E, N: Integer;
begin
  O := CpOfs[U];
  E := O + 2 + U2(O);
  O := O + 3;                         { skip len and '(' }
  N := 0;
  while (O < E) and (Buf[O] <> 41) do   { ')' }
  begin
    case Buf[O] of
      76: begin                       { 'L': one ref slot, skip to ';' }
            N := N + 1;
            while (O < E) and (Buf[O] <> 59) do O := O + 1;
          end;
      91: ;                           { '[': the element type carries it }
      74, 68: Fail('long/double not supported');
    else
      N := N + 1;
    end;
    O := O + 1;
  end;
  ArgSlots := N;
end;

procedure ParseClass;
var
  O, N, K, A, T, NameU, DescU, AttN, AttL, Acc: Integer;
  IsStatic: Boolean;
begin
  CpCount := U2(8);
  if CpCount > MAXPOOL then Fail('constant pool too big');
  O := 10;
  N := 1;
  while N < CpCount do
  begin
    T := Buf[O];
    CpTag[N] := T;
    CpOfs[N] := O + 1;
    ShimC[N] := 0;
    case T of
      1: O := O + 3 + U2(O + 1);
      3, 4: O := O + 5;
      5, 6: begin O := O + 9; N := N + 1 end;
      7, 8: O := O + 3;
      9, 10, 11, 12: O := O + 5;
      15: O := O + 4;
      16: O := O + 3;
      17, 18: O := O + 5;
    else
      FailB('pool tag ', T);
    end;
    N := N + 1;
  end;
  O := O + 2;                         { access flags }
  ThisCp := U2(O);
  O := O + 4;                         { this, super }
  N := U2(O); O := O + 2 + N * 2;     { interfaces }
  { fields: keep static ints }
  SFCount := 0;
  N := U2(O); O := O + 2;
  for K := 1 to N do
  begin
    Acc := U2(O);
    NameU := U2(O + 2);
    O := O + 6;
    A := U2(O); O := O + 2;
    while A > 0 do
    begin
      AttL := U2(O + 4);              { u4 length: low word }
      if U2(O + 2) <> 0 then Fail('huge attribute');
      O := O + 6 + AttL;
      A := A - 1;
    end;
    if (Acc and 8) <> 0 then
    begin
      SFCount := SFCount + 1;
      if SFCount > MAXSF then Fail('too many fields');
      SFName[SFCount] := NameU;
      SFHi[SFCount] := 0; SFLo[SFCount] := 0;
    end;
  end;
  { methods: record name/desc/code }
  MCount := 0; MainM := 0;
  N := U2(O); O := O + 2;
  for K := 1 to N do
  begin
    NameU := U2(O + 2);
    DescU := U2(O + 4);
    O := O + 6;
    MCount := MCount + 1;
    if MCount > MAXMETH then Fail('too many methods');
    MName[MCount] := NameU;
    MDesc[MCount] := DescU;
    MCode[MCount] := 0;
    MArgs[MCount] := ArgSlots(DescU);
    A := U2(O); O := O + 2;
    while A > 0 do
    begin
      AttN := U2(O);
      AttL := U2(O + 4);
      if U2(O + 2) <> 0 then Fail('huge attribute');
      if UtfIs(AttN, 'Code') then
      begin
        MMaxL[MCount] := U2(O + 8);
        if U2(O + 10) <> 0 then Fail('huge method');
        MCode[MCount] := O + 14;      { code bytes }
      end;
      O := O + 6 + AttL;
      A := A - 1;
    end;
    if UtfIs(NameU, 'main') then MainM := MCount;
  end;
end;
