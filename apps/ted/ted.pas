program Ted;
{ TED - a controller-first text editor for snes86.
  Modeless, nano-spirit: type to insert, d-pad moves the cursor, Y (Esc)
  opens the menu on the status row - no on-screen-keyboard trips for
  commands. Runs on the standard 108 KB build; saving to B: writes
  battery-backed cartridge SRAM, so edits survive power-off.

  Usage:  TED [file]
  Keys:   arrows / PgUp / PgDn / Home / End   move
          Enter = split line   Backspace / Del = edit and join
          Esc (Y button) = menu: Save / save As / Load / seaRch /
          Goto / Undo line / Quit  (d-pad + Enter, or the hotkey letter)
  Limits: 2000 lines, 255 chars per line, text bounded by free RAM.
  Long lines pan under the cursor (the other rows show columns 1-64);
  TABs display at 8-column stops but stay TAB bytes in the file. }

const
  MAXL = 2000;
  SW = 64;                            { visible columns }
  SLACK = 128;                        { heap paragraphs kept for the stack }
  MenuN = 7;
  MenuS: array[1..MenuN] of string[6] =
    ('Save', 'As', 'Load', 'seaRch', 'Goto', 'Undo', 'Quit');
  MenuK: array[1..MenuN] of Char = ('S', 'A', 'L', 'R', 'G', 'U', 'Q');

type
  TStr = string[255];
  TStr64 = string[64];
  BArr = array[0..254] of Byte;
  PB = ^BArr;
  Regs = record
    AX, BX, CX, DX, BP, SI, DI, DS, ES, Flags: Integer;
  end;

var
  R: Regs;
  LineP: array[1..MAXL] of PB;
  LineL: array[1..MAXL] of Byte;
  NL: Integer;                        { line count, >= 1 once running }
  WStr: TStr;                         { the line under the cursor }
  UStr: TStr;                         { snapshot of it, for Undo }
  WLine, ULine: Integer;
  WDirty, WTab: Boolean;
  CY, CX: Integer;                    { cursor: file line, 1-based column }
  Top: Integer;                       { first visible file line }
  LeftS: Integer;                     { h-pan of the cursor row }
  Modified: Boolean;
  Warn255, WarnMax, WarnMem: Boolean;
  FName: TStr64;
  Handle: Integer;
  IoBuf: array[0..2047] of Byte;
  IoN: Integer;
  IoErr: Boolean;
  StMsg: TStr64;
  Done: Boolean;
  I: Integer;

{ ---------------- BIOS / DOS ---------------- }

function ReadKey: Integer;
begin
  R.AX := $0000; Intr($16, R);
  ReadKey := R.AX;
end;

procedure SetCur(Row, Col: Integer);
begin
  R.AX := $0200; R.BX := 0;
  R.DX := (Row shl 8) + Col;
  Intr($10, R);
end;

procedure TextMode;
begin
  R.AX := $0003; Intr($10, R);
end;

function HeapLow: Boolean;
{ TP3's heap and stack share a segment; running the heap into the stack
  is a crash, so refuse allocations when the cushion gets thin. MemAvail
  is paragraphs in a 16-bit Integer: negative means > 32767 free. }
begin
  HeapLow := (MemAvail >= 0) and (MemAvail < SLACK);
end;

{ ---------------- lines ---------------- }

procedure GetLn(L: Integer; var S: TStr);
begin
  if L = WLine then S := WStr
  else
  begin
    S[0] := Chr(LineL[L]);
    if LineL[L] > 0 then Move(LineP[L]^, S[1], LineL[L]);
  end;
end;

procedure CommitWork;
var
  N: Integer;
begin
  if WDirty and (WLine >= 1) then
  begin
    if LineL[WLine] > 0 then FreeMem(LineP[WLine], LineL[WLine]);
    N := Length(WStr);
    LineL[WLine] := N;
    if N > 0 then
    begin
      GetMem(LineP[WLine], N);
      Move(WStr[1], LineP[WLine]^, N);
    end;
  end;
  WDirty := False;
end;

procedure LoadWork(L: Integer);
var
  K: Integer;
begin
  CommitWork;
  GetLn(L, WStr);
  WLine := L;
  UStr := WStr; ULine := L;
  WDirty := False;
  WTab := False;
  for K := 1 to Length(WStr) do
    if WStr[K] = #9 then WTab := True;
