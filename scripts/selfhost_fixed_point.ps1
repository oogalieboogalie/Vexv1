param(
    [switch]$Regen,
    [switch]$SkipSanity
)

$ErrorActionPreference = "Stop"

function Run-Step([string]$Label, [scriptblock]$Body) {
    Write-Host $Label
    $t = Measure-Command { & $Body }
    Write-Host ("[selfhost] elapsed_sec={0:N3}`n" -f $t.TotalSeconds)
}

if ($Regen -or -not (Test-Path "compiler_core_selfhost.vbc")) {
    Run-Step "[selfhost] generating compiler_core_selfhost.vbc via vexc..." {
        zig build run -- examples/vexc_run_compiler_core_bcsave_selfhost_demo.vex go
    }
} else {
    Write-Host "[selfhost] using existing compiler_core_selfhost.vbc (pass -Regen to rebuild)`n"
}

Run-Step "[selfhost] generating compiler_core_selfhost2.vbc via runbc..." {
    zig build run -- runbc compiler_core_selfhost.vbc bcsave src/compiler_core.vex compiler_core_selfhost2.vbc
}

$hash1 = (Get-FileHash compiler_core_selfhost.vbc -Algorithm SHA256).Hash
$hash2 = (Get-FileHash compiler_core_selfhost2.vbc -Algorithm SHA256).Hash

Write-Host "[selfhost] compiler_core_selfhost.vbc  sha256=$hash1"
Write-Host "[selfhost] compiler_core_selfhost2.vbc sha256=$hash2"

if ($hash1 -ne $hash2) {
    throw "[selfhost] fixed point FAILED: hashes differ"
}

Write-Host "[selfhost] fixed point OK"

if (-not $SkipSanity) {
    Run-Step "[selfhost] sanity: run hello.vex via compiler_core_selfhost2.vbc..." {
        zig build run -- runbc compiler_core_selfhost2.vbc eval examples/hello.vex
    }
}
