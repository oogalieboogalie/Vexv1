$ErrorActionPreference = "Stop"

function Invoke-ZigEval([string]$runnerPath) {
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & zig build run -- eval $runnerPath 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPref

    if ($exitCode -ne 0) {
        Write-Host "zig exited with code $exitCode"
        Write-Host ($output -join "`n")
        exit $exitCode
    }

    return ($output -join "`n")
}

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $text = Invoke-ZigEval "examples/vexc_run_error_demo.vex"
    $text2 = Invoke-ZigEval "examples/vexc_run_error_func_demo.vex"
    $text3 = Invoke-ZigEval "examples/vexc_run_eval_error_demo.vex"
} finally {
    Pop-Location
}

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

$checks2 = @(
    @{ Name = "func_error1"; Pattern = "\[vexc\] error: examples/vexc_input_error_func\.vex:1:4: fn expects a name" },
    @{ Name = "func_error2"; Pattern = "\[vexc\] error: examples/vexc_input_error_func\.vex:6:1: expected '\{' to start function body" },
    @{ Name = "func_return"; Pattern = "returned 7" }
)

$checks3 = @(
    @{ Name = "eval_error1"; Pattern = "\[vexc\] error: examples/vexc_input_eval_error\.vex: undefined var missing_var" },
    @{ Name = "eval_error2"; Pattern = "\[vexc\] error: examples/vexc_input_eval_error\.vex: undefined function missing_fn" },
    @{ Name = "eval_return"; Pattern = "returned 3" }
)

foreach ($check in $checks2) {
    if ($text2 -notmatch $check.Pattern) {
        Write-Host "Missing expected output: $($check.Name)"
        $failed = $true
    }
}

foreach ($check in $checks3) {
    if ($text3 -notmatch $check.Pattern) {
        Write-Host "Missing expected output: $($check.Name)"
        $failed = $true
    }
}

if ($failed) {
    Write-Host "Output was:"
    Write-Host $text
    Write-Host $text2
    Write-Host $text3
    exit 1
}

Write-Host "vexc error output checks: ok"