end;

function InsLine(Pos: Integer; var S: TStr): Boolean;
var
  K, N: Integer;
begin
  InsLine := False;
  if (NL >= MAXL) or HeapLow then Exit;
  for K := NL downto Pos do
  begin
    LineP[K + 1] := LineP[K];
    LineL[K + 1] := LineL[K];
  end;
  N := Length(S);
  LineL[Pos] := N;
  if N > 0 then
  begin
    GetMem(LineP[Pos], N);
    Move(S[1], LineP[Pos]^, N);
  end;
  NL := NL + 1;
  if WLine >= Pos then WLine := WLine + 1;
  if ULine >= Pos then ULine := ULine + 1;
  InsLine := True;
end;

procedure DelLine(Pos: Integer);
var
  K: Integer;
begin
  if LineL[Pos] > 0 then FreeMem(LineP[Pos], LineL[Pos]);
  for K := Pos to NL - 1 do
  begin
    LineP[K] := LineP[K + 1];
    LineL[K] := LineL[K + 1];
  end;
  NL := NL - 1;
  if WLine > Pos then WLine := WLine - 1
  else if WLine = Pos then WLine := 0;
  if ULine > Pos then ULine := ULine - 1
  else if ULine = Pos then ULine := 0;
end;

procedure ClearBuf;
var
  K: Integer;
begin
  for K := 1 to NL do
    if LineL[K] > 0 then FreeMem(LineP[K], LineL[K]);
  NL := 0;
  WLine := 0; ULine := 0;
  WDirty := False;
  Modified := False;
end;

{ ---------------- screen ---------------- }

function ScrCol(var S: TStr; UpTo: Integer): Integer;
{ screen column (0-based) of character position UpTo }
var
  K, SC: Integer;
begin
  SC := 0;
  for K := 1 to UpTo - 1 do
    if S[K] = #9 then SC := SC + 8 - (SC mod 8)
    else SC := SC + 1;
  ScrCol := SC;
end;

procedure DrawR(Row, L: Integer);
{ paint screen row Row (0..23) from file line L; 0 = blank row.
  The cursor row honors LeftS; other rows always start at column 1. }
var
  S: TStr;
  Base, LS, SC, K, N, C, Cell: Integer;
begin
  Base := Row * 160;
  if (L < 1) or (L > NL) then
  begin
    for K := 0 to SW - 1 do MemW[$B800:Base + K + K] := $0720;
    Exit;
  end;
  GetLn(L, S);
  if L = CY then LS := LeftS else LS := 0;
  SC := 0;
  K := 1;
  while (K <= Length(S)) and (SC < LS + SW) do
  begin
    C := Ord(S[K]);
    if C = 9 then
    begin
      N := 8 - (SC mod 8);
      while (N > 0) and (SC < LS + SW) do
      begin
        if SC >= LS then MemW[$B800:Base + (SC - LS) * 2] := $0720;
        SC := SC + 1;
        N := N - 1;
      end;
    end
    else
    begin
      if SC >= LS then MemW[$B800:Base + (SC - LS) * 2] := $0700 + C;
      SC := SC + 1;
    end;
    K := K + 1;
  end;
  Cell := SC - LS;
  if Cell < 0 then Cell := 0;
  while Cell < SW do
  begin
    MemW[$B800:Base + Cell + Cell] := $0720;
    Cell := Cell + 1;
  end;
end;

procedure DrawL(L: Integer);
begin
  if (L >= Top) and (L <= Top + 23) then DrawR(L - Top, L);
end;

procedure FullDraw;
var
  K: Integer;
begin
  for K := 0 to 23 do DrawR(K, Top + K);
end;

procedure DrawFrom(L: Integer);
{ repaint rows for file lines L..bottom of the window }
var
  K: Integer;
begin
  if L < Top then L := Top;
  for K := L - Top to 23 do DrawR(K, Top + K);
end;

procedure FastTail(FromCol: Integer);
{ cursor row, no tabs, no pan, line fits: repaint cols FromCol..len+1 }
var
  Base, K, N: Integer;
begin
  Base := (CY - Top) * 160;
  N := Length(WStr);
  for K := FromCol to N do
    MemW[$B800:Base + (K - 1) * 2] := $0700 + Ord(WStr[K]);
  if N < SW then MemW[$B800:Base + N + N] := $0720;
