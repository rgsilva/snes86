{ JAVA3.INC - resolution and the bytecode dispatch loop.
  Resolution compares constant-pool Utf8 strings once per call site and
  caches the verdict in ShimC[], so steady-state dispatch never touches
  a string. Same-class references are recognized by comparing the
  class index against ThisCp - javac shares the cp entry. }

procedure FailCP(CP: Integer);        { die naming the culprit member }
var
  NatO: Integer;
begin
  NatO := CpOfs[U2(CpOfs[CP] + 2)];
  Write('JAVA: unsupported: ');
  OutUtf(U2(NatO));
  OutUtf(U2(NatO + 2));
  WriteLn;
  Halt;
end;

procedure Push(H, L: Integer);
begin
  SP := SP + 1;
  if SP > STKSZ then Fail('stack overflow');
  SHi[SP] := H; SLo[SP] := L;
end;

procedure PushI(V: Integer);
begin
  if V < 0 then Push(-1, V) else Push(0, V);
end;

procedure ChkArr(H, L: Integer);
begin
  if H <> $7F01 then Fail('not an array');
  if (L < 1) or (L > ACount) then Fail('bad array handle');
end;

function ShimOf(CP: Integer): Integer;
{ classify a Methodref/Fieldref cp entry into a shim id:
   1 println(String)  2 println(int)  3 print(char)  4 print(String)
   5 println()        6 in.read      7 SB <init>     8 SB append(Str)
   9 SB append(int)  10 SB append(char)  11 SB toString  12 Object <init>
   20+k static field k   40+m our method m   0 unknown }
var
  ClsU, NatO, NmU, DcU, K, ClsCp: Integer;
begin
  ShimOf := 0;
  ClsCp := U2(CpOfs[CP]);
  NatO := CpOfs[U2(CpOfs[CP] + 2)];
  NmU := U2(NatO);
  DcU := U2(NatO + 2);
  if ClsCp = ThisCp then
  begin
    if CpTag[CP] = 9 then             { our static field }
    begin
      for K := 1 to SFCount do
        if SFName[K] = NmU then
        begin
          ShimOf := 20 + K;
          Exit;
        end;
      Fail('unknown field');
    end
    else
    begin
      for K := 1 to MCount do
        if (MName[K] = NmU) and (MDesc[K] = DcU) then
        begin
          ShimOf := 40 + K;
          Exit;
        end;
      Fail('unknown method');
    end;
  end;
  ClsU := U2(CpOfs[ClsCp]);
  if UtfIs(ClsU, 'java/lang/System') then
  begin
    if UtfIs(NmU, 'out') then ShimOf := 13
    else if UtfIs(NmU, 'in') then ShimOf := 14;
    Exit;
  end;
  if UtfIs(ClsU, 'java/io/PrintStream') then
  begin
    if UtfIs(NmU, 'println') then
    begin
      if UtfIs(DcU, '(Ljava/lang/String;)V') then ShimOf := 1
      else if UtfIs(DcU, '(I)V') then ShimOf := 2
      else if UtfIs(DcU, '(C)V') then ShimOf := 3
      else if UtfIs(DcU, '()V') then ShimOf := 5;
    end
    else if UtfIs(NmU, 'print') then
    begin
      if UtfIs(DcU, '(C)V') then ShimOf := 3
      else if UtfIs(DcU, '(Ljava/lang/String;)V') then ShimOf := 4
      else if UtfIs(DcU, '(I)V') then ShimOf := 2;
    end;
    Exit;
  end;
  if UtfIs(ClsU, 'java/io/InputStream') then
  begin
    if UtfIs(NmU, 'read') then ShimOf := 6;
    Exit;
  end;
  if UtfIs(ClsU, 'java/lang/StringBuilder') then
  begin
    if UtfIs(NmU, '<init>') then ShimOf := 7
    else if UtfIs(NmU, 'append') then
    begin
      if UtfIs(DcU, '(Ljava/lang/String;)Ljava/lang/StringBuilder;') then
        ShimOf := 8
      else if UtfIs(DcU, '(I)Ljava/lang/StringBuilder;') then ShimOf := 9
      else if UtfIs(DcU, '(C)Ljava/lang/StringBuilder;') then ShimOf := 10;
    end
    else if UtfIs(NmU, 'toString') then ShimOf := 11;
    Exit;
  end;
  if UtfIs(ClsU, 'java/lang/Object') then
  begin
    if UtfIs(NmU, '<init>') then ShimOf := 12;
    Exit;
  end;
end;

function Shim(CP: Integer): Integer;
begin
  if ShimC[CP] = 0 then ShimC[CP] := ShimOf(CP);
  Shim := ShimC[CP];
end;

procedure CallLocal(M: Integer);
var
  K: Integer;
begin
  if MCode[M] = 0 then Fail('abstract method');
  FP := FP + 1;
  if FP > MAXFRM then Fail('call stack overflow');
  FrPC[FP] := PC; FrM[FP] := CurM; FrLB[FP] := LB;
  LB := LTop;
  LTop := LTop + MMaxL[M];
  if LTop > LOCSZ then Fail('locals overflow');
  for K := MArgs[M] - 1 downto 0 do
  begin
    LHi[LB + K] := SHi[SP]; LLo[LB + K] := SLo[SP];
    SP := SP - 1;
  end;
  CurM := M;
  PC := MCode[M];
end;

procedure Ret(HasV: Boolean);
var
  H, L: Integer;
begin
  if HasV then
  begin
    H := SHi[SP]; L := SLo[SP]; SP := SP - 1;
  end;
  if FP = 0 then
  begin
    Running := False;
    Exit;
  end;
  LTop := LB;
  PC := FrPC[FP]; CurM := FrM[FP]; LB := FrLB[FP];
  FP := FP - 1;
  if HasV then Push(H, L);
end;

procedure DoShim(SH: Integer; Virt: Boolean);
{ run shim SH; Virt = invokevirtual/special (objectref under the args) }
var
  AH, AL2, K: Integer;
