program Sokoban;
{ Sokoban for snes86 - CGA mode 4 (320x200x4), direct B800 rendering. }
{ Compiled with Turbo Pascal 3.01 on the machine itself.              }
{ Keys: arrows or WASD move, R restart, N next, Q quit.               }

const
  NLev = 5;
  LRow: array[1..6] of Integer = (1, 4, 7, 12, 16, 22);  { start row, +sentinel }
  LDat: array[1..26] of string[8] = (
    '######',      { 1: two steps right }
    '#@ $.#',
    '######',
    '#######',     { 2: three left }
    '#. $ @#',
    '#######',
    '#####',       { 3: one up }
    '#.  #',
    '#$  #',
    '#@  #',
    '#####',
    '#######',     { 4: split pair }
    '#.$ $.#',
    '#  @  #',
    '#######',
    '######',      { 5: the corner tour }
    '#   .#',
    '#@$  #',
    '# $  #',
    '#  . #',
    '######',
    '',            { pad to 26 }
    '', '', '', '');

type
  Str40 = string[40];
  RegPack = record
    AX, BX, CX, DX, BP, SI, DI, DS, ES, Flags: Integer;
  end;

var
  R: RegPack;
  Wall, Goal, Box: array[0..10, 0..11] of Boolean;
  BH, BW, PX, PY: Integer;             { board dims, player (col,row) }
  Lev, Moves, XO, YO: Integer;         { level, moves, pixel origin   }
  Done: Boolean;

procedure VMode(m: Integer);
begin
  R.AX := m; Intr($10, R);
end;

procedure Bright;                      { 3D9 bit4: light green/red/yellow }
begin
  Port[$3D9] := $10;
end;

function GetKey: Integer;              { INT16 AH=0 -> scan<<8 | ascii }
begin
  R.AX := 0; Intr($16, R);
  GetKey := R.AX;
end;

procedure CellLine(ofs, w1, w2: Integer);
begin
  MemW[$B800:ofs] := w1; MemW[$B800:ofs + 2] := w2;
end;

procedure DrawCell(cx, cy: Integer);
var
  l, y, ofs, w1, w2: Integer;
  pl, bx: Boolean;
begin
  pl := (cx = PX) and (cy = PY);
  bx := Box[cy, cx];
  for l := 0 to 15 do
  begin
    y := YO + cy * 16 + l;
    ofs := (y and 1) * 8192 + (y shr 1) * 80 + XO + cx * 4;
    w1 := 0; w2 := 0;
    if Wall[cy, cx] then
    begin
      if (l = 0) or (l = 15) then begin w1 := $FFFF; w2 := $FFFF; end
      else begin w1 := $55D5; w2 := $5755; end
    end
    else if bx then
    begin
      if (l >= 2) and (l <= 13) then
        if Goal[cy, cx] then begin w1 := $FF0F; w2 := $F0FF; end
        else begin w1 := $AA0A; w2 := $A0AA; end
    end
    else if pl then
    begin
      if (l >= 2) and (l <= 5) then begin w1 := $0F00; w2 := $00F0; end
      else if (l >= 6) and (l <= 13) then begin w1 := $FF00; w2 := $00FF; end
    end
    else if Goal[cy, cx] then
    begin
      if (l >= 7) and (l <= 8) then begin w1 := $5700; w2 := $00D5; end
    end;
    CellLine(ofs, w1, w2);
  end;
end;

procedure Say(s: Str40; row: Integer);
var
  i: Integer;
begin
  R.AX := $0200; R.BX := 0; R.DX := row shl 8; Intr($10, R);
  for i := 1 to Length(s) do
  begin
    R.AX := $0E00 + Ord(s[i]); R.BX := 3; Intr($10, R);
  end;
end;

procedure Status;
var
  s: string[40];
  t: string[6];
begin
  Str(Lev, t); s := 'LEVEL ' + t;
  Str(Moves, t); s := s + '   MOVES ' + t;
  s := s + '   R RESTART  Q QUIT';
  Say(s, 24);
end;

procedure LoadLevel;
var
  r0, y, x: Integer;
  c: Char;
begin
  r0 := LRow[Lev];
  BH := LRow[Lev + 1] - r0;
  BW := 0;
  for y := 0 to BH - 1 do
    if Length(LDat[r0 + y]) > BW then BW := Length(LDat[r0 + y]);
  for y := 0 to 10 do
    for x := 0 to 11 do
    begin
      Wall[y, x] := False; Goal[y, x] := False; Box[y, x] := False;
    end;
  for y := 0 to BH - 1 do
    for x := 1 to Length(LDat[r0 + y]) do
    begin
      c := LDat[r0 + y][x];
      case c of
        '#': Wall[y, x - 1] := True;
        '.': Goal[y, x - 1] := True;
        '$': Box[y, x - 1] := True;
        '*': begin Goal[y, x - 1] := True; Box[y, x - 1] := True; end;
        '@': begin PX := x - 1; PY := y; end;
        '+': begin Goal[y, x - 1] := True; PX := x - 1; PY := y; end;
      end;
    end;
  Moves := 0;
  XO := (80 - BW * 4) div 2;           { centre: bytes per line }
  YO := (184 - BH * 16) div 2;
  VMode(4);
  Bright;
  for y := 0 to BH - 1 do
    for x := 0 to BW - 1 do DrawCell(x, y);
  Status;
end;

function Solved: Boolean;
var
  y, x: Integer;
begin
  Solved := True;
  for y := 0 to BH - 1 do
    for x := 0 to BW - 1 do
      if Box[y, x] and not Goal[y, x] then Solved := False;
end;

procedure TryMove(dx, dy: Integer);
var
  nx, ny, bx, by: Integer;
begin
  nx := PX + dx; ny := PY + dy;
  if Wall[ny, nx] then Exit;
  if Box[ny, nx] then
  begin
    bx := nx + dx; by := ny + dy;
    if Wall[by, bx] or Box[by, bx] then Exit;
    Box[ny, nx] := False; Box[by, bx] := True;
  end;
  PX := nx; PY := ny;
  Moves := Moves + 1;
  DrawCell(nx - dx, ny - dy); DrawCell(nx, ny);
  DrawCell(nx + dx, ny + dy);
  Status;
end;

procedure Play;
var
  k, sc: Integer;
  c: Char;
begin
  LoadLevel;
  Done := False;
  repeat
    k := GetKey;
    sc := Hi(k); c := UpCase(Chr(Lo(k)));
    if (sc = $48) or (c = 'W') then TryMove(0, -1)
    else if (sc = $50) or (c = 'S') then TryMove(0, 1)
    else if (sc = $4B) or (c = 'A') then TryMove(-1, 0)
    else if (sc = $4D) or (c = 'D') then TryMove(1, 0)
    else if c = 'R' then LoadLevel
    else if c = 'N' then begin Lev := Lev mod NLev + 1; LoadLevel; end
    else if c = 'Q' then begin Done := True; Exit; end;
    if Solved then
    begin
      if Lev = NLev then
      begin
        Say('ALL LEVELS SOLVED - WELL DONE!', 11);
        k := GetKey;
        Done := True; Exit;
      end;
      Say('LEVEL COMPLETE!', 11);
      k := GetKey;
      Lev := Lev + 1;
      LoadLevel;
    end;
  until Done;
end;

begin
  Lev := 1;
  Play;
  VMode(3);                            { back to the DOS prompt }
end.
