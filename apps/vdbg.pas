program VDbg;
var
  Buf: array[0..63] of Byte;
  Out1: array[0..31] of Byte;
  Row: array[0..79] of Byte;
  PSrc, PSrcEnd, PDst, PDstEnd, PRun, PVal, VBlt: Integer;
  I: Integer;

procedure Rle;
begin
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
end;

begin
  Buf[0] := 1; Buf[1] := 2; Buf[2] := 3; Buf[3] := $C4; Buf[4] := 9;
  Buf[5] := 5;
  PSrc := Ofs(Buf); PSrcEnd := Ofs(Buf) + 6;
  PDst := Ofs(Out1); PDstEnd := Ofs(Out1) + 8;
  PRun := 0;
  Rle;
  Write('T1:');
  for I := 0 to 7 do Write(' ', Out1[I]);
  WriteLn(' pos=', PDst - Ofs(Out1), ' want: 1 2 3 9 9 9 9 5 pos=8');

  Buf[0] := $C8; Buf[1] := 7;
  PSrc := Ofs(Buf); PSrcEnd := Ofs(Buf) + 2;
  PDst := Ofs(Out1); PDstEnd := Ofs(Out1) + 5;
  PRun := 0;
  Rle;
  WriteLn('T2: pos=', PDst - Ofs(Out1), ' run=', PRun, ' want: pos=5 run=3');
  PDst := Ofs(Out1); PDstEnd := Ofs(Out1) + 3;
  Rle;
  WriteLn('T2b: pos=', PDst - Ofs(Out1), ' run=', PRun, ' out0=', Out1[0],
          ' want: pos=3 run=0 out0=7');

  Buf[0] := 11; Buf[1] := $C3;
  PSrc := Ofs(Buf); PSrcEnd := Ofs(Buf) + 2;
  PDst := Ofs(Out1); PDstEnd := Ofs(Out1) + 8;
  PRun := 0;
  Rle;
  WriteLn('T3: used=', PSrc - Ofs(Buf), ' pos=', PDst - Ofs(Out1),
          ' want: used=1 pos=1');
  Buf[0] := $C3; Buf[1] := 22;
  PSrc := Ofs(Buf); PSrcEnd := Ofs(Buf) + 2;
  Rle;
  WriteLn('T3b: pos=', PDst - Ofs(Out1), ' out1=', Out1[1],
          ' want: pos=4 out1=22');

  for I := 0 to 79 do Row[I] := I;
  VBlt := 24 * 160;
    inline(
    $06/$B8/$00/$B8/$8E/$C0/$BE/Row/$8B/
    $3E/VBlt/$FC/$B9/$28/$00/$F3/$A5/$07);
  WriteLn('T4: b5=', Mem[$B800:24*160+5], ' b79=', Mem[$B800:24*160+79],
          ' want: b5=5 b79=79');
end.