end;

procedure PutStatus(var S: TStr);
var
  K, C: Integer;
begin
  for K := 0 to SW - 1 do
  begin
    if K < Length(S) then C := Ord(S[K + 1]) else C := 32;
    MemW[$B800:24 * 160 + K + K] := $7000 + C;
  end;
end;

procedure DrawStatus;
var
  S: TStr;
  T: TStr64;
begin
  S := ' ';
  if FName = '' then S := S + '(no file)' else S := S + FName;
  if Modified then S := S + ' *';
  Str(CY, T); S := S + '  Ln ' + T;
  Str(CX, T); S := S + ' Col ' + T;
  if StMsg <> '' then S := S + '  ' + StMsg;
  while Length(S) < SW - 7 do S := S + ' ';
  S := S + 'Y=menu';
  PutStatus(S);
end;

procedure PlaceCursor;
var
  SC, Old: Integer;
begin
  if WTab then SC := ScrCol(WStr, CX) else SC := CX - 1;
  Old := LeftS;
  if SC < LeftS then
  begin
    LeftS := SC - 16;
    if LeftS < 0 then LeftS := 0;
  end;
  if SC >= LeftS + SW then LeftS := SC - SW + 1;
  if LeftS <> Old then DrawR(CY - Top, CY);
  SetCur(CY - Top, SC - LeftS);
end;

procedure ScrollUp1;
{ window moves down the file by one: rows 1..23 -> 0..22, draw new 23 }
type
  TChunk = array[0..1839] of Integer;
  PChunk = ^TChunk;
var
  A, B: PChunk;
begin
  A := Ptr($B800, 160);
  B := Ptr($B800, 0);
  Move(A^, B^, 23 * 160);              { dest < src: ascending-safe }
  Top := Top + 1;
  DrawR(23, Top + 23);
end;

procedure ScrollDn1;
type
  TRow = array[0..79] of Integer;
  PRow = ^TRow;
var
  A, B: PRow;
  K: Integer;
begin
  for K := 23 downto 1 do
  begin
    A := Ptr($B800, (K - 1) * 160);
    B := Ptr($B800, K * 160);
    Move(A^, B^, 160);
  end;
  Top := Top - 1;
  DrawR(0, Top);
end;

{ ---------------- cursor motion ---------------- }

procedure GoLine(L: Integer);
var
  OldCY, OldLS: Integer;
begin
  if L < 1 then L := 1;
  if L > NL then L := NL;
  if L = CY then Exit;
  OldCY := CY; OldLS := LeftS;
  LoadWork(L);
  CY := L;
  LeftS := 0;
  if CX > Length(WStr) + 1 then CX := Length(WStr) + 1;
  if CY < Top then
  begin
    if Top - CY = 1 then ScrollDn1
    else
    begin
      Top := CY;
      FullDraw;
    end;
  end
  else if CY > Top + 23 then
  begin
    if CY - Top = 24 then ScrollUp1
    else
    begin
      Top := CY - 23;
      FullDraw;
    end;
  end;
  if OldLS <> 0 then DrawL(OldCY);     { un-pan the row we left }
end;

{ ---------------- editing ---------------- }

procedure DoInsert(C: Char);
begin
  if Length(WStr) >= 255 then
  begin
    StMsg := 'line full';
    Exit;
  end;
  Insert(C, WStr, CX);
  CX := CX + 1;
  if C = #9 then WTab := True;
  WDirty := True; Modified := True;
  if WTab or (LeftS > 0) or (Length(WStr) > SW) then DrawR(CY - Top, CY)
  else FastTail(CX - 1);
end;

procedure DoEnter;
var
  TailS: TStr;
begin
  TailS := Copy(WStr, CX, 255);
  WStr[0] := Chr(CX - 1);
  WDirty := True;
  CommitWork;
  if not InsLine(CY + 1, TailS) then
  begin
    GetLn(CY, WStr);                   { restore the split }
    WStr := WStr + TailS;
    WDirty := True;
    StMsg := 'no room';
    Exit;
  end;
  Modified := True;
  CY := CY + 1;
  CX := 1;
  LeftS := 0;
  LoadWork(CY);
  if CY > Top + 23 then ScrollUp1;
  DrawFrom(CY - 1);
end;

