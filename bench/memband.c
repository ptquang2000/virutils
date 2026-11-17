/* memband.c -- memory bandwidth for the Windows bench guest (le11-vm-bench), where winsat
 * mem cannot run over ssh (it needs a D3D device). Each of N threads memcpy's its own
 * 64 MiB buffer into another, over and over, for T seconds; it prints the total copy
 * rate in MiB/s (bytes copied, read and write not counted twice).
 *   memband THREADS SECONDS
 * Build: gcc -O2 -o memband.exe memband.c   (w64devkit) */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUF (64u << 20)

static volatile LONG stop;
typedef struct { unsigned long long bytes; } Work;

static DWORD WINAPI run(LPVOID p) {
    Work *w = p;
    char *a = VirtualAlloc(0, BUF, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    char *b = VirtualAlloc(0, BUF, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    memset(a, 1, BUF); memset(b, 2, BUF);
    while (!stop) { memcpy(b, a, BUF); w->bytes += BUF; char *t = a; a = b; b = t; }
    return 0;
}

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 1, secs = argc > 2 ? atoi(argv[2]) : 10;
    HANDLE th[256]; Work w[256] = {0};
    LARGE_INTEGER f, t0, t1;
    QueryPerformanceFrequency(&f);
    for (int i = 0; i < n; i++) th[i] = CreateThread(0, 0, run, &w[i], 0, 0);
    Sleep(1000);                                   /* warm-up: allocation and first touch */
    unsigned long long s0 = 0, s1 = 0;
    for (int i = 0; i < n; i++) s0 += w[i].bytes;
    QueryPerformanceCounter(&t0);
    Sleep(secs * 1000);
    for (int i = 0; i < n; i++) s1 += w[i].bytes;
    QueryPerformanceCounter(&t1);
    stop = 1;
    WaitForMultipleObjects(n, th, TRUE, INFINITE);
    double dt = (double)(t1.QuadPart - t0.QuadPart) / f.QuadPart;
    printf("%.0f\n", (s1 - s0) / dt / (1 << 20));
    return 0;
}
