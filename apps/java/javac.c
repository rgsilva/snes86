/*
** JAVAC - a Java compiler for snes86 (or any DOS 2.0 PC).
**
** Compiles the Java subset that JAVA.COM interprets (see README.md)
** straight to class-file bytecode: one public class, static methods,
** 32-bit ints, boolean/int arrays, String literals, string concat via
** the StringBuilder chain, System.out.println/print, System.in.read.
** Emits class-format version 49.0 (pre-StackMapTable, so no stack
** frames are needed) with no optional attributes; the output runs on
** JAVA.COM *and* on a modern desktop JVM.
**
** Written in the polyglot dialect that both clang (-std=c89) and the
** 1988 Small-C compiler accept, so the same source builds the desktop
** development binary and the DOS binary that ships on the SNES:
**   - K&R function definitions, no prototypes, no structs (parallel
**     arrays), no unsigned/long/void/static, no initializers, no
**     compound assignment, slash-star comments only;
**   - identifiers unique in the first 8 characters;
**   - ints may be 16-bit: every value is kept in -32768..32767, and
**     the one 32-bit quantity (Java int literals) lives in four byte
**     limbs so the arithmetic is identical on both compilers;
**   - no #include at all: the platform drivers (ccmain.c for clang,
**     scmain.c for Small-C) own file I/O, argv and error printing,
**     and call jcmain() with src[]/slen filled in.
**
** Subset limits (clean error, not silence): no / or % (JAVA.COM has
** no idiv), no objects/fields/floats/long, no else-if paren groups in
** conditions beyond `a op b [&&/|| ...]`, no .length, one class.
*/


/* ---- source + lexer ---- */
char src[16384];
int slen;
int pos;
int ln;

int tok;                      /* token: 0 eof, 1 ident, 2 num, 3 string,
                                 else the ASCII char / 2xx codes below */
char tnm[130];                /* ident / string text */
int tl;                       /* its length */
int nb0, nb1, nb2, nb3;       /* number literal, little-endian limbs */

/* saved lexer state for the one-token rollback (concat detection) */
int svpos, svln, svtok, svtl;
int svb0, svb1, svb2, svb3;
char svnm[130];

/* ---- class file buffers ---- */
char pool[2100];              /* constant pool, wire format */
int pln;
int pcnt;
int pk[97];                   /* entry kind: 1 utf8 3 int 7 class
                                 8 string 9 fieldref 10 methodref
                                 12 nameandtype */
int pa[97], pb[97];           /* operands (utf8: offset,len of body) */

char code[900];               /* current method's bytecode */
int clen;
int stkc, stkm;               /* stack tracking: current, max */

char mbuf[2100];              /* finished method_info records */
int mbl;
int mtot;                     /* methods emitted (incl <init>) */

char clsnm[40];               /* the class name */
int clsl;

/* ---- methods (from the pre-scan) ---- */
char mnms[300];               /* name arena */
int mno[14], mnl[14];         /* name offset/len in arena */
int marg[14];                 /* arg count (ints; main: 1 = args) */
int mret[14];                 /* 'V' or 'I' */
int mism[14];                 /* is this main()? */
int mcnt;

/* ---- locals of the current method ---- */
char lnms[300];
int lno[26], lnl[26];
int lslot[26], ltyp[26];      /* type: 0 int 1 String 2 int[] 3 bool[] */
int lscp[26];
int lcnt, slotn, scplv;
int curret;                   /* current method return: 'V'/'I' */

/* ---- loop stack for break/continue ----
   active levels 0..loopd-1. brkc: forward goto chain -> loop exit.
   cnta >= 0: continue is a backward jump to that PC (while loop).
   cnta < 0:  continue is the forward chain cntc (for loop's update). */
int brkc[8];
int cnta[8];
int cntc[8];
int loopd;

/* ---- output ---- */
char outb[2600];
int olen;

/* ================= small helpers ================= */

scopy(d, s) char *d; char *s; {     /* strcpy; Small-C can't subscript
                                      a string literal, so all literal
                                      text is copied through here */
  int i;
  i = 0;
  while (s[i] != 0) { d[i] = s[i]; i++; }
  d[i] = 0;
  return i;
}

streq(a, b) char *a; char *b; {
  int i;
  i = 0;
  while (a[i] != 0 && b[i] != 0) {
    if (a[i] != b[i]) return 0;
    i++;
  }
  if (a[i] != b[i]) return 0;
  return 1;
}

tokis(s) char *s; {
  if (tok != 1) return 0;
  return streq(tnm, s);
}

/* ================= lexer ================= */

pk2() {                   /* peek char after pos, masked */
  if (pos + 1 >= slen) return 0;
  return src[pos + 1] & 255;
}