procedure JoinInto(L: Integer);
{ append line L+1 onto line L; cursor ends at the seam }
var
  TailS: TStr;
  SeamC: Integer;
begin
  GetLn(L + 1, TailS);
  if L = WLine then SeamC := Length(WStr) else SeamC := LineL[L];
  if SeamC + Length(TailS) > 255 then
  begin
    StMsg := 'too long to join';
    Exit;
  end;
  if WLine <> L then
  begin
    CommitWork;
    LoadWork(L);
  end;
  CY := L;
  CX := SeamC + 1;
  WStr := WStr + TailS;
  WDirty := True; Modified := True;
  WTab := False;
  for SeamC := 1 to Length(WStr) do
    if WStr[SeamC] = #9 then WTab := True;
  DelLine(L + 1);
  DrawFrom(CY);
end;

procedure DoBackspace;
var
  T: Integer;
begin
  if CX > 1 then
  begin
    Delete(WStr, CX - 1, 1);
    CX := CX - 1;
    WDirty := True; Modified := True;
    if WTab or (LeftS > 0) or (Length(WStr) >= SW) then DrawR(CY - Top, CY)
    else FastTail(CX - 1);
  end
  else if CY > 1 then
  begin
    T := CY - 1;
    if T < Top then GoLine(T);
    JoinInto(T);
  end;
end;

procedure DoDel;
begin
  if CX <= Length(WStr) then
  begin
    Delete(WStr, CX, 1);
    WDirty := True; Modified := True;
    if WTab or (LeftS > 0) or (Length(WStr) >= SW) then DrawR(CY - Top, CY)
    else FastTail(CX);
  end
  else if CY < NL then JoinInto(CY);
end;

{ ---------------- file I/O ---------------- }

procedure IoFlush;
begin
  if IoN > 0 then
  begin
    R.AX := $4000; R.BX := Handle; R.CX := IoN;
    R.DS := DSeg; R.DX := Ofs(IoBuf);
    MsDos(R);
    if ((R.Flags and 1) <> 0) or (R.AX < IoN) then IoErr := True;
    IoN := 0;
  end;
end;

procedure IoPut(B: Byte);
begin
  IoBuf[IoN] := B;
  IoN := IoN + 1;
  if IoN = 2048 then IoFlush;
end;

function SaveFile(var Nm: TStr64): Boolean;
var
  L, K: Integer;
  S: TStr;
  Z: TStr64;
begin
  SaveFile := False;
  CommitWork;
  Z := Nm + #0;
  R.AX := $3C00; R.CX := 0;
  R.DS := Seg(Z); R.DX := Ofs(Z[1]);   { Z is a local: SS-based, not DS }
  MsDos(R);
  if (R.Flags and 1) <> 0 then
  begin
    StMsg := 'cannot create ' + Nm;
    Exit;
  end;
  Handle := R.AX;
  IoN := 0; IoErr := False;
  for L := 1 to NL do
  begin
    GetLn(L, S);
    for K := 1 to Length(S) do IoPut(Ord(S[K]));
    IoPut(13); IoPut(10);
  end;
  IoFlush;
  R.AX := $3E00; R.BX := Handle; MsDos(R);
  if IoErr then StMsg := 'write failed (disk full?)'
  else
  begin
    Modified := False;
    StMsg := 'saved ' + Nm;
    SaveFile := True;
  end;
end;

procedure AddRead(var S: TStr);
begin
  if NL >= MAXL then WarnMax := True
  else if HeapLow then WarnMem := True
  else
  begin
    NL := NL + 1;
    LineL[NL] := Length(S);
    if Length(S) > 0 then
    begin
      GetMem(LineP[NL], Length(S));
      Move(S[1], LineP[NL]^, Length(S));
    end;
  end;
end;

procedure ReadFile(var Nm: TStr64);
var
  Cur: TStr;
  N, K, C: Integer;
  Z: TStr64;
  Stop: Boolean;
