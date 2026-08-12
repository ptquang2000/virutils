#!/bin/bash

mkdir -p build
pushd build >/dev/null
clang++ -fproc-stat-report -g -O0 -glldb -std=c++23 ../main.cpp -lvirt-qemu -lvirt -o virutil
popd >/dev/null
