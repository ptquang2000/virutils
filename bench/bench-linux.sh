#!/bin/sh
# bench-linux.sh -- one benchmark pass inside a Linux bench guest (le11-vm-bench).
# Run as root (sudo). Prints KEY=VALUE lines, one per metric; the host collects them.
# Needs: 7z (7zip), sysbench, fio, python3, gcc/make, /opt/bench/zstd-1.5.7.tar.gz.
set -u
T=${T:-20}                       # seconds per timed test
FIO_FILE=/var/tmp/fio.bench      # on the guest's root disk
NC=$(nproc)

say() { echo "$1=$2"; }
say nproc "$NC"
say kernel "$(uname -r)"

# --- CPU: 7-Zip ---------------------------------------------------------------
# 7z b prints "Tot:" with the overall rating in MIPS as its last field.
z1=$(7z b -mmt1 2>/dev/null | awk '/^Tot:/{print $NF}')
zn=$(7z b -mmt"$NC" 2>/dev/null | awk '/^Tot:/{print $NF}')
say 7z_mips_1t "$z1"; say 7z_mips_nt "$zn"

# --- CPU: sysbench --------------------------------------------------------------
s1=$(sysbench cpu --threads=1 --time="$T" run | awk '/events per second/{print $NF}')
sn=$(sysbench cpu --threads="$NC" --time="$T" run | awk '/events per second/{print $NF}')
say sb_cpu_eps_1t "$s1"; say sb_cpu_eps_nt "$sn"

# --- memory bandwidth ------------------------------------------------------------
m1=$(sysbench memory --threads=1 --memory-block-size=1M --memory-total-size=1000G --time="$T" run | sed -n 's/.*(\([0-9.]*\) MiB\/sec).*/\1/p')
mn=$(sysbench memory --threads="$NC" --memory-block-size=1M --memory-total-size=1000G --time="$T" run | sed -n 's/.*(\([0-9.]*\) MiB\/sec).*/\1/p')
say mem_mibs_1t "$m1"; say mem_mibs_nt "$mn"

# --- disk: fio, direct I/O on the root disk ---------------------------------------
fio_one() { # name rw bs iodepth -> prints iops and MB/s
    fio --name="$1" --filename="$FIO_FILE" --size=4G --rw="$2" --bs="$3" --iodepth="$4" \
        --numjobs=1 --ioengine=libaio --direct=1 --time_based --runtime="$T" --ramp_time=3 \
        --group_reporting --output-format=json 2>/dev/null |
    python3 -c 'import json,sys; j=json.load(sys.stdin)["jobs"][0]; d=j["read"] if j["read"]["io_bytes"] else j["write"]; print("%.0f %.1f" % (d["iops"], d["bw"]/1024))'
}
# lay the file out once, written for real (not sparse), so reads hit the disk
fio --name=lay --filename="$FIO_FILE" --size=4G --rw=write --bs=1M --direct=1 --ioengine=libaio --iodepth=8 >/dev/null 2>&1
set -- $(fio_one rr randread 4k 32);  say fio_4k_randread_iops "$1"
set -- $(fio_one rw randwrite 4k 32); say fio_4k_randwrite_iops "$1"
set -- $(fio_one sr read 1M 8);       say fio_1m_seqread_mbs "$2"
set -- $(fio_one sw write 1M 8);      say fio_1m_seqwrite_mbs "$2"
rm -f "$FIO_FILE"

# --- real workload: cold build of zstd -----------------------------------------------
B=/var/tmp/zstd-build
rm -rf "$B"; mkdir -p "$B"
tar -xzf /opt/bench/zstd-1.5.7.tar.gz -C "$B"
sync; echo 3 > /proc/sys/vm/drop_caches
t0=$(date +%s.%N)
make -s -C "$B/zstd-1.5.7" -j"$NC" zstd >/var/tmp/zstd-build.log 2>&1; rc=$?
t1=$(date +%s.%N)
say build_zstd_rc "$rc"
say build_zstd_s "$(echo "$t1 $t0" | awk '{printf "%.1f", $1-$2}')"
rm -rf "$B"
say done 1
