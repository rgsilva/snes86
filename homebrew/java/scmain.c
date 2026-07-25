/*
** scmain.c - the DOS (Small-C) driver for JAVAC. Concatenated AFTER
** javac.c, so every global and jcmain() is already declared; this file
** owns file I/O, argv and errors on the guest, the way ccmain.c does on
** the host. Build: cat javac.c scmain.c > JAVAC.C ; cc JAVAC ; asm ...
**
** Usage on DOS:  JAVAC IN.JAV OUT.CLA
** Binary I/O uses the kit's raw read()/write() (no CR/LF or ^Z cooking,
** which would wreck a class file). argv[1..] arrive fine on DOS 2.0 (cc
** and asm take arguments the same way); only argv[0] needs DOS 3.
*/
/* No #include: the kit's stdio.h is included by the host driver's own
   path, and Small-C cannot #include mid-file (after javac.c). The three
   values used are inlined; the I/O functions resolve at link time. */
#define NULL   0
#define LF     10
#define stderr 2

die(msg) char *msg; {
  puts("JAVAC: ");
  puts(msg);
  puts(" (line ");
  putn(ln);
  puts(")");
  putc(LF, stderr);
  exit(1);
  return 0;
}

/* small unsigned-decimal print (avoids pulling printf into the image) */
putn(v) int v; {
  char b[8];
  int i;
  i = 0;
  if (v == 0) { putc('0', stderr); return 0; }
  while (v > 0 && i < 7) { b[i] = '0' + (v % 10); v = v / 10; i++; }
  while (i > 0) { i--; putc(b[i], stderr); }
  return 0;
}

main(argc, argv) int argc; char *argv[]; {
  int fd, i, n;
  if (argc < 3) {
    puts("usage: JAVAC IN.JAV OUT.CLA");
    putc(LF, stderr);
    exit(1);
  }
  fd = fopen(argv[1], "r");
  if (fd == NULL) { puts("cannot open input"); putc(LF, stderr); exit(1); }
  slen = 0;
  while (1) {
    n = read(fd, &src[slen], 4096);
    if (n <= 0) break;
    slen = slen + n;
    if (slen > 16000) { puts("source too big"); putc(LF, stderr); exit(1); }
  }
  fclose(fd);

  jcmain();

  fd = fopen(argv[2], "w");
  if (fd == NULL) { puts("cannot create output"); putc(LF, stderr); exit(1); }
  i = 0;
  while (i < olen) {
    n = olen - i;
    if (n > 4096) n = 4096;
    if (write(fd, &outb[i], n) != n) {
      puts("write error"); putc(LF, stderr); exit(1);
    }
    i = i + n;
  }
  fclose(fd);
  puts("ok: ");
  puts(argv[2]);
  putc(LF, stderr);
  return 0;
}
