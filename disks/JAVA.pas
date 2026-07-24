program JavaVM;
{ JAVA - a Java class-file interpreter for snes86 (or any DOS 2.0 PC).
  Runs real javac bytecode: on any modern machine,
      javac --release 8 Hello.java
  rename Hello.class to HELLO.CLA, bring it here, and
      JAVA HELLO
  Scope (see java/README.md): static methods of one class, 32-bit int
  arithmetic, boolean/int arrays, String literals, StringBuilder concat,
  System.out.println/print, System.in.read. No objects, no GC (nothing
  lives long enough to collect), no long/float, no exceptions - an
  unsupported program dies with a clean message, not a hang.
  The machine word is 16 bits, so every Java int is a hi/lo register
  pair; the hot pair arithmetic is hand-written 8086 (AddV/SubV/MulV).
  Class files are read whole (they are under 2 KB) and parsed in place. }

const
  MAXPOOL = 96;
  MAXMETH = 12;
  MAXSF = 12;
  MAXFRM = 16;
  STKSZ = 48;
  LOCSZ = 96;
  BUFSZ = 2599;
  HEAPSZ = 8500;

type
  Str48 = string[48];
  Str16 = string[16];
  Regs = record
    AX, BX, CX, DX, BP, SI, DI, DS, ES, Flags: Integer;
  end;

var
  R: Regs;
  FName: string[64];
  Nm: string[65];
  Buf: array[0..BUFSZ] of Byte;      { the whole .CLA, parsed in place }
  FSize: Integer;
  { constant pool: tag + offset of each entry's body }
  CpTag: array[1..MAXPOOL] of Byte;
  CpOfs: array[1..MAXPOOL] of Integer;
  CpCount: Integer;
  ShimC: array[1..MAXPOOL] of Integer;  { resolved shim cache per cp idx }
  ThisCp: Integer;                   { cp index of this class's Class entry }
  { methods of this class }
  MName, MDesc, MCode, MMaxL, MArgs: array[1..MAXMETH] of Integer;
  MCount, MainM: Integer;
  { static int fields of this class }
  SFName: array[1..MAXSF] of Integer;
  SFHi, SFLo: array[1..MAXSF] of Integer;
  SFCount: Integer;
  { operand stack + locals: 32-bit values as hi/lo word pairs }
  SHi, SLo: array[0..STKSZ] of Integer;
  SP: Integer;
  LHi, LLo: array[0..LOCSZ] of Integer;
  LB, LTop: Integer;
  { call frames }
  FrPC, FrM, FrLB: array[1..MAXFRM] of Integer;
  FP: Integer;
  PC, CurM: Integer;
  Running: Boolean;
  { arrays live in one byte arena; handles index this table }
  Heap: array[0..HEAPSZ] of Byte;
  HeapTop: Integer;
  AOfs, ALen, AEsz: array[1..6] of Integer;
  ACount: Integer;
  { StringBuilder slots (javac uses one per statement; two is safety) }
  SBBuf: array[1..2, 0..191] of Byte;
  SBLen: array[1..2] of Integer;
  SBNext: Integer;
  { globals for the inline 32-bit helpers (TP3 keeps SS<>DS: no locals) }
  VHA, VLA, VHB, VLB, VRH, VRL: Integer;
  T0, I: Integer;
  S16: Str16;

{$I JAVA1.INC}
{$I JAVA2.INC}
{$I JAVA3.INC}

begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: JAVA program[.CLA]');
    WriteLn('  runs javac --release 8 bytecode (see C:\JAVA\README)');
    Halt;
  end;
  FName := ParamStr(1);
  I := Pos('.', FName);
  if I = 0 then FName := FName + '.CLA';
  LoadFile;
  ParseClass;
  if MainM = 0 then Fail('no main([Ljava/lang/String;)V');
  T0 := MemW[$0040:$006C];
  HeapTop := 0; ACount := 0; SBNext := 2;   { TP3 globals start as garbage }
  { start main: locals[0] = args (null) }
  CurM := MainM;
  LB := 0;
  LTop := MMaxL[MainM];
  LHi[0] := 0; LLo[0] := 0;
  PC := MCode[MainM];
  SP := 0;
  FP := 0;
  Running := True;
  Run;
  I := MemW[$0040:$006C] - T0;
  WriteLn('[', I, ' ticks]');
end.
