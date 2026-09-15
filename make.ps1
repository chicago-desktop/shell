# chicago/shell on Windows — the same targets as the Makefile.
#
# `check` and `late-locals` need only node and python. `lint` and `test` need
# a runtime WITH the `gfx` module: the released wippy does not load this
# module at all (it answers "node with ID {gfx :gfx} not found"), and the base
# `chicago/tui-desktop` is a replacement pointing at `../tui-desktop`.
# Pass such a build with -Wippy or $env:WIPPY. There is no UI here, so the
# template's build/dev/typecheck targets are gone.
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'setup', 'check', 'late-locals', 'lint', 'test', 'test-pg', 'postgres-up', 'postgres-down', 'verify', 'release-check', 'publish')]
    [string]$Target = 'check',
    [string]$Organization,
    [string]$ModuleName,
    [string]$Title,
    [string]$Namespace,
    [string]$Tag,
    [string]$GitHubOwner,
    [ValidateSet('private', 'public')]
    [string]$Visibility = 'private',
    [string]$Wippy = $(if ($env:WIPPY) { $env:WIPPY } else { 'wippy' }),
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
# The module declares its own terminal.host, so the CLI no longer picks one by
# itself; the suites run on the application host, as in the Makefile.
$TestHost = 'wippy.terminal:host'

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments, [string]$Directory = $Root)
    Push-Location $Directory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

function Invoke-Init {
    if (-not $Organization -or -not $ModuleName -or -not $Title) {
        throw 'init requires -Organization, -ModuleName, and -Title'
    }
    $initArgs = @('scripts/init-module.mjs', '--organization', $Organization, '--module', $ModuleName, '--title', $Title)
    if ($Namespace) { $initArgs += @('--namespace', $Namespace) }
    if ($Tag) { $initArgs += @('--tag', $Tag) }
    if ($GitHubOwner) { $initArgs += @('--github-owner', $GitHubOwner) }
    Invoke-Checked node $initArgs
}

function Invoke-Setup {
    Invoke-Checked $Wippy @('update')
    Invoke-Checked $Wippy @('update') (Join-Path $Root 'test')
}

function Invoke-Check {
    Invoke-Checked node @('scripts/check-module.mjs')
    Invoke-Checked node @('scripts/test-initializer.mjs')
}

# Late locals are read as globals above their declaration and fail silently;
# `wippy lint` does not see them, so this runs first, as in the Makefile.
function Invoke-LateLocals {
    Invoke-Checked $Python @('tools/late-locals.py', 'src')
    Invoke-Checked $Python @('tools/late-locals.py', 'test')
}

function Invoke-Lint {
    Invoke-LateLocals
    Invoke-Checked $Wippy @('lint')
}

# The runner exits 0 when it discovers zero tests, which turns a broken
# discovery setup into a false-green run; mirror the Makefile guard.
function Invoke-TestRunner {
    param([string[]]$Arguments)
    Push-Location (Join-Path $Root 'test')
    try {
        $output = & $Wippy @Arguments 2>&1 | ForEach-Object { "$_" }
        $output | Write-Host
        if ($LASTEXITCODE -ne 0) { throw "wippy failed with exit code $LASTEXITCODE" }
        if ($output -match 'No tests found') { throw 'test runner discovered no tests' }
    } finally {
        Pop-Location
    }
}
function Invoke-Test { Invoke-TestRunner @('test', '--host', $TestHost) }
function Invoke-TestPg { Invoke-TestRunner @('test', '--host', $TestHost, '--profile', 'postgres') }
function Invoke-Verify {
    Invoke-Setup
    Invoke-Check
    Invoke-Lint
    Invoke-Test
}

switch ($Target) {
    'init' { Invoke-Init }
    'setup' { Invoke-Setup }
    'check' { Invoke-Check }
    'late-locals' { Invoke-LateLocals }
    'lint' { Invoke-Lint }
    'test' { Invoke-Test }
    'test-pg' { Invoke-TestPg }
    'postgres-up' { Invoke-Checked docker @('compose', '-f', 'compose.test.yaml', 'up', '-d', '--wait') }
    'postgres-down' { Invoke-Checked docker @('compose', '-f', 'compose.test.yaml', 'down', '-v') }
    'verify' { Invoke-Verify }
    'release-check' {
        Invoke-Verify
        Invoke-Checked $Wippy @('auth', 'status')
        Invoke-Checked $Wippy @('publish', '--dry-run', '--create', '--module-visibility', $Visibility, '--module-type', 'plugin')
    }
    'publish' {
        Invoke-Checked node @('scripts/check-module.mjs')
        Invoke-Checked $Wippy @('auth', 'status')
        Invoke-Checked $Wippy @('publish', '--create', '--module-visibility', $Visibility, '--module-type', 'plugin')
    }
}