begin
  ClearBuf;
  Warn255 := False; WarnMax := False; WarnMem := False;
  Z := Nm + #0;
  R.AX := $3D00;
  R.DS := Seg(Z); R.DX := Ofs(Z[1]);
  MsDos(R);
  if (R.Flags and 1) <> 0 then
  begin
    StMsg := 'new file';
    NL := 1; LineL[1] := 0;
    Exit;
  end;
  Handle := R.AX;
  Cur := '';
  Stop := False;
  repeat
    R.AX := $3F00; R.BX := Handle; R.CX := 2048;
    R.DS := DSeg; R.DX := Ofs(IoBuf);
    MsDos(R);
    if (R.Flags and 1) <> 0 then N := 0 else N := R.AX;
    K := 0;
    while (K < N) and not Stop do
    begin
      C := IoBuf[K];
      if C = 10 then
      begin
        AddRead(Cur);
        Cur[0] := #0;
      end
      else if C <> 13 then
      begin
        if Length(Cur) = 255 then
        begin
          Warn255 := True;
          AddRead(Cur);
          Cur[0] := #0;
        end;
        Cur[0] := Chr(Length(Cur) + 1);
        Cur[Length(Cur)] := Chr(C);
      end;
      if WarnMax or WarnMem then Stop := True;
      K := K + 1;
    end;
  until (N < 2048) or Stop;
  R.AX := $3E00; R.BX := Handle; MsDos(R);
  if (Length(Cur) > 0) or (NL = 0) then AddRead(Cur);
  if NL = 0 then
  begin
    NL := 1;
    LineL[1] := 0;
  end;
  if WarnMax or WarnMem then StMsg := 'TRUNCATED (too big)'
  else if Warn255 then StMsg := 'long lines were split'
  else StMsg := 'loaded';
end;

{ ---------------- prompts and menu ---------------- }

function PromptS(Lbl: TStr64; var S: TStr64): Boolean;
var
  P: TStr;
  K, AL: Integer;
  Fin: Boolean;
begin
  PromptS := False;
  Fin := False;
  repeat
    P := ' ' + Lbl + S + '_';
    PutStatus(P);
    K := ReadKey;
    AL := K and $FF;
    if AL = 13 then
    begin
      PromptS := True;
      Fin := True;
    end
    else if AL = 27 then Fin := True
    else if AL = 8 then
    begin
      if Length(S) > 0 then S[0] := Chr(Length(S) - 1);
    end
    else if (AL >= 32) and (Length(S) < 40) then
      S := S + Chr(AL);
  until Fin;
end;

function Confirm(Msg: TStr64): Boolean;
var
  P: TStr;
  K, AL: Integer;
begin
  P := ' ' + Msg + ' START=yes  Y-btn=no';
  PutStatus(P);
  Confirm := False;
  repeat
    K := ReadKey;
    AL := K and $FF;
    if (AL = 13) or (AL = Ord('y')) or (AL = Ord('Y')) then
    begin
      Confirm := True;
      Exit;
    end;
  until (AL = 27) or (AL = Ord('n')) or (AL = Ord('N'));
end;

procedure DoSearch;
var
  Term: TStr64;
  S: TStr;
  L, P, Cnt: Integer;
  Hit: Boolean;
begin
  Term := '';
  if not PromptS('Find: ', Term) then Exit;
  if Term = '' then Exit;
  CommitWork;
  Hit := False;
  L := CY;
  Cnt := 0;
  while (Cnt < NL) and not Hit do
  begin
    L := L + 1;
    if L > NL then L := 1;
    GetLn(L, S);
    P := Pos(Term, S);
    if P > 0 then Hit := True;
    Cnt := Cnt + 1;
  end;
  if Hit then
  begin
    GoLine(L);
    CX := P;
    StMsg := 'found';
  end
  else StMsg := 'not found';
end;

procedure DoGoto;
var
  NS: TStr64;
  V, Code: Integer;
begin
  NS := '';
  if not PromptS('Line: ', NS) then Exit;
  Val(NS, V, Code);
  if Code = 0 then
  begin
    GoLine(V);
    CX := 1;
  end;
end;

procedure DoLoad;
var
  Nm: TStr64;
begin
  if Modified then
    if not Confirm('Discard changes?') then Exit;
  Nm := FName;
  if not PromptS('Load: ', Nm) then Exit;
  if Nm = '' then Exit;
  FName := Nm;
  ReadFile(FName);
  CY := 1; CX := 1; Top := 1; LeftS := 0;
  LoadWork(1);
  FullDraw;
end;

procedure DoSaveAs;
var
  Nm: TStr64;
begin
  Nm := FName;
  if not PromptS('Save as: ', Nm) then Exit;
  if Nm = '' then Exit;
  if SaveFile(Nm) then FName := Nm;
