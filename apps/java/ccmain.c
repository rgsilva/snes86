/*
** ccmain.c - the desktop (clang) driver for JAVAC. Concatenated AFTER
** javac.c so every global and jcmain() is already in scope; this file
** owns file I/O, argv and error reporting on the host, exactly as
** scmain.c does on DOS. Build: cat javac.c ccmain.c | cc -std=c89 -x c -
**
** Usage: javac-dev FILE.java [OUT.class]
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int die(msg) char *msg; {
  fprintf(stderr, "JAVAC: %s (line %d)\n", msg, ln);
  exit(1);
  return 0;
}

int main(argc, argv) int argc; char **argv; {
  FILE *f;
  int c, i;
  char out[128];
  if (argc < 2) { fprintf(stderr, "usage: javac FILE.java [OUT.class]\n"); return 1; }
  f = fopen(argv[1], "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
  slen = 0;
  while ((c = fgetc(f)) != EOF) {
    if (slen >= (int)sizeof(src)) { fprintf(stderr, "source too big\n"); return 1; }
    src[slen++] = (char)c;
  }
  fclose(f);

  jcmain();

  if (argc >= 3) strcpy(out, argv[2]);
  else {
    /* derive: strip extension, add .class */
    strcpy(out, clsnm);
    strcat(out, ".class");
  }
  f = fopen(out, "wb");
  if (!f) { fprintf(stderr, "cannot write %s\n", out); return 1; }
  for (i = 0; i < olen; i++) fputc(outb[i] & 255, f);
  fclose(f);
  fprintf(stderr, "wrote %s (%d bytes)\n", out, olen);
  return 0;
}
