program Bench;  { self-timing micro-benchmarks via DOS clock }
type Regs = record AX,BX,CX,DX,BP,SI,DI,DS,ES,Flags: integer; end;
var r: Regs;
    t0, t1: real;
    i, k, n, acc: integer;
    flags: array[0..8190] of boolean;
function Clock: real;
begin
  r.AX := $2C00; MsDos(r);
  Clock := Hi(r.CX)*3600.0 + Lo(r.CX)*60.0 + Hi(r.DX) + Lo(r.DX)/100.0;
end;
begin
  WriteLn('snes86 benchmark suite');
  t0 := Clock;
  for n := 1 to 3 do begin
    for i := 0 to 8190 do flags[i] := true;
    for i := 0 to 8190 do
      if flags[i] then begin
        k := i + i + 3 + i;
        while k <= 8190 do begin flags[k] := false; k := k + i + i + 3; end;
      end;
  end;
  t1 := Clock;
  WriteLn('Sieve x3:    ', (t1-t0):7:2, ' s');
  t0 := Clock; acc := 1;
  for i := 1 to 10000 do begin acc := acc * 13; acc := acc div 7; end;
  t1 := Clock;
  WriteLn('MulDiv 10k:  ', (t1-t0):7:2, ' s');
  t0 := Clock;
  for i := 1 to 200 do Write('.');
  WriteLn;
  t1 := Clock;
  WriteLn('Console 200: ', (t1-t0):7:2, ' s');
  WriteLn('(IBM PC/XT 4.77MHz for scale: ~2s / ~0.4s / ~0.1s)');
end.