lex() {
  int c, q;
  tl = 0;
  tnm[0] = 0;
  while (pos < slen) {
    c = src[pos] & 255;
    if (c == 10) { ln++; pos++; }
    else if (c == 32 || c == 9 || c == 13 || c == 12 || c == 26) pos++;
    else if (c == '/' && pk2() == '/') {
      while (pos < slen && (src[pos] & 255) != 10) pos++;
    }
    else if (c == '/' && pk2() == '*') {
      pos = pos + 2;
      while (pos < slen) {
        if ((src[pos] & 255) == 10) ln++;
        if ((src[pos] & 255) == '*' && pk2() == '/') { pos = pos + 2; break; }
        pos++;
      }
    }
    else break;
  }
  if (pos >= slen) { tok = 0; return 0; }
  c = src[pos] & 255;
  if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$') {
    while (pos < slen) {
      c = src[pos] & 255;
      if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '_' || c == '$') {
        if (tl < 128) { tnm[tl] = c; tl++; }
        pos++;
      }
      else break;
    }
    tnm[tl] = 0;
    tok = 1;
    return 0;
  }
  if (c >= '0' && c <= '9') {           /* decimal, into 4 limbs */
    nb0 = 0; nb1 = 0; nb2 = 0; nb3 = 0;
    while (pos < slen) {
      c = src[pos] & 255;
      if (c < '0' || c > '9') break;
      /* limbs = limbs*10 + digit, 8-bit limb math (identical on
         16-bit and 32-bit host ints) */
      nb0 = nb0 * 10 + (c - '0');
      nb1 = nb1 * 10 + (nb0 >> 8);
      nb0 = nb0 & 255;
      nb2 = nb2 * 10 + (nb1 >> 8);
      nb1 = nb1 & 255;
      nb3 = nb3 * 10 + (nb2 >> 8);
      nb2 = nb2 & 255;
      nb3 = nb3 & 255;
      pos++;
    }
    tok = 2;
    return 0;
  }
  if (c == 34) {                        /* string literal */
    pos++;
    while (pos < slen) {
      c = src[pos] & 255;
      if (c == 34) { pos++; break; }
      if (c == 92) {                    /* escape */
        pos++;
        q = src[pos] & 255;
        if (q == 'n') c = 10;
        else if (q == 't') c = 9;
        else if (q == 'r') c = 13;
        else c = q;
        pos++;
      }
      else pos++;
      if (tl < 128) { tnm[tl] = c; tl++; }
    }
    tnm[tl] = 0;
    tok = 3;
    return 0;
  }
  if (c == 39) {                        /* char literal -> number */
    pos++;
    c = src[pos] & 255;
    if (c == 92) {
      pos++;
      q = src[pos] & 255;
      if (q == 'n') c = 10;
      else if (q == 't') c = 9;
      else if (q == 'r') c = 13;
      else if (q == '0') c = 0;
      else c = q;
    }
    pos++;
    if ((src[pos] & 255) != 39) die("bad char literal");
    pos++;
    nb0 = c; nb1 = 0; nb2 = 0; nb3 = 0;
    tok = 2;
    return 0;
  }
  pos++;
  q = src[pos] & 255;                   /* char already advanced past c */
  if (c == '<' && q == '=') { pos++; tok = 200; return 0; }
  if (c == '>' && q == '=') { pos++; tok = 201; return 0; }
  if (c == '=' && q == '=') { pos++; tok = 202; return 0; }
  if (c == '!' && q == '=') { pos++; tok = 203; return 0; }
  if (c == '&' && q == '&') { pos++; tok = 204; return 0; }
  if (c == '|' && q == '|') { pos++; tok = 205; return 0; }
  if (c == '+' && q == '+') { pos++; tok = 206; return 0; }
  if (c == '-' && q == '-') { pos++; tok = 207; return 0; }
  if (c == '+' && q == '=') { pos++; tok = 208; return 0; }
  if (c == '-' && q == '=') { pos++; tok = 209; return 0; }
  tok = c;
  return 0;
}

lsave() {
  int i;
  svpos = pos; svln = ln; svtok = tok; svtl = tl;
  svb0 = nb0; svb1 = nb1; svb2 = nb2; svb3 = nb3;
  i = 0;
  while (i <= tl) { svnm[i] = tnm[i]; i++; }
  return 0;
}

lrest() {
  int i;
  pos = svpos; ln = svln; tok = svtok; tl = svtl;
  nb0 = svb0; nb1 = svb1; nb2 = svb2; nb3 = svb3;
  i = 0;
  while (i <= tl) { tnm[i] = svnm[i]; i++; }
  return 0;
}

expct(t) int t; {
  if (tok != t) die("unexpected token");
  lex();
  return 0;
}

kweat(s) char *s; {       /* expect keyword ident s */
  if (!tokis(s)) die("expected keyword");
  lex();
  return 0;
}

/* ================= constant pool ================= */

pu8(b) int b; {
  if (pln >= 2090) die("constant pool overflow");
  pool[pln] = b & 255;
  pln++;
  return 0;
}

pu16(v) int v; {
  pu8((v >> 8) & 255);
  pu8(v & 255);
  return 0;
}

newent(k, a, b) int k, a, b; {
  pcnt++;
  if (pcnt > 90) die("too many constants");
  pk[pcnt] = k; pa[pcnt] = a; pb[pcnt] = b;
  return pcnt;
}

cpu8(s) char *s; {        /* Utf8 entry, dedup by content */
  int i, j, n, o;
  n = 0;
  while (s[n] != 0) n++;
  i = 1;
  while (i <= pcnt) {
    if (pk[i] == 1 && pb[i] == n) {
      o = pa[i];
      j = 0;
      while (j < n && (pool[o + j] & 255) == (s[j] & 255)) j++;
      if (j == n) return i;
    }
    i++;
  }
  pu8(1);
  pu16(n);
  o = pln;
  j = 0;
  while (j < n) { pu8(s[j] & 255); j++; }
  return newent(1, o, n);
}

cppair(k, a, b) int k, a, b; {  /* dedup entry with two operands */
  int i;
  i = 1;
  while (i <= pcnt) {
    if (pk[i] == k && pa[i] == a && pb[i] == b) return i;
    i++;
  }
  pu8(k);
  pu16(a);
  if (k != 7 && k != 8) pu16(b);
  return newent(k, a, b);
}

cpcls(s) char *s; {       /* Class */
  return cppair(7, cpu8(s), 0);
}

cpstr(u) int u; {         /* String from utf8 idx */
  return cppair(8, u, 0);
}

