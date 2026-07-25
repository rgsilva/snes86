#include <stdio.h>
#define SIZE 8190
char flags[8191];
main() {
  int i, k, count, iter;
  for (iter = 1; iter <= 3; ++iter) {
    count = 0;
    for (i = 0; i <= SIZE; ++i) flags[i] = 1;
    for (i = 0; i <= SIZE; ++i)
      if (flags[i]) {
        k = i + i + i + 3;
        while (k <= SIZE) { flags[k] = 0; k = k + i + i + 3; }
        ++count;
      }
  }
  printf("%d primes (expect 1899)\n", count);
}
