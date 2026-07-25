echo off
if not exist stdio.h copy c:\cc\stdio.h stdio.h >nul
scc %1 -m
asm %1 -S200 -NM
if exist prog.obj del prog.obj
ren %1.obj prog.obj
link @c:\cc\clib.rsp
del prog.obj
if exist %1.exe del %1.exe
ren prog.exe %1.exe
if exist vm.tmp del vm.tmp
echo Built %1.EXE - run it by name