cpnt(n, d) char *n; char *d; { /* NameAndType */
  return cppair(12, cpu8(n), cpu8(d));
}

cpmeth(c, n, d) char *c; char *n; char *d; {  /* Methodref */
  return cppair(10, cpcls(c), cpnt(n, d));
}

cpfld(c, n, d) char *c; char *n; char *d; {   /* Fieldref */
  return cppair(9, cpcls(c), cpnt(n, d));
}

cpint(h, l) int h, l; {   /* Integer, operands = hi/lo 16-bit words */
  int i;
  i = 1;
  while (i <= pcnt) {
    if (pk[i] == 3 && pa[i] == h && pb[i] == l) return i;
    i++;
  }
  pu8(3);
  pu16(h);
  pu16(l);
  return newent(3, h, l);
}

/* ================= code emission ================= */

e1(b) int b; {
  if (clen >= 890) die("method too long");
  code[clen] = b & 255;
  clen++;
  return 0;
}

esp(d) int d; {           /* stack depth bookkeeping */
  stkc = stkc + d;
  if (stkc > stkm) stkm = stkc;
  return 0;
}

e2u(v) int v; {
  e1((v >> 8) & 255);
  e1(v & 255);
  return 0;
}

/* branch chains: each pending jump stores the PREVIOUS chain link in
   its two offset bytes; 0 terminates (offset bytes can never be 0-0
   for a real link because links point at operand positions > 0). */

cjmp(op, chain) int op, chain; {
  int at;
  e1(op);
  at = clen;
  e2u(chain);
  return at;                  /* new chain head = operand position */
}

patch(chain, target) int chain, target; {
  int nx, d;
  while (chain != 0) {
    nx = ((code[chain] & 255) << 8) | (code[chain + 1] & 255);
    d = target - (chain - 1);          /* rel to opcode byte */
    code[chain] = (d >> 8) & 255;
    code[chain + 1] = d & 255;
    chain = nx;
  }
  return 0;
}

ebrk(target) int target; { /* backward goto */
  int d;
  e1(167);
  d = target - (clen - 1);
  e2u(d);
  return 0;
}

/* iconst/bipush/sipush/ldc from limbs nb0..nb3 */
enum32() {
  int hi, lo, v;
  hi = ((nb3 & 255) << 8) | (nb2 & 255);
  lo = ((nb1 & 255) << 8) | (nb0 & 255);
  esp(1);
  if (hi == 0 && nb1 == 0 && nb0 <= 127) {
    v = nb0;
    if (v <= 5) { e1(3 + v); return 0; }         /* iconst_0..5 */
    e1(16); e1(v);                                /* bipush */
    return 0;
  }
  if (hi == 0 && (nb1 & 128) == 0) {              /* sipush positive */
    e1(17); e1(nb1); e1(nb0);
    return 0;
  }
  e1(18); e1(cpint(hi, lo));                      /* ldc Integer */
  return 0;
}

/* negate the literal limbs (two's complement) */
negl() {
  int c, v;
  nb0 = (nb0 ^ 255) & 255;
  nb1 = (nb1 ^ 255) & 255;
  nb2 = (nb2 ^ 255) & 255;
  nb3 = (nb3 ^ 255) & 255;
  v = nb0 + 1; nb0 = v & 255; c = v >> 8;
  v = nb1 + c; nb1 = v & 255; c = v >> 8;
  v = nb2 + c; nb2 = v & 255; c = v >> 8;
  nb3 = (nb3 + c) & 255;
  return 0;
}

/* emit a NEGATIVE small literal from limbs when they fit bipush etc */
enegl() {
  int hi;
  negl();                     /* now magnitude-negated: limbs = -value */
  hi = ((nb3 & 255) << 8) | (nb2 & 255);
  esp(1);
  if (hi == -1 || hi == 65535) hi = 65535;
  if (hi == 65535 && nb1 == 255 && nb0 >= 128) {  /* -128..-1 */
    if (nb0 == 255) { e1(2); return 0; }          /* iconst_m1 */
    e1(16); e1(nb0);
    return 0;
  }
  if (hi == 65535 && (nb1 & 128) != 0) {          /* sipush negative */
    e1(17); e1(nb1); e1(nb0);
    return 0;
  }
  e1(18); e1(cpint(hi, ((nb1 & 255) << 8) | (nb0 & 255)));
  return 0;
}

eload(slot, ref) int slot, ref; {
  esp(1);
  if (ref) {
    if (slot <= 3) { e1(42 + slot); return 0; }
    e1(25); e1(slot);
    return 0;
  }
  if (slot <= 3) { e1(26 + slot); return 0; }
  e1(21); e1(slot);
  return 0;
}

estore(slot, ref) int slot, ref; {
  esp(-1);
  if (ref) {
    if (slot <= 3) { e1(75 + slot); return 0; }
    e1(58); e1(slot);
    return 0;
  }
  if (slot <= 3) { e1(59 + slot); return 0; }
  e1(54); e1(slot);
  return 0;
}

/* ================= locals ================= */

lfind(s) char *s; {
  int i, j, o;
  i = lcnt - 1;
  while (i >= 0) {
    o = lno[i];
    j = 0;
    while (s[j] != 0 && lnms[o + j] == s[j]) j++;
    if (s[j] == 0 && lnl[i] == j) return i;
    i--;
  }
  return -1;
}

int lno2;                     /* arena top for locals */

ladd(s, typ) char *s; int typ; {
  int j;
  if (lcnt >= 25) die("too many locals");
  lno[lcnt] = lno2;
  j = 0;
  while (s[j] != 0) {
    if (lno2 >= 295) die("local names overflow");
    lnms[lno2] = s[j];
    lno2++; j++;
  }
  lnl[lcnt] = j;
  lslot[lcnt] = slotn;
  ltyp[lcnt] = typ;
  lscp[lcnt] = scplv;
  lcnt++;
  slotn++;
  return lcnt - 1;
}

scpop() {                 /* leave a scope level */
  while (lcnt > 0 && lscp[lcnt - 1] >= scplv) lcnt--;
  scplv--;
  return 0;
}

/* ================= methods table ================= */

mfind(s) char *s; {
  int i, j, o;
  i = 0;
  while (i < mcnt) {
    o = mno[i];
    j = 0;
    while (s[j] != 0 && mnms[o + j] == s[j]) j++;
    if (s[j] == 0 && mnl[i] == j) return i;
    i++;
  }
  return -1;
}

/* build "(III)I" style descriptor for method i into dst */
mdesc(i, dst) int i; char *dst; {
  int j, k;
  if (mism[i]) {
    scopy(dst, "([Ljava/lang/String;)V");
    return 0;
  }
  k = 0;
  dst[k] = '('; k++;
  j = 0;
  while (j < marg[i]) { dst[k] = 'I'; k++; j++; }
  dst[k] = ')'; k++;
  dst[k] = mret[i]; k++;
  dst[k] = 0;
  return 0;
}

char dscb[28];                /* scratch descriptor */
char mnmb[36];                /* scratch method name */

mgetnm(i) int i; {        /* copy method i's name into mnmb */
  int j, o;
  o = mno[i];
  j = 0;
  while (j < mnl[i]) { mnmb[j] = mnms[o + j]; j++; }
  mnmb[j] = 0;
  return 0;
}

/* ================= expressions ================= */
/* forward use: sum(), prim(), xpr(), cond() are mutually recursive;
   C's implicit declarations cover the cycles in both dialects. */

sbNew() {                 /* new SB, dup, invokespecial <init> */
  e1(187); esp(1);
  e2u(cpcls("java/lang/StringBuilder"));
  e1(89); esp(1);
  e1(183); esp(-1);
  e2u(cpmeth("java/lang/StringBuilder", "<init>", "()V"));
  return 0;
}

sbAppI() {
  e1(182); esp(-1);
  e2u(cpmeth("java/lang/StringBuilder", "append",
             "(I)Ljava/lang/StringBuilder;"));
  esp(0);
  return 0;
}

sbAppS() {
  e1(182); esp(-1);
  e2u(cpmeth("java/lang/StringBuilder", "append",
             "(Ljava/lang/String;)Ljava/lang/StringBuilder;"));
  esp(0);
  return 0;
}

sbToS() {
  e1(182);
  e2u(cpmeth("java/lang/StringBuilder", "toString",
             "()Ljava/lang/String;"));
  return 0;
}

egetout() {
  e1(178); esp(1);
  e2u(cpfld("java/lang/System", "out", "Ljava/io/PrintStream;"));
  return 0;
}

egetin() {
  e1(178); esp(1);
  e2u(cpfld("java/lang/System", "in", "Ljava/io/InputStream;"));
  return 0;
}

einread() {
  e1(182);
  e2u(cpmeth("java/io/InputStream", "read", "()I"));
  esp(0);                     /* pops in, pushes result */
  return 0;
}

/* method call: name already consumed, tok is '(' */
ecall(mi) int mi; {
  int n;
  expct('(');
  n = 0;
  if (tok != ')') {
    while (1) {
      if (sum() != 0) die("int argument expected");
      n++;
      if (tok != ',') break;
      lex();
    }
  }
  expct(')');
  if (n != marg[mi]) die("wrong argument count");
  e1(184);
  mgetnm(mi);
  mdesc(mi, dscb);
  e2u(cpmeth(clsnm, mnmb, dscb));
  esp(-n);
  if (mret[mi] == 'I') esp(1);
  return mret[mi];            /* 'I' or 'V' */
}

/* primary: returns type 0 int, 1 String, 2 int[], 3 bool[] */
prim() {
  int i, t;
  if (tok == 2) {             /* number */
    enum32();
    lex();
    return 0;
  }
  if (tok == 3) {             /* string literal */
    i = cpstr(cpu8(tnm));
    if (i > 255) die("string pool index too big");
    e1(18); esp(1); e1(i);    /* ldc */
    lex();
    return 1;
  }
  if (tok == '-') {           /* unary minus */
    lex();
    if (tok == 2) {           /* constant-fold negative literal */
      enegl();
      lex();
      return 0;
    }
    t = prim();
    if (t != 0) die("minus needs an int");
    e1(116);                  /* ineg */
    return 0;
  }
  if (tok == '(') {
    lex();
    t = sum();
    expct(')');
    return t;
  }
  if (tok != 1) die("expression expected");
  if (streq(tnm, "true")) { lex(); e1(4); esp(1); return 0; }
  if (streq(tnm, "false")) { lex(); e1(3); esp(1); return 0; }
  if (streq(tnm, "System")) {
    lex(); expct('.');
    if (!tokis("in")) die("only System.in here");
    lex(); expct('.');
    kweat("read");
    expct('('); expct(')');
    egetin();
    einread();
    return 0;
  }
  /* identifier: local, or method call */
  lsave();
  i = lfind(tnm);
  if (i >= 0) {
    lex();
    if (tok == '[') {         /* array element */
      if (ltyp[i] != 2 && ltyp[i] != 3) die("not an array");
      eload(lslot[i], 1);
      lex();
      if (sum() != 0) die("index must be int");
      expct(']');
      if (ltyp[i] == 3) e1(51); else e1(46);   /* baload/iaload */
      esp(-1);
      return 0;
    }
    eload(lslot[i], ltyp[i] != 0);
    if (ltyp[i] == 1) return 1;
    if (ltyp[i] != 0) die("array used as value");
    return 0;
  }
  i = mfind(tnm);
  if (i >= 0) {
    lex();
    if (tok != '(') die("method name used as value");
    if (ecall(i) != 'I') die("void call in expression");
    return 0;
  }
  die("unknown identifier");
  return 0;
}

/* additive/multiplicative int expression; also passes String through
   (a lone String literal/var). Type returned like prim(). */
trm() {
  int t;
  t = prim();
  while (tok == '*') {
    if (t != 0) die("* needs ints");
    lex();
    if (prim() != 0) die("* needs ints");
    e1(104); esp(-1);         /* imul */
  }
  if (tok == '/' || tok == '%')
    die("no division: JAVA.COM has no idiv");
  return t;
}

sum() {
  int t;
  t = trm();
  while (tok == '+' || tok == '-') {
    if (t != 0) return t;     /* String + ... handled by caller */
    if (tok == '+') {
      lex();
      if (trm() != 0) die("+ needs ints here");
      e1(96); esp(-1);        /* iadd */
    }
    else {
      lex();
      if (trm() != 0) die("- needs ints");
      e1(100); esp(-1);       /* isub */
    }
  }
  return t;
}

/* string-concat chain: SB is on the stack; parse term ('+' term)*,
   appending each. Each operand is a multiplicative term, so once the
   expression is a concat every '+' concatenates (Java semantics:
   "x" + a + b is append(a).append(b), not "x" + (a+b)). */
concat() {
  int t;
  while (1) {
    t = trm();
    if (t == 0) sbAppI();
    else if (t == 1) sbAppS();
    else die("cannot concat an array");
    if (tok != '+') break;
    lex();
  }
  return 0;
}

/* Is the additive expression starting here a string concat? Scans
   tokens at paren-depth 0: a bare string literal or a String local
   makes it a concat. Methods only return int and arrays aren't
   Strings, so those are the only String operands in the subset. */
concatAhead() {
  int depth, i, sawstr, sawplus;
  lsave();
  depth = 0; sawstr = 0; sawplus = 0;
  while (tok != 0) {
    if (tok == '(' || tok == '[') depth++;
    else if (tok == ')') { if (depth == 0) break; depth--; }
    else if (tok == ']') depth--;
    else if (depth == 0 && (tok == ';' || tok == ',')) break;
    else if (depth == 0 && tok == '+') sawplus = 1;
    else if (depth == 0 && tok == 3) sawstr = 1;
    else if (depth == 0 && tok == 1) {
      i = lfind(tnm);
      if (i >= 0 && ltyp[i] == 1) sawstr = 1;
    }
    lex();
  }
  lrest();
  return sawstr && sawplus;
}

/* expression for println/print argument or String init/assign:
   returns 0 int / 1 String. */
xpr() {
  if (concatAhead()) {
    sbNew();
    concat();
    sbToS();
    return 1;
  }
  return sum();
}

/* ================= conditions ================= */
/* compile a condition; emits jumps-to-false threaded on a chain.
   Returns the false-chain head. Grammar:
     cond := cand { '||' cand }
     cand := crel { '&&' crel }
     crel := sum [relop sum]          (bare int: false when 0)
*/

crel(fch) int fch; {      /* returns updated false chain */
  int t, op;
  t = sum();
  if (tok == '<' || tok == '>' || tok == 200 || tok == 201 ||
      tok == 202 || tok == 203) {
    if (t != 0) die("comparison needs ints");
    op = tok;
    lex();
    if (sum() != 0) die("comparison needs ints");
    esp(-2);
    /* jump to FALSE on the opposite condition */
    if (op == '<') return cjmp(162, fch);       /* if_icmpge */
    if (op == '>') return cjmp(164, fch);       /* if_icmple */
    if (op == 200) return cjmp(163, fch);       /* <= : if_icmpgt */
    if (op == 201) return cjmp(161, fch);       /* >= : if_icmplt */
    if (op == 202) return cjmp(160, fch);       /* == : if_icmpne */
    return cjmp(159, fch);                      /* != : if_icmpeq */
  }
  if (t != 0) die("condition must be int or comparison");
  esp(-1);
  return cjmp(153, fch);                        /* ifeq -> false */
}

cand(fch) int fch; {
  fch = crel(fch);
  while (tok == 204) {        /* && */
    lex();
    fch = crel(fch);
  }
  return fch;
}

cond() {
  int fch, tch;
  /* returns a FALSE chain (jumps taken when the whole condition is
     false). tch collects "an earlier ||-alternative was true" jumps,
     which all land at the body (current clen on return). */
  tch = 0;
  fch = cand(0);
  while (tok == 205) {        /* || */
    lex();
    tch = cjmp(167, tch);     /* this cand true -> body */
    patch(fch, clen);         /* this cand false -> try next cand */
    fch = cand(0);
  }
  patch(tch, clen);           /* body starts right after the condition */
  return fch;
}

/* ================= statements ================= */
/* stmt() is used by block() before its definition; Small-C and clang
   both resolve the forward reference via implicit-int, so no prototype. */

block() {
  scplv++;
  expct('{');
  while (tok != '}' && tok != 0) stmt();
  expct('}');
  scpop();
  return 0;
}

body() {                  /* one statement or a block */
  if (tok == '{') block();
  else stmt();
  return 0;
}

/* assignment / call / ++ / -- statement, ident in tnm.
   endchk: if nonzero, expect ';' (for-updates pass 0). */
