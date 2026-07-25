/*
** scmain.c - the DOS (Small-C) driver for JAVAC. Concatenated AFTER
** javac.c, so every global and jcmain() is already declared; this file
** owns file I/O, argv and errors on the guest, the way ccmain.c does on
** the host. Build: cat javac.c scmain.c > JAVAC.C ; cc JAVAC ; asm ...
**
** Usage on DOS:  JAVAC IN.JAV OUT.CLA
**
** Strictly canonical Small-C 2.2 throughout - cc 2.2 ACCEPTS some
** wider constructs and then silently miscompiles them, so this file
** only uses shapes cc's own source uses:
**   - main(argc, argv) int argc, *argv;  and CLIB getarg() - NOT
**     char *argv[] (accepted, then main's body is emitted as garbage)
**   - no local arrays (buffers are globals)
**   - fputc, not putc (no PUTC module in CLIB)
** Binary I/O uses the kit's raw read()/write() from CSYSLIB (no CR/LF
** or ^Z cooking, which would wreck a class file).
*/
#define LF     10
#define stderr 2

char infn[24];
char outfn[24];
char pnb[8];

die(msg) char *msg; {
  puts("JAVAC: ");
  puts(msg);
  puts(" (line ");
  putn(ln);
  puts(")");
  fputc(LF, stderr);
  exit(1);
  return 0;
}

/* small unsigned-decimal print (avoids pulling printf into the image) */
putn(v) int v; {
  int i;
  i = 0;
  if (v == 0) { fputc('0', stderr); return 0; }
  while (v > 0 && i < 7) { pnb[i] = '0' + (v % 10); v = v / 10; i++; }
  while (i > 0) { i--; fputc(pnb[i], stderr); }
  return 0;
}

main(argc, argv) int argc, *argv; {
  int fd, i, n;
  if (argc < 3) {
    puts("usage: JAVAC IN.JAV OUT.CLA");
    fputc(LF, stderr);
    exit(1);
  }
  getarg(1, infn, 24, argc, argv);
  getarg(2, outfn, 24, argc, argv);
  fd = fopen(infn, "r");
  if (fd == 0) { puts("cannot open input"); fputc(LF, stderr); exit(1); }
  slen = 0;
  while (1) {
    n = read(fd, src + slen, 4096);
    if (n <= 0) break;
    slen = slen + n;
    if (slen > 16000) { puts("source too big"); fputc(LF, stderr); exit(1); }
  }
  fclose(fd);

  jcmain();

  fd = fopen(outfn, "w");
  if (fd == 0) { puts("cannot create output"); fputc(LF, stderr); exit(1); }
  i = 0;
  while (i < olen) {
    n = olen - i;
    if (n > 4096) n = 4096;
    if (write(fd, outb + i, n) != n) {
      puts("write error"); fputc(LF, stderr); exit(1);
    }
    i = i + n;
  }
  fclose(fd);
  puts("ok: ");
  puts(outfn);
  fputc(LF, stderr);
  return 0;
}