end;

procedure DoUndo;
begin
  if (ULine = CY) and (WLine = CY) then
  begin
    WStr := UStr;
    WDirty := True; Modified := True;
    WTab := False;
    for I := 1 to Length(WStr) do
      if WStr[I] = #9 then WTab := True;
    if CX > Length(WStr) + 1 then CX := Length(WStr) + 1;
    DrawR(CY - Top, CY);
    StMsg := 'line restored';
  end
  else StMsg := 'nothing to undo';
end;

procedure ExecMenu(Sel: Integer);
begin
  if Sel = 1 then
  begin
    if FName = '' then DoSaveAs
    else if SaveFile(FName) then;
  end
  else if Sel = 2 then DoSaveAs
  else if Sel = 3 then DoLoad
  else if Sel = 4 then DoSearch
  else if Sel = 5 then DoGoto
  else if Sel = 6 then DoUndo
  else if Sel = 7 then
  begin
    if Modified then
    begin
      if Confirm('Unsaved changes - quit?') then Done := True;
    end
    else Done := True;
  end;
end;

procedure DoMenu;
var
  Sel, K, AL, AH2, M: Integer;
  P: TStr;
  Fin: Boolean;
  C: Char;
begin
  Sel := 1;
  Fin := False;
  repeat
    P := ' ';
    for M := 1 to MenuN do
    begin
      if M = Sel then P := P + '[' + MenuS[M] + ']'
      else P := P + ' ' + MenuS[M] + ' ';
    end;
    PutStatus(P);
    K := ReadKey;
    AL := K and $FF;
    AH2 := (K shr 8) and $FF;
    if AL = 27 then Fin := True
    else if AL = 13 then
    begin
      ExecMenu(Sel);
      Fin := True;
    end
    else if AL = 0 then
    begin
      if AH2 = $4B then
      begin
        Sel := Sel - 1;
        if Sel < 1 then Sel := MenuN;
      end
      else if AH2 = $4D then
      begin
        Sel := Sel + 1;
        if Sel > MenuN then Sel := 1;
      end;
    end
    else
    begin
      C := UpCase(Chr(AL));
      for M := 1 to MenuN do
        if C = MenuK[M] then
        begin
          ExecMenu(M);
          Fin := True;
        end;
    end;
  until Fin;
end;

{ ---------------- main ---------------- }

var
  K, AL, AH2: Integer;

begin
  NL := 0;
  WLine := 0; ULine := 0;
  WDirty := False; WTab := False;
  Modified := False; Done := False;
  IoN := 0;
  LeftS := 0;
  StMsg := '';
  TextMode;
  FName := '';
  if ParamCount >= 1 then FName := ParamStr(1);
  if FName <> '' then ReadFile(FName)
  else
  begin
    NL := 1;
    LineL[1] := 0;
    StMsg := 'new buffer';
  end;
  CY := 1; CX := 1; Top := 1;
  LoadWork(1);
  FullDraw;
  DrawStatus;
  PlaceCursor;
  repeat
    K := ReadKey;
    StMsg := '';
    AL := K and $FF;
    AH2 := (K shr 8) and $FF;
    if AL = 27 then DoMenu
    else if AL = 13 then DoEnter
    else if AL = 8 then DoBackspace
    else if (AL = 9) or (AL >= 32) then DoInsert(Chr(AL))
    else if AL = 0 then
    begin
      if AH2 = $48 then GoLine(CY - 1)
      else if AH2 = $50 then GoLine(CY + 1)
      else if AH2 = $4B then
      begin
        if CX > 1 then CX := CX - 1
        else if CY > 1 then
        begin
          GoLine(CY - 1);
          CX := Length(WStr) + 1;
        end;
      end
      else if AH2 = $4D then
      begin
        if CX <= Length(WStr) then CX := CX + 1
        else if CY < NL then
        begin
          GoLine(CY + 1);
          CX := 1;
        end;
      end
      else if AH2 = $47 then CX := 1
      else if AH2 = $4F then CX := Length(WStr) + 1
      else if AH2 = $49 then GoLine(CY - 23)
      else if AH2 = $51 then GoLine(CY + 23)
      else if AH2 = $53 then DoDel;
    end;
    DrawStatus;
    PlaceCursor;
  until Done;
  TextMode;
end.