simple(endchk) int endchk; {
  int i, t, cst, d;
  if (streq(tnm, "System")) {
    lex(); expct('.');
    if (tokis("in")) {        /* System.in.read(); as a statement */
      lex(); expct('.');
      kweat("read");
      expct('('); expct(')');
      egetin(); einread();
      e1(87); esp(-1);        /* pop result */
      if (endchk) expct(';');
      return 0;
    }
    kweat("out");
    expct('.');
    if (tokis("println")) {
      lex(); expct('(');
      egetout();
      if (tok == ')') {
        lex();
        e1(182); esp(-1);
        e2u(cpmeth("java/io/PrintStream", "println", "()V"));
      }
      else {
        t = xpr();
        expct(')');
        e1(182); esp(-2);
        if (t == 1)
          e2u(cpmeth("java/io/PrintStream", "println",
                     "(Ljava/lang/String;)V"));
        else
          e2u(cpmeth("java/io/PrintStream", "println", "(I)V"));
      }
      if (endchk) expct(';');
      return 0;
    }
    kweat("print");
    expct('(');
    egetout();
    t = xpr();
    expct(')');
    e1(182); esp(-2);
    if (t == 1)
      e2u(cpmeth("java/io/PrintStream", "print",
                 "(Ljava/lang/String;)V"));
    else
      e2u(cpmeth("java/io/PrintStream", "print", "(I)V"));
    if (endchk) expct(';');
    return 0;
  }
  i = lfind(tnm);
  if (i < 0) {
    i = mfind(tnm);
    if (i >= 0) {
      lex();
      if (ecall(i) == 'I') { e1(87); esp(-1); }
      if (endchk) expct(';');
      return 0;
    }
    die("unknown identifier");
  }
  lex();
  if (tok == '[') {           /* arr[idx] = expr */
    eload(lslot[i], 1);
    lex();
    if (sum() != 0) die("index must be int");
    expct(']');
    expct('=');
    if (sum() != 0) die("array stores ints");
    if (ltyp[i] == 3) e1(84); else e1(79);   /* bastore/iastore */
    esp(-3);
    if (endchk) expct(';');
    return 0;
  }
  if (tok == 206 || tok == 207) {          /* ++ / -- */
    if (ltyp[i] != 0) die("++ needs an int");
    d = 1;
    if (tok == 207) d = 255;               /* -1 */
    lex();
    e1(132); e1(lslot[i]); e1(d);          /* iinc */
    if (endchk) expct(';');
    return 0;
  }
  if (tok == 208 || tok == 209) {          /* += / -= */
    if (ltyp[i] != 0) die("+=/-= needs an int");
    d = tok;
    lex();
    /* constant? then iinc */
    if (tok == 2 && nb1 == 0 && nb2 == 0 && nb3 == 0 && nb0 <= 127) {
      cst = nb0;
      lsave();
      lex();
      if (tok == ';' || tok == ')') {
        if (d == 209) cst = (0 - cst) & 255;
        e1(132); e1(lslot[i]); e1(cst);
        if (endchk) expct(';');
        return 0;
      }
      lrest();                 /* complex rhs, fall through */
    }
    eload(lslot[i], 0);
    if (sum() != 0) die("+= needs ints");
    if (d == 208) e1(96); else e1(100);
    esp(-1);
    estore(lslot[i], 0);
    if (endchk) expct(';');
    return 0;
  }
  expct('=');
  if (ltyp[i] == 1) {          /* String local reassign */
    if (xpr() != 1) die("String = needs a String");
    estore(lslot[i], 1);
    if (endchk) expct(';');
    return 0;
  }
  if (ltyp[i] != 0) die("cannot assign whole arrays");
  if (sum() != 0) die("int = needs an int");
  estore(lslot[i], 0);
  if (endchk) expct(';');
  return 0;
}

/* declaration:  int a = e, b;  |  int[] a = new int[e];
   boolean[] f = new boolean[e];  |  String s = "..."; */
decl() {
  int isarr, typ, i;
  isarr = 0;
  if (tokis("String")) {
    lex();
    if (tok != 1) die("name expected");
    i = ladd(tnm, 1);
    lex();
    expct('=');
    if (xpr() != 1) die("String needs a String value");
    estore(lslot[i], 1);
    expct(';');
    return 0;
  }
  if (tokis("boolean")) typ = 3;
  else typ = 2;               /* int[] */
  lex();
  if (tok == '[') {
    lex();
    expct(']');
    isarr = 1;
  }
  if (!isarr) {               /* plain int declarations */
    while (1) {
      if (tok != 1) die("name expected");
      i = ladd(tnm, 0);
      lex();
      if (tok == '=') {
        lex();
        if (sum() != 0) die("int init needs an int");
        estore(lslot[i], 0);
      }
      if (tok != ',') break;
      lex();
    }
    expct(';');
    return 0;
  }
  if (typ == 3) typ = 3; else typ = 2;
  if (tok != 1) die("name expected");
  i = ladd(tnm, typ);
  lex();
  expct('=');
  kweat("new");
  if (typ == 3) kweat("boolean");
  else kweat("int");
  expct('[');
  if (sum() != 0) die("array size must be int");
  expct(']');
  e1(188);                    /* newarray */
  if (typ == 3) e1(4); else e1(10);
  estore(lslot[i], 1);
  expct(';');
  return 0;
}

/* for-statement: single-pass. The update text precedes the body but
   runs after it, so its bytecode is captured and replayed. The capture
   buffer is indexed by loop depth (one flat 1-D array, Small-C has no
   2-D) so a nested for cannot clobber an outer one's saved update. */
