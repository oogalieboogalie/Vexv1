$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & zig build run -- eval examples/vexc_run_error_demo.vex 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPref
} finally {
    Pop-Location
}

if ($exitCode -ne 0) {
    Write-Host "zig exited with code $exitCode"
    Write-Host ($output -join "`n")
    exit $exitCode
}

$text = $output -join "`n"

$checks = @(
    @{ Name = "error1"; Pattern = "\[vexc\] error: examples/vexc_input_error\.vex:3:3: expected '\)'" },
    @{ Name = "snippet"; Pattern = "print\(x" },
    @{ Name = "caret"; Pattern = "(?m)^\s*\^$" },
    @{ Name = "error2"; Pattern = "\[vexc\] error: examples/vexc_input_error\.vex:4:1: expected '\)' after print expr" },
    @{ Name = "error3"; Pattern = "\[vexc\] error: examples/vexc_input_error\.vex:4:1: expected '\}'" }
)

$failed = $false
foreach ($check in $checks) {
    if ($text -notmatch $check.Pattern) {
        Write-Host "Missing expected output: $($check.Name)"
        $failed = $true
    }
}

if ($failed) {
    Write-Host "Output was:"
    Write-Host $text
    exit 1
}

Write-Host "vexc error output check: ok"