begin
  case SH of
    1, 4: begin                       { println/print (String) }
            AH := SHi[SP]; AL2 := SLo[SP]; SP := SP - 2;
            OutRef(AH, AL2);
            if SH = 1 then WriteLn;
          end;
    2: begin                          { println/print (int) }
         I32Str(SHi[SP], SLo[SP]); SP := SP - 2;
         Write(S16);
         WriteLn;
       end;
    3: begin                          { print/println (char) }
         OutCh(SLo[SP] and $FF); SP := SP - 2;
       end;
    5: begin SP := SP - 1; WriteLn end;
    6: begin SP := SP - 1; PushI(KeyIn) end;
    7: begin                          { StringBuilder <init> }
         SP := SP - 1;                { pops the dup'd ref }
       end;
    8: begin                          { append(String) }
         AH := SHi[SP]; AL2 := SLo[SP]; SP := SP - 1;
         if AH = $7F02 then SBAddUtf(SLo[SP], AL2)
         else if (AH = $7F03) or (AH = $7F04) then
           for K := 0 to SBLen[AL2] - 1 do SBAddCh(SLo[SP], SBBuf[AL2, K])
         else Fail('append: not a string');
       end;                           { SB ref stays on the stack }
    9: begin                          { append(int) }
         I32Str(SHi[SP], SLo[SP]); SP := SP - 1;
         SBAddStr(SLo[SP]);
       end;
    10: begin                         { append(char) }
          AL2 := SLo[SP] and $FF; SP := SP - 1;
          SBAddCh(SLo[SP], AL2);
        end;
    11: SHi[SP] := $7F04;             { toString: same slot, now a string }
    12: SP := SP - 1;                 { Object.<init> }
  else
    Fail('unsupported library call');
  end;
end;

procedure Run;
var
  B: Byte;
  OpPC, V, H, L, K, SH: Integer;
begin
  while Running do
  begin
    OpPC := PC;
    B := Buf[PC];
    PC := PC + 1;
    case B of
      0: ;                                          { nop }
      1: Push(0, 0);                                { aconst_null }
      2, 3, 4, 5, 6, 7, 8: PushI(B - 3);            { iconst_m1..5 }
      16: begin                                     { bipush }
            V := Buf[PC]; PC := PC + 1;
            if V > 127 then V := V - 256;
            PushI(V);
          end;
      17: begin PushI(U2(PC)); PC := PC + 2 end;    { sipush }
      18: begin                                     { ldc }
            V := Buf[PC]; PC := PC + 1;
            case CpTag[V] of
              8: Push($7F02, U2(CpOfs[V]));
              3: Push(U2(CpOfs[V]), U2(CpOfs[V] + 2));
            else
              Fail('ldc: unsupported constant');
            end;
          end;
      21, 25: begin                                 { iload/aload }
                V := Buf[PC]; PC := PC + 1;
                Push(LHi[LB + V], LLo[LB + V]);
              end;
      26, 27, 28, 29: Push(LHi[LB + B - 26], LLo[LB + B - 26]);
      42, 43, 44, 45: Push(LHi[LB + B - 42], LLo[LB + B - 42]);
      54, 58: begin                                 { istore/astore }
                V := Buf[PC]; PC := PC + 1;
                LHi[LB + V] := SHi[SP]; LLo[LB + V] := SLo[SP];
                SP := SP - 1;
              end;
      59, 60, 61, 62: begin
                        LHi[LB + B - 59] := SHi[SP];
                        LLo[LB + B - 59] := SLo[SP];
                        SP := SP - 1;
                      end;
      75, 76, 77, 78: begin
                        LHi[LB + B - 75] := SHi[SP];
                        LLo[LB + B - 75] := SLo[SP];
                        SP := SP - 1;
                      end;
      46, 51: begin                                 { iaload/baload }
                V := SLo[SP]; SP := SP - 1;         { index }
                ChkArr(SHi[SP], SLo[SP]);
                K := SLo[SP]; SP := SP - 1;
                if (V < 0) or (Cmp32(0, V, 0, ALen[K]) >= 0) then
                  Fail('array index out of bounds');
                if B = 51 then
                begin
                  L := Heap[AOfs[K] + V];
                  Push(0, L);
                end
                else
                begin
                  V := AOfs[K] + V * 4;
                  Push(Heap[V + 2] or (Heap[V + 3] shl 8),
                       Heap[V] or (Heap[V + 1] shl 8));
                end;
              end;
      79, 84: begin                                 { iastore/bastore }
                H := SHi[SP]; L := SLo[SP]; SP := SP - 1;
                V := SLo[SP]; SP := SP - 1;
                ChkArr(SHi[SP], SLo[SP]);
                K := SLo[SP]; SP := SP - 1;
                if (V < 0) or (V >= ALen[K]) then
                  Fail('array index out of bounds');
                if B = 84 then Heap[AOfs[K] + V] := L and $FF
                else
                begin
                  V := AOfs[K] + V * 4;
                  Heap[V] := L and $FF;
                  Heap[V + 1] := (L shr 8) and $FF;
                  Heap[V + 2] := H and $FF;
                  Heap[V + 3] := (H shr 8) and $FF;
                end;
              end;
      87: SP := SP - 1;                             { pop }
      89: begin                                     { dup }
            Push(SHi[SP], SLo[SP]);
          end;
      96, 100, 104: begin                           { iadd/isub/imul }
                      VHB := SHi[SP]; VLB := SLo[SP]; SP := SP - 1;
                      VHA := SHi[SP]; VLA := SLo[SP];
                      case B of
                        96: AddV;
                        100: SubV;
                        104: MulV;
                      end;
                      SHi[SP] := VHA; SLo[SP] := VLA;
                    end;
      116: begin                                    { ineg }
             VHB := SHi[SP]; VLB := SLo[SP];
             VHA := 0; VLA := 0;
             SubV;
             SHi[SP] := VHA; SLo[SP] := VLA;
           end;
      132: begin                                    { iinc }
             V := Buf[PC];
             K := Buf[PC + 1];
             PC := PC + 2;
             if K > 127 then K := K - 256;
             VHA := LHi[LB + V]; VLA := LLo[LB + V];
             if K < 0 then VHB := -1 else VHB := 0;
             VLB := K;
             AddV;
             LHi[LB + V] := VHA; LLo[LB + V] := VLA;
           end;
      153, 154, 155, 156, 157, 158:                 { ifXX vs 0 }
        begin
          V := Cmp32(SHi[SP], SLo[SP], 0, 0); SP := SP - 1;
          case B of
            153: K := Ord(V = 0);
            154: K := Ord(V <> 0);
            155: K := Ord(V < 0);
            156: K := Ord(V >= 0);
            157: K := Ord(V > 0);
            158: K := Ord(V <= 0);
          end;
          if K <> 0 then PC := OpPC + U2(PC) else PC := PC + 2;
        end;
      159, 160, 161, 162, 163, 164:                 { if_icmpXX }
        begin
          V := Cmp32(SHi[SP - 1], SLo[SP - 1], SHi[SP], SLo[SP]);
          SP := SP - 2;
          case B of
            159: K := Ord(V = 0);
            160: K := Ord(V <> 0);
            161: K := Ord(V < 0);
            162: K := Ord(V >= 0);
            163: K := Ord(V > 0);
            164: K := Ord(V <= 0);
          end;
          if K <> 0 then PC := OpPC + U2(PC) else PC := PC + 2;
        end;
      167: PC := OpPC + U2(PC);                     { goto }
      172, 176: Ret(True);                          { ireturn/areturn }
      177: Ret(False);                              { return }
      178: begin                                    { getstatic }
             V := U2(PC); PC := PC + 2;
             SH := Shim(V);
             if SH = 13 then Push($7F05, 0)
             else if SH = 14 then Push($7F06, 0)
             else if SH > 20 then Push(SFHi[SH - 20], SFLo[SH - 20])
             else Fail('getstatic: unsupported field');
           end;
      179: begin                                    { putstatic }
             V := U2(PC); PC := PC + 2;
             SH := Shim(V);
             if SH <= 20 then Fail('putstatic: unsupported field');
             SFHi[SH - 20] := SHi[SP]; SFLo[SH - 20] := SLo[SP];
             SP := SP - 1;
           end;
      182, 183: begin                               { invokevirtual/special }
                  V := U2(PC); PC := PC + 2;
                  SH := Shim(V);
                  if SH = 0 then FailCP(V);
                  if SH >= 40 then CallLocal(SH - 40)
                  else DoShim(SH, True);
                end;
      184: begin                                    { invokestatic }
             V := U2(PC); PC := PC + 2;
             SH := Shim(V);
             if SH < 40 then Fail('invokestatic: not ours');
             CallLocal(SH - 40);
           end;
      187: begin                                    { new }
             V := U2(PC); PC := PC + 2;
             if not UtfIs(U2(CpOfs[V]), 'java/lang/StringBuilder') then
               Fail('new: only StringBuilder');
             SBNext := 3 - SBNext;                  { rotate 1 <-> 2 }
             SBLen[SBNext] := 0;
             Push($7F03, SBNext);
           end;
      188: begin                                    { newarray }
             V := Buf[PC]; PC := PC + 1;            { atype }
             if SHi[SP] <> 0 then Fail('array too big');
             L := SLo[SP]; SP := SP - 1;
             if L < 0 then Fail('negative array size');
             ACount := ACount + 1;
             if ACount > 6 then Fail('too many arrays');
             if (V = 4) or (V = 8) or (V = 5) then K := 1
             else if V = 10 then K := 4
             else Fail('array type not supported');
             AOfs[ACount] := HeapTop;
             ALen[ACount] := L;
             AEsz[ACount] := K;
             HeapTop := HeapTop + L * K;
             if (HeapTop > HEAPSZ) or (HeapTop < 0) then
               Fail('out of heap');
             FillChar(Heap[AOfs[ACount]], L * K, 0);
             Push($7F01, ACount);
           end;
      190: begin                                    { arraylength }
             ChkArr(SHi[SP], SLo[SP]);
             K := SLo[SP]; SP := SP - 1;
             PushI(ALen[K]);
           end;
    else
      FailB('opcode ', B);
    end;
  end;
end;
