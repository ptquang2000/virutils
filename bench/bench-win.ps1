# bench-win.ps1 -- one benchmark pass inside the Windows bench guest (le11-vm-bench).
# Run elevated (ssh as the admin user `test`). Prints KEY=VALUE lines, one per metric.
# Needs: 7-Zip, C:\bench\diskspd, C:\bench\w64devkit, C:\bench\zstd-1.5.7.tar.gz.
param([int]$T = 20)
$ErrorActionPreference = 'Continue'
$nc = [Environment]::ProcessorCount
function Say($k, $v) { "$k=$v" }
Say nproc $nc
Say os ((Get-CimInstance Win32_OperatingSystem).Version)

# --- CPU: 7-Zip ---------------------------------------------------------------------
$z = 'C:\Program Files\7-Zip\7z.exe'
function Get-7zMips($mt) { ((& $z b "-mmt$mt" | Select-String '^Tot:') -split '\s+')[-1] }
Say 7z_mips_1t (Get-7zMips 1)
Say 7z_mips_nt (Get-7zMips $nc)

# --- memory bandwidth: memband.exe (tools\memband.c), memcpy MiB/s; winsat mem needs a D3D device ---
Say mem_mibs_1t (C:\bench\memband.exe 1 $T)
Say mem_mibs_nt (C:\bench\memband.exe $nc $T)

# --- disk: DiskSpd, unbuffered (-Sh), on C: ---------------------------------------------------
$ds = 'C:\bench\diskspd\amd64\diskspd.exe'
$f  = 'C:\bench\io.dat'
& $ds -c4G -b1M -o8 -t1 -w100 -d3 -Sh $f | Out-Null       # lay the file out
function Invoke-Ds($bs, $qd, $w, $rand) {
    $a = @("-b$bs", "-o$qd", '-t1', "-w$w", "-d$T", '-W3', '-Sh', '-L', '-Rxml')
    if ($rand) { $a += '-r' }
    [xml]$x = & $ds @a $f
    $tg = $x.Results.TimeSpan
    $secs = [double]$tg.TestTimeSeconds
    $bytes = 0; $ios = 0
    foreach ($t in $tg.Thread) { foreach ($tt in $t.Target) { $bytes += [double]$tt.BytesCount; $ios += [double]$tt.IOCount } }
    @{ iops = [math]::Round($ios / $secs); mbs = [math]::Round($bytes / $secs / 1MB, 1) }
}
Say ds_4k_randread_iops  (Invoke-Ds 4K 32 0 $true).iops
Say ds_4k_randwrite_iops (Invoke-Ds 4K 32 100 $true).iops
Say ds_1m_seqread_mbs    (Invoke-Ds 1M 8 0 $false).mbs
Say ds_1m_seqwrite_mbs   (Invoke-Ds 1M 8 100 $false).mbs
Remove-Item $f -Force

# --- real workload: cold build of zstd with w64devkit (gcc + make) -------------------------------
$b = 'C:\bench\zstd-build'
Remove-Item -Recurse -Force $b -ErrorAction SilentlyContinue
New-Item -ItemType Directory $b | Out-Null
tar -xzf C:\bench\zstd-1.5.7.tar.gz -C $b
$env:PATH = "C:\bench\w64devkit\bin;$env:PATH"
$sw = [Diagnostics.Stopwatch]::StartNew()
& C:\bench\w64devkit\bin\make.exe -s -C "$b\zstd-1.5.7" "-j$nc" zstd *> C:\bench\zstd-build.log
$rc = $LASTEXITCODE
$sw.Stop()
Say build_zstd_rc $rc
Say build_zstd_s ([math]::Round($sw.Elapsed.TotalSeconds, 1))
Remove-Item -Recurse -Force $b
Say done 1
