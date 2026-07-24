program MidPlay;
{ MIDPLAY v2 - streams a pre-converted .SNM packet file (see MIDCONV) }
{ to the SNES-MIDI interface: data port $330, status port $331 reads  }
{ the free packet count. Dumb and fast on purpose: the MIDI parsing   }
{ happens offline in MIDCONV. Q or Esc stops.                         }

type
  Str64 = string[64];
  RegPack = record
    AX, BX, CX, DX, BP, SI, DI, DS, ES, Flags: Integer;
  end;

var
  f: file;
  buf: array[0..127] of Byte;
  i: Integer;
  R: RegPack;
  fname: Str64;
  playing: Boolean;
  npk: Integer;

procedure CheckKey;
var
  c: Char;
begin
  R.AX := $0100;
  Intr($16, R);
  if R.Flags and $40 = 0 then
  begin
    R.AX := 0;
    Intr($16, R);
    c := UpCase(Chr(Lo(R.AX)));
    if (c = 'Q') or (Lo(R.AX) = 27) then playing := False;
  end;
end;

begin
  WriteLn('MIDPLAY - the SNES is your sound card now.');
  if ParamCount >= 1 then fname := ParamStr(1)
  else fname := 'C:\MIDI\CANYON.SNM';
  Assign(f, fname);
  {$I-}
  Reset(f);
  {$I+}
  if IOResult <> 0 then
  begin
    WriteLn('Cannot open ', fname);
    Halt(1);
  end;
  Port[$331] := 0;                   { reset the card }
  WriteLn('Playing ', fname, ' - Q or Esc stops.');
  playing := True;
  npk := 0;
  while playing do
  begin
    {$I-}
    BlockRead(f, buf, 1);
    {$I+}
    if IOResult <> 0 then playing := False
    else
    begin
      i := 0;
      while i < 128 do
      begin
        repeat until Port[$331] > 0;
        Port[$330] := buf[i];
        Port[$330] := buf[i + 1];
        Port[$330] := buf[i + 2];
        Port[$330] := buf[i + 3];
        i := i + 4;
      end;
      npk := npk + 32;
      CheckKey;
    end;
  end;
  Port[$330] := 0;                  { all notes off, whatever happened }
  Port[$330] := $FF;
  Port[$330] := 0;
  Port[$330] := 0;
  Close(f);
  WriteLn('Done. ', npk, ' packets sent.');
end.