char ubufs[640];              /* 8 loops x 80 bytes */
int ublens[8];

forst() {
  int condat, fch, umark, k, d, exit, base, n;
  expct('(');
  scplv++;
  if (tok == ';') lex();
  else if (tokis("int") || tokis("boolean") || tokis("String")) decl();
  else simple(1);
  condat = clen;
  fch = 0;
  if (tok != ';') fch = cond();
  expct(';');
  if (loopd >= 8) die("loops nested too deep");
  d = loopd;
  base = d * 80;
  umark = clen;               /* capture the update's code, then rewind */
  if (tok != ')') simple(0);
  n = clen - umark;
  if (n > 80) die("for-update too long");
  k = 0;
  while (k < n) { ubufs[base + k] = code[umark + k]; k++; }
  ublens[d] = n;
  clen = umark;
  expct(')');
  brkc[d] = 0; cnta[d] = -1; cntc[d] = 0;   /* continue -> update site */
  loopd++;
  body();
  loopd--;
  patch(cntc[d], clen);       /* continue jumps land at the update */
  k = 0;
  n = ublens[d];
  while (k < n) { e1(ubufs[base + k] & 255); k++; }
  ebrk(condat);
  exit = clen;
  patch(fch, exit);
  patch(brkc[d], exit);
  scpop();
  return 0;
}

stmt() {
  int fch, at, ech;
  if (tok == '{') { block(); return 0; }
  if (tok == ';') { lex(); return 0; }
  if (tok != 1) die("statement expected");
  if (streq(tnm, "if")) {
    lex();
    expct('(');
    fch = cond();
    expct(')');
    body();
    if (tokis("else")) {
      lex();
      ech = cjmp(167, 0);     /* skip else from then-path */
      patch(fch, clen);
      body();
      patch(ech, clen);
      return 0;
    }
    patch(fch, clen);
    return 0;
  }
  if (streq(tnm, "while")) {
    lex();
    expct('(');
    at = clen;
    /* while(true): no test at all */
    if (tokis("true")) {
      lex();
      fch = 0;
    }
    else fch = cond();
    expct(')');
    if (loopd >= 8) die("loops nested too deep");
    brkc[loopd] = 0;
    cnta[loopd] = at;         /* continue -> re-test */
    cntc[loopd] = 0;
    loopd++;
    body();
    loopd--;
    ebrk(at);
    patch(fch, clen);
    patch(brkc[loopd], clen);
    return 0;
  }
  if (streq(tnm, "for")) {
    lex();
    forst();
    return 0;
  }
  if (streq(tnm, "break")) {
    lex();
    expct(';');
    if (loopd == 0) die("break outside loop");
    brkc[loopd - 1] = cjmp(167, brkc[loopd - 1]);
    return 0;
  }
  if (streq(tnm, "continue")) {
    lex();
    expct(';');
    if (loopd == 0) die("continue outside loop");
    if (cnta[loopd - 1] >= 0) ebrk(cnta[loopd - 1]);   /* while: backward */
    else cntc[loopd - 1] = cjmp(167, cntc[loopd - 1]); /* for: forward */
    return 0;
  }
  if (streq(tnm, "return")) {
    lex();
    if (tok == ';') {
      lex();
      if (curret != 'V') die("return needs a value");
      e1(177);
      return 0;
    }
    if (sum() != 0) die("return needs an int");
    expct(';');
    if (curret != 'I') die("void method returns a value");
    e1(172); esp(-1);         /* ireturn */
    return 0;
  }
  if (streq(tnm, "int") || streq(tnm, "boolean") || streq(tnm, "String")) {
    decl();
    return 0;
  }
  simple(1);
  return 0;
}

/* ================= methods ================= */

mfin(nmidx, dsidx, flags) int nmidx, dsidx, flags; {
  int need, k;
  need = 8 + 14 + clen;
  if (mbl + need >= 2090) die("class too large");
  mbuf[mbl] = (flags >> 8) & 255; mbl++;
  mbuf[mbl] = flags & 255; mbl++;
  mbuf[mbl] = (nmidx >> 8) & 255; mbl++;
  mbuf[mbl] = nmidx & 255; mbl++;
  mbuf[mbl] = (dsidx >> 8) & 255; mbl++;
  mbuf[mbl] = dsidx & 255; mbl++;
  mbuf[mbl] = 0; mbl++;   /* attributes_count = 1 */
  mbuf[mbl] = 1; mbl++;
  k = cpu8("Code");
  mbuf[mbl] = (k >> 8) & 255; mbl++;
  mbuf[mbl] = k & 255; mbl++;
  k = 12 + clen;              /* attribute_length */
  mbuf[mbl] = 0; mbl++;
  mbuf[mbl] = 0; mbl++;
  mbuf[mbl] = (k >> 8) & 255; mbl++;
  mbuf[mbl] = k & 255; mbl++;
  mbuf[mbl] = (stkm >> 8) & 255; mbl++;
  mbuf[mbl] = stkm & 255; mbl++;
  mbuf[mbl] = (slotn >> 8) & 255; mbl++;
  mbuf[mbl] = slotn & 255; mbl++;
  mbuf[mbl] = 0; mbl++;   /* code_length u4 */
  mbuf[mbl] = 0; mbl++;
  mbuf[mbl] = (clen >> 8) & 255; mbl++;
  mbuf[mbl] = clen & 255; mbl++;
  k = 0;
  while (k < clen) { mbuf[mbl] = code[k]; mbl++; k++; }
  mbuf[mbl] = 0; mbl++;   /* exception_table_length */
  mbuf[mbl] = 0; mbl++;
  mbuf[mbl] = 0; mbl++;   /* code attributes_count */
  mbuf[mbl] = 0; mbl++;
  mtot++;
  return 0;
}

