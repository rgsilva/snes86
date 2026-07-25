program MidConv;
{ MIDCONV - converts a format-0 Standard MIDI File into the .SNM    }
{ packet stream MIDPLAY streams to the SNES-MIDI card. The parse    }
{ (software Real math) is too slow to do live at snes86 speed, so   }
{ it runs once here; playback is then a dumb fast loop.             }

type
  Str64 = string[64];
  RegPack = record
    AX, BX, CX, DX, BP, SI, DI, DS, ES, Flags: Integer;
  end;

var
  f: file;
  win: array[0..4479] of Byte;
  wpos, wlen: Integer;
  feof: Boolean;
  scale, fcarry: Real;
  division: Real;
  rstatus: Byte;
  pending: Integer;
  npk: Integer;
  R: RegPack;
  fo: file;
  ob: array[0..127] of Byte;
  on_: Integer;
  oname: Str64;
  fname: Str64;
  playing: Boolean;

procedure Refill;
var
  left: Integer;
begin
  left := wlen - wpos;
  if left > 0 then Move(win[wpos], win[0], left);
  wlen := left;
  wpos := 0;
  {$I-}
  while (wlen <= 4351 - 128) and not feof do
  begin
    BlockRead(f, win[wlen], 1);
    if IOResult <> 0 then feof := True
    else wlen := wlen + 128;
  end;
  {$I+}
end;

function NextB: Byte;
begin
  if wlen - wpos < 8 then Refill;
  if wpos >= wlen then
  begin
    NextB := $FF;                   { starved: fake end-of-things }
    playing := False;
  end
  else
  begin
    NextB := win[wpos];
    wpos := wpos + 1;
  end;
end;

function ReadVar: Integer;          { MIDI variable-length quantity }
var
  v: Integer;
  b: Byte;
  i: Integer;
begin
  v := 0;
  for i := 1 to 4 do
  begin
    b := NextB;
    v := v * 128 + (b and $7F);
    if b < $80 then
    begin
      ReadVar := v;
      Exit;
    end;
  end;
  ReadVar := v;
end;

procedure OFlush;
begin
  if on_ > 0 then BlockWrite(fo, ob, 1);
  on_ := 0;
end;

procedure SendPk(d, s, d1, d2: Byte);
begin
  ob[on_] := d; ob[on_ + 1] := s; ob[on_ + 2] := d1; ob[on_ + 3] := d2;
  on_ := on_ + 4;
  if on_ >= 128 then OFlush;
  npk := npk + 1;
  if npk and 63 = 0 then Write('.');
end;

procedure Emit(s, d1, d2: Byte);
begin
  while pending > 255 do
  begin
    SendPk(255, 0, 0, 0);
    pending := pending - 255;
  end;
  SendPk(pending, s, d1, d2);
  pending := 0;
end;

procedure AddDelta(ticks: Integer);
var
  fd: Real;
begin
  fd := ticks * scale + fcarry;
  pending := pending + Trunc(fd);
  fcarry := fd - Trunc(fd);
end;

procedure SetTempo(t: Real);
begin
  scale := t / (division * 16667.0);
end;

procedure PlayTrack;
var
  b, d1, mt: Byte;
  ln, i: Integer;
  tmp: Real;
begin
  playing := True;
  rstatus := 0;
  pending := 0;
  fcarry := 0.0;
  while playing do
  begin
    AddDelta(ReadVar);
    b := NextB;
    if not playing then Exit;
    if b >= $80 then
    begin
      if b < $F0 then
      begin
        rstatus := b;
        b := NextB;
      end
      else if b = $FF then
      begin                          { meta event }
        mt := NextB;
        ln := ReadVar;
        if mt = $2F then Exit;       { end of track }
        if mt = $51 then
        begin
          tmp := 0.0;
          for i := 1 to ln do
            tmp := tmp * 256.0 + NextB;
          SetTempo(tmp);
        end
        else
          for i := 1 to ln do
            mt := NextB;
        rstatus := 0;
        b := 0;                      { handled }
      end
      else
      begin                          { F0/F7 sysex: skip }
        ln := ReadVar;
        for i := 1 to ln do
          mt := NextB;
        rstatus := 0;
        b := 0;
      end;
    end;
    if rstatus >= $80 then
      case rstatus shr 4 of
        $8, $9, $A, $B, $E:
          begin
            d1 := b;
            b := NextB;
            if (rstatus shr 4 = $8) or (rstatus shr 4 = $9) then
              Emit(rstatus, d1, b);  { others: keep the delta, drop it }
          end;
        $C, $D:
          begin
            if rstatus shr 4 = $C then Emit(rstatus, b, 0);
          end;
      end;
  end;
end;

procedure Header;
var
  i, fmt, ntrk: Integer;
  hi, lo: Byte;
begin
  for i := 1 to 8 do hi := NextB;    { MThd + length }
  hi := NextB; lo := NextB; fmt := hi * 256 + lo;
  hi := NextB; lo := NextB; ntrk := hi * 256 + lo;
  hi := NextB; lo := NextB; division := hi * 256.0 + lo;
  if fmt <> 0 then
  begin
    WriteLn('Sorry: only format-0 MIDI files (this is format ', fmt, ').');
    Halt(1);
  end;
  for i := 1 to 8 do hi := NextB;    { MTrk + length }
end;

begin
  WriteLn('MIDCONV - MIDI to SNM packet stream.');
  if ParamCount < 2 then
  begin
    WriteLn('usage: MIDCONV IN.MID OUT.SNM');
    Halt(1);
  end;
  fname := ParamStr(1);
  oname := ParamStr(2);
  Assign(f, fname);
  {$I-}
  Reset(f);
  {$I+}
  if IOResult <> 0 then
  begin
    WriteLn('Cannot open ', fname);
    Halt(1);
  end;
  Assign(fo, oname);
  Rewrite(fo);
  wpos := 0;
  wlen := 0;
  feof := False;
  npk := 0;
  on_ := 0;
  division := 480.0;
  Refill;
  Header;
  SetTempo(500000.0);                { division is known now }
  WriteLn('Converting ', fname, ' -> ', oname);
  PlayTrack;
  SendPk(0, $FF, 0, 0);              { all notes off marker }
  while on_ > 0 do SendPk(0, 0, 0, 0);   { pad the last block }
  Close(fo);
  Close(f);
  WriteLn;
  WriteLn('Done. ', npk, ' packets.');
end.
