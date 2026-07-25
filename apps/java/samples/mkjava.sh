#!/bin/sh
# Rebuild the sample .class files (committed, so a JDK is optional).
# --release 8: newer javac emits invokedynamic string concat, which the
# snes86 interpreter deliberately does not implement.
set -e
cd "$(dirname "$0")"
javac --release 8 *.java
echo "compiled: $(ls *.class)"