geninit() {               /* the constructor javac always emits */
  clen = 0; stkc = 0; stkm = 0; slotn = 1;
  e1(42); esp(1);             /* aload_0 */
  e1(183); esp(-1);
  e2u(cpmeth("java/lang/Object", "<init>", "()V"));
  e1(177);                    /* return */
  mfin(cpu8("<init>"), cpu8("()V"), 1);
  return 0;
}

/* parse "( params )" and register locals; returns nothing */
params(mi) int mi; {
  expct('(');
  if (mism[mi]) {             /* String[] args */
    kweat("String");
    expct('[');
    expct(']');
    if (tok != 1) die("parameter name expected");
    ladd(tnm, 1);             /* slot 0, unused */
    lex();
  }
  else if (tok != ')') {
    while (1) {
      kweat("int");
      if (tok != 1) die("parameter name expected");
      ladd(tnm, 0);
      lex();
      if (tok != ',') break;
      lex();
    }
  }
  expct(')');
  if (tokis("throws")) {      /* parse and ignore */
    lex();
    if (tok != 1) die("exception name expected");
    lex();
  }
  return 0;
}

method(mi) int mi; {
  int flags;
  clen = 0; stkc = 0; stkm = 0;
  lcnt = 0; lno2 = 0; slotn = 0; scplv = 0; loopd = 0;
  curret = mret[mi];
  params(mi);
  block();
  if (curret == 'V') e1(177); /* trailing return */
  flags = 8;                  /* static */
  if (mism[mi]) flags = 9;    /* public static */
  mgetnm(mi);
  mdesc(mi, dscb);
  mfin(cpu8(mnmb), cpu8(dscb), flags);
  return 0;
}

/* ================= pre-scan ================= */

int mnms2;                    /* method name arena top */

addmth(nm, argc, ret) char *nm; int argc, ret; {
  int j;
  if (mcnt >= 12) die("too many methods");
  mno[mcnt] = mnms2;
  j = 0;
  while (nm[j] != 0) {
    if (mnms2 >= 295) die("method names overflow");
    mnms[mnms2] = nm[j];
    mnms2++; j++;
  }
  mnl[mcnt] = j;
  marg[mcnt] = argc;
  mret[mcnt] = ret;
  mism[mcnt] = streq(nm, "main");
  mcnt++;
  return 0;
}

char pnm[36];                 /* pending method name in prescan */

prescan() {
  int depth, ret, argc, k;
  depth = 0;
  pos = 0; ln = 1;
  lex();
  while (tok != 0) {
    if (tok == '{') { depth++; lex(); }
    else if (tok == '}') { depth--; lex(); }
    else if (depth == 1 && tokis("static")) {
      lex();
      /* [void|int] name ( params ) */
      if (tokis("void")) ret = 'V';
      else if (tokis("int")) ret = 'I';
      else { lex(); continue; }
      lex();
      if (tok != 1) die("method name expected");
      k = 0;
      while (k < tl && k < 34) { pnm[k] = tnm[k]; k++; }
      pnm[k] = 0;
      lex();
      if (tok != '(') continue;
      lex();
      argc = 0;
      if (tok != ')') {
        argc = 1;
        while (tok != ')' && tok != 0) {
          if (tok == ',') argc++;
          lex();
        }
      }
      addmth(pnm, argc, ret);
    }
    else lex();
  }
  return 0;
}

/* ================= output ================= */

o1(b) int b; {
  if (olen >= 2595) die("class file too large");
  outb[olen] = b & 255;
  olen++;
  return 0;
}

o2(v) int v; {
  o1((v >> 8) & 255);
  o1(v & 255);
  return 0;
}

serial() {
  int i, thisc, superc;
  thisc = cpcls(clsnm);
  superc = cpcls("java/lang/Object");
  olen = 0;
  o1(202); o1(254); o1(186); o1(190);   /* 0xCA 0xFE 0xBA 0xBE */
  o2(0);                      /* minor */
  o2(49);                     /* major: pre-StackMapTable */
  o2(pcnt + 1);
  i = 0;
  while (i < pln) { o1(pool[i] & 255); i++; }
  o2(33);                     /* ACC_PUBLIC | ACC_SUPER */
  o2(thisc);
  o2(superc);
  o2(0);                      /* interfaces */
  o2(0);                      /* fields */
  o2(mtot);
  i = 0;
  while (i < mbl) { o1(mbuf[i] & 255); i++; }
  o2(0);                      /* class attributes */
  return 0;
}

/* ================= driver entry ================= */

jcmain() {
  int i;
  pln = 0; pcnt = 0; mbl = 0; mtot = 0; mcnt = 0; mnms2 = 0;
  olen = 0;
  prescan();
  if (mcnt == 0) die("no static methods found");
  /* the real pass */
  pos = 0; ln = 1;
  lex();
  if (tokis("public")) lex();
  kweat("class");
  if (tok != 1) die("class name expected");
  i = 0;
  while (i < tl && i < 38) { clsnm[i] = tnm[i]; i++; }
  clsnm[i] = 0;
  clsl = i;
  lex();
  /* pool order mirrors javac: Object.<init> first via <init> */
  geninit();
  expct('{');
  while (tok != '}' && tok != 0) {
    if (tokis("public")) lex();
    kweat("static");
    if (tokis("void") || tokis("int")) lex();
    else die("method must return void or int");
    if (tok != 1) die("method name expected");
    i = mfind(tnm);
    if (i < 0) die("prescan mismatch");
    lex();
    method(i);
  }
  serial();
  return 0;
}
