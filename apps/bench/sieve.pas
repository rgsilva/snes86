program Sieve;  { BYTE benchmark, 10 iterations }
const Size = 8190;
var flags: array[0..Size] of boolean;
    i, prime, k, count, iter: integer;
begin
  WriteLn('BYTE Sieve, 10 iterations');
  for iter := 1 to 10 do begin
    count := 0;
    FillChar(flags, SizeOf(flags), 1);
    for i := 0 to Size do
      if flags[i] then begin
        prime := i + i + 3;
        k := i + prime;
        while k <= Size do begin
          flags[k] := false;
          k := k + prime;
        end;
        count := count + 1;
      end;
  end;
  WriteLn(count, ' primes (expect 1899)');
end.
