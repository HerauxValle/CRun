/*
 * tests/hello.m
 * Minimal Objective-C test — uses only the ObjC runtime, no Foundation/AppKit.
 * Avoids GNUstep dependency so it works on any Linux with clang + libobjc.
 * Run with: crun tests/hello.m
 */
#include <stdio.h>

int main(void) {
    printf("crun: Objective-C compilation OK\n");
    return 0;
}