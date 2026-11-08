[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$IncludeHardware
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here) -and $MyInvocation.MyCommand.Path) {
        $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if ([string]::IsNullOrWhiteSpace($here)) {
        $here = (Get-Location).Path
    }
    $ScriptPath = Join-Path $here 'win_btcomms.ps1'
}

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    Write-Host "ERROR: main script not found: $ScriptPath" -ForegroundColor Red
    Write-Host "Pass it explicitly with -ScriptPath." -ForegroundColor Yellow
    exit 2
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path


$script:Passed   = 0
$script:Failed   = 0
$script:Skipped  = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    Write-Host ("[TEST] {0}" -f $Name) -ForegroundColor Cyan
    try {
        & $Body
        $script:Passed++
        Write-Host '  PASS' -ForegroundColor Green
    }
    catch {
        $script:Failed++
        $script:Failures.Add(("{0}: {1}" -f $Name, $_.Exception.Message))
        Write-Host ("  FAIL: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Skip-Case {
    param([string]$Name, [string]$Reason)
    $script:Skipped++
    Write-Host ("[SKIP] {0} - {1}" -f $Name, $Reason) -ForegroundColor DarkYellow
}

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Expected true.')
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message = 'Expected false.')
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -ne $Actual) {
        if ([string]::IsNullOrEmpty($Message)) {
            $Message = "Expected '$Expected' but got '$Actual'."
        }
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$MessagePattern = '.'
    )

    $threw = $false
    try {
        & $Body
    }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw ("Exception did not match pattern '{0}'. Got: {1}" -f
                $MessagePattern, $_.Exception.Message)
        }
    }

    if (-not $threw) {
        throw 'Expected an exception, none was thrown.'
    }
}


Write-Host ''
Write-Host '=== Environment ===' -ForegroundColor Cyan
Write-Host ("PSVersion : {0}" -f $PSVersionTable.PSVersion)
Write-Host ("PSEdition : {0}" -f $PSVersionTable.PSEdition)
Write-Host ("Script    : {0}" -f $ScriptPath)
Write-Host ("Hardware  : {0}" -f $(if ($IncludeHardware) { 'included' } else { 'not included (use -IncludeHardware)' }))

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Host 'This test suite requires Windows PowerShell 5.1 (powershell.exe).' -ForegroundColor Red
    exit 2
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    foreach ($parseError in $parseErrors) {
        Write-Host ("PARSE ERROR: {0}" -f $parseError.Message) -ForegroundColor Red
    }
    exit 2
}


Write-Host ''
Write-Host '=== Loading helper functions from main script ===' -ForegroundColor Cyan

$functionNames = @(
    'ConvertTo-CleanAddress'
    'Get-AddressFromId'
    'Get-UniquePath'
    'New-ObexPacket'
    'New-NameHeader'
    'Read-ObexHeaders'
    'Read-Exact'
)

$fnSources = @{}
$functionAsts = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)

foreach ($functionAst in $functionAsts) {
    $fnSources[$functionAst.Name] = $functionAst.Extent.Text
}

foreach ($name in $functionNames) {
    if (-not $fnSources.ContainsKey($name)) {
        Write-Host "ERROR: function '$name' not found in $ScriptPath" -ForegroundColor Red
        exit 2
    }
    . ([scriptblock]::Create($fnSources[$name]))
}

Write-Host ("Loaded: {0}" -f ($functionNames -join ', '))


Test-Case 'ConvertTo-CleanAddress accepts colon-separated MAC' {
    Assert-Equal 'AABBCCDDEEFF' (ConvertTo-CleanAddress 'AA:BB:CC:DD:EE:FF')
}
Test-Case 'ConvertTo-CleanAddress accepts dash-separated MAC' {
    Assert-Equal 'AABBCCDDEEFF' (ConvertTo-CleanAddress 'aa-bb-cc-dd-ee-ff')
}
Test-Case 'ConvertTo-CleanAddress accepts bare 12 hex' {
    Assert-Equal '001122AABBCC' (ConvertTo-CleanAddress '001122aabbcc')
}
Test-Case 'ConvertTo-CleanAddress rejects short input' {
    Assert-Throws { ConvertTo-CleanAddress 'AA:BB:CC' } 'Invalid Bluetooth address'
}
Test-Case 'ConvertTo-CleanAddress rejects non-hex input' {
    Assert-Throws { ConvertTo-CleanAddress 'ZZ:BB:CC:DD:EE:FF' } 'Invalid Bluetooth address'
}


Test-Case 'Get-AddressFromId extracts trailing MAC from a device id' {
    $id = 'Bluetooth#Bluetooth00:11:22:33:44:55-ac:c0:48:20:b6:2c'
    Assert-Equal 'ACC04820B62C' (Get-AddressFromId $id)
}
Test-Case 'Get-AddressFromId returns ? for unrelated id' {
    Assert-Equal '?' (Get-AddressFromId 'USB#ROOT_HUB30#something')
}


Test-Case 'New-ObexPacket builds header-only packet' {
    $bytes = New-ObexPacket 0x80 ([byte[]]@())
    Assert-Equal 3 $bytes.Length
    Assert-Equal 0x80 $bytes[0]
    Assert-Equal 0x00 $bytes[1]
    Assert-Equal 0x03 $bytes[2]
}
Test-Case 'New-ObexPacket builds packet with body and correct length' {
    $bytes = New-ObexPacket 0x02 ([byte[]]@(0xAA, 0xBB, 0xCC))
    Assert-Equal 6 $bytes.Length
    Assert-Equal 0x02 $bytes[0]
    Assert-Equal 0x00 $bytes[1]
    Assert-Equal 0x06 $bytes[2]
    Assert-Equal 0xAA $bytes[3]
    Assert-Equal 0xCC $bytes[5]
}
Test-Case 'New-ObexPacket handles length greater than 255' {
    $body = New-Object byte[] 300
    for ($i = 0; $i -lt 300; $i++) { $body[$i] = 0x41 }

    $bytes = New-ObexPacket 0x02 $body
    Assert-Equal 303 $bytes.Length

    $length = ([int]$bytes[1] -shl 8) -bor [int]$bytes[2]
    Assert-Equal 303 $length
}


Test-Case 'New-NameHeader encodes name as UTF-16BE with NUL terminator' {
    $header = New-NameHeader 'a.txt'
    Assert-Equal 0x01 $header[0]
    Assert-Equal 15 $header.Length
    Assert-Equal 0x00 $header[1]
    Assert-Equal 0x0F $header[2]
    Assert-Equal 0x00 $header[3]
    Assert-Equal 0x61 $header[4]
    Assert-Equal 0x00 $header[13]
    Assert-Equal 0x00 $header[14]
}


Test-Case 'Read-ObexHeaders parses a Name header built by New-NameHeader' {
    $header = New-NameHeader 'report.pdf'
    $parsed = @(Read-ObexHeaders $header)

    Assert-Equal 1 $parsed.Count
    Assert-Equal 0x01 $parsed[0].Id

    $decoded = [System.Text.Encoding]::BigEndianUnicode.GetString(
        $parsed[0].Data
    ).TrimEnd([char]0)

    Assert-Equal 'report.pdf' $decoded
}
Test-Case 'Read-ObexHeaders parses 4-byte and byte-sequence headers' {
    # 0xC3: four data bytes.
    # 0x48: byte-sequence header, length 5 includes ID and two length bytes.
    $data = [byte[]]@(
        0xC3, 0x00, 0x00, 0x10, 0x00,
        0x48, 0x00, 0x05, 0x7A, 0x7B
    )

    $parsed = @(Read-ObexHeaders -Data $data)

    Assert-Equal 2 $parsed.Count

    Assert-Equal 0xC3 $parsed[0].Id
    Assert-Equal 4 $parsed[0].Data.Length
    Assert-Equal 0x00 $parsed[0].Data[0]
    Assert-Equal 0x00 $parsed[0].Data[1]
    Assert-Equal 0x10 $parsed[0].Data[2]
    Assert-Equal 0x00 $parsed[0].Data[3]

    Assert-Equal 0x48 $parsed[1].Id
    Assert-Equal 2 $parsed[1].Data.Length
    Assert-Equal 0x7A $parsed[1].Data[0]
    Assert-Equal 0x7B $parsed[1].Data[1]
}
Test-Case 'Read-ObexHeaders parses a 1-byte (0x80-class) header' {
    $parsed = @(Read-ObexHeaders ([byte[]]@(0x97, 0x01)))
    Assert-Equal 1 $parsed.Count
    Assert-Equal 0x97 $parsed[0].Id
    Assert-Equal 0x01 $parsed[0].Data[0]
}
Test-Case 'Read-ObexHeaders stops on a byte-sequence length below 3' {
    $parsed = @(Read-ObexHeaders ([byte[]]@(0x48, 0x00, 0x02, 0x7A, 0x7B)))
    Assert-Equal 0 $parsed.Count
}
Test-Case 'Read-ObexHeaders stops on truncated byte-sequence header prefix' {
    $parsed = @(Read-ObexHeaders ([byte[]]@(0x48, 0x00)))
    Assert-Equal 0 $parsed.Count
}
Test-Case 'Read-ObexHeaders stops when byte-sequence length exceeds available data' {
    $parsed = @(Read-ObexHeaders ([byte[]]@(0x48, 0x00, 0x06, 0x7A, 0x7B)))
    Assert-Equal 0 $parsed.Count
}
Test-Case 'Read-ObexHeaders stops on truncated 4-byte quantity header' {
    $parsed = @(Read-ObexHeaders ([byte[]]@(0xC3, 0x00, 0x00, 0x10)))
    Assert-Equal 0 $parsed.Count
}
Test-Case 'Read-ObexHeaders stops on truncated 1-byte header' {
    $parsed = @(Read-ObexHeaders ([byte[]]@(0x97)))
    Assert-Equal 0 $parsed.Count
}
Test-Case 'Read-ObexHeaders accepts empty input' {
    $parsed = @(Read-ObexHeaders ([byte[]]@()))
    Assert-Equal 0 $parsed.Count
}


Test-Case 'Read-Exact reads the requested number of bytes' {
    $stream = New-Object System.IO.MemoryStream(,[byte[]]@(1, 2, 3, 4, 5))
    $buffer = Read-Exact $stream 3

    Assert-Equal 3 $buffer.Length
    Assert-Equal 1 $buffer[0]
    Assert-Equal 3 $buffer[2]
}
Test-Case 'Read-Exact returns empty array for zero count' {
    $stream = New-Object System.IO.MemoryStream(,[byte[]]@(1, 2, 3))
    $buffer = Read-Exact $stream 0
    Assert-Equal 0 $buffer.Length
}
Test-Case 'Read-Exact throws when stream closes early' {
    $stream = New-Object System.IO.MemoryStream(,[byte[]]@(1, 2))
    Assert-Throws { Read-Exact $stream 5 } 'Connection closed'
}


$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) (
    'btcommtest_' + [guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop | Out-Null

try {
    Test-Case 'Get-UniquePath returns plain name when no collision' {
        $path = Get-UniquePath -Directory $tempDirectory -FileName 'file.txt'
        Assert-Equal (Join-Path $tempDirectory 'file.txt') $path
    }
    Test-Case 'Get-UniquePath adds (1) on collision' {
        $path1 = Get-UniquePath -Directory $tempDirectory -FileName 'dup.txt'
        Set-Content -LiteralPath $path1 -Value 'x'

        $path2 = Get-UniquePath -Directory $tempDirectory -FileName 'dup.txt'
        Assert-Equal (Join-Path $tempDirectory 'dup (1).txt') $path2
    }
    Test-Case 'Get-UniquePath sanitizes invalid filename characters' {
        $path = Get-UniquePath -Directory $tempDirectory -FileName 'a:b*c?.txt'
        $leaf = [IO.Path]::GetFileName($path)

        foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
            Assert-False ($leaf.Contains([string]$character)) (
                "Leaf still contains invalid character '$character'"
            )
        }
    }
    Test-Case 'Get-UniquePath substitutes a default name for blank input' {
        $path = Get-UniquePath -Directory $tempDirectory -FileName '   '
        $leaf = [IO.Path]::GetFileName($path)
        Assert-True ($leaf -like 'bluetooth_file_*') "Unexpected leaf: $leaf"
    }
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}


Write-Host ''
Write-Host '=== Parameter validation ===' -ForegroundColor Cyan

Test-Case 'Mode parameter declares the expected ValidateSet' {
    $paramAst = $ast.ParamBlock
    Assert-True ($null -ne $paramAst) 'Script has no param block.'

    $modeParam = $paramAst.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }

    Assert-True ($null -ne $modeParam) 'Mode parameter not found.'

    $validateSet = $modeParam.Attributes |
        Where-Object { $_.TypeName.Name -eq 'ValidateSet' } |
        Select-Object -First 1

    Assert-True ($null -ne $validateSet) 'ValidateSet attribute not found on -Mode.'

    $values = @($validateSet.PositionalArguments | ForEach-Object { $_.Value })
    $expected = @('paired', 'scan', 'send', 'receive', 'chathost', 'chatjoin', 'blescan')

    foreach ($value in $expected) {
        Assert-True ($values -contains $value) "ValidateSet missing '$value'."
    }
    Assert-Equal $expected.Count $values.Count
}
Test-Case 'blescan mode is dispatched to Show-BleScan' {
    $mainText = Get-Content -LiteralPath $ScriptPath -Raw
    Assert-True ($mainText -match "(?m)'blescan'\s*\{\s*Show-BleScan\s*\}") `
        'The main mode switch does not dispatch blescan to Show-BleScan.'
}
Test-Case 'Show-BleScan uses the Windows BLE Advertisement namespace' {
    $bleFunction = $functionAsts | Where-Object { $_.Name -eq 'Show-BleScan' } | Select-Object -First 1
    Assert-True ($null -ne $bleFunction) 'Show-BleScan function not found.'
    $bleText = $bleFunction.Extent.Text
    Assert-True ($bleText -match 'Windows\.Devices\.Bluetooth\.Advertisement\.BluetoothLEAdvertisementWatcher') `
        'BLE watcher type must use the Bluetooth.Advertisement namespace.'
    Assert-True ($bleText -match 'Windows\.Devices\.Bluetooth\.Advertisement\.BluetoothLEScanningMode') `
        'BLE scanning mode type must use the Bluetooth.Advertisement namespace.'
}
Test-Case 'Show-BleScan subscribes to Received events and stops the watcher in finally' {
    $bleFunction = $functionAsts | Where-Object { $_.Name -eq 'Show-BleScan' } | Select-Object -First 1
    Assert-True ($null -ne $bleFunction) 'Show-BleScan function not found.'
    $bleText = $bleFunction.Extent.Text
    Assert-True ($bleText.Contains("`$receivedQ.Subscribe(`$watcher, 'Received')")) `
        'BLE watcher is not subscribed to Received events.'
    Assert-True ($bleText -match '\$watcher\.Start\(\)') 'BLE watcher is never started.'

    $tryStatements = $bleFunction.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.TryStatementAst]
    }, $true)
    $stoppedInFinally = $false
    foreach ($tryStatement in $tryStatements) {
        if ($null -ne $tryStatement.Finally -and
            $tryStatement.Finally.Extent.Text -match '\$watcher\.Stop\(\)') {
            $stoppedInFinally = $true
            break
        }
    }
    Assert-True $stoppedInFinally `
        'BLE watcher must be stopped inside a finally block so cleanup also runs after errors.'
}
Test-Case 'Show-BleScan reports RSSI, estimated distance, and sample count' {
    $bleFunction = $functionAsts | Where-Object { $_.Name -eq 'Show-BleScan' } | Select-Object -First 1
    Assert-True ($null -ne $bleFunction) 'Show-BleScan function not found.'
    $bleText = $bleFunction.Extent.Text
    foreach ($field in @('RawSignalStrengthInDBm', 'EstimatedDistance', 'Samples')) {
        Assert-True ($bleText -match [regex]::Escape($field)) "BLE scan output is missing '$field'."
    }
    Assert-True ($bleText -match 'rough RSSI-based estimate') `
        'BLE scan should clarify that distance is only an estimate.'
}
Test-Case 'BLE WinRT type references are scoped to Show-BleScan' {
    $mainText = Get-Content -LiteralPath $ScriptPath -Raw
    $bleFunction = $functionAsts | Where-Object { $_.Name -eq 'Show-BleScan' } | Select-Object -First 1
    Assert-True ($null -ne $bleFunction) 'Show-BleScan function not found.'
    $outsideBle = $mainText.Replace($bleFunction.Extent.Text, '')
    Assert-False ($outsideBle -match 'BluetoothLEAdvertisementWatcher|BluetoothLEScanningMode') `
        'BLE-specific WinRT type references should not be loaded by Classic scan initialization.'
}
Test-Case 'Script declares CmdletBinding' {
    $paramAst = $ast.ParamBlock
    $hasCmdletBinding = $paramAst.Attributes |
        Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }

    Assert-True ($null -ne $hasCmdletBinding) 'CmdletBinding attribute missing.'
}
Test-Case 'ScanSeconds has a sane default' {
    $paramAst = $ast.ParamBlock
    $parameter = $paramAst.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -eq 'ScanSeconds' }

    Assert-True ($null -ne $parameter) 'ScanSeconds parameter not found.'
    Assert-Equal 15 ([int]$parameter.DefaultValue.Value)
}
Test-Case 'Nickname default references COMPUTERNAME' {
    $paramAst = $ast.ParamBlock
    $parameter = $paramAst.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -eq 'Nickname' }

    Assert-True ($null -ne $parameter) 'Nickname parameter not found.'
    Assert-True ($parameter.DefaultValue.Extent.Text -match 'COMPUTERNAME') `
        'Nickname default does not reference COMPUTERNAME.'
}


Write-Host ''
Write-Host '=== Live invocation failure paths (hardware-free) ===' -ForegroundColor Cyan

$psExe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) {
    $psExe = 'powershell.exe'
}

function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][string]$Value)

    # Quote each argument for Start-Process, which joins ArgumentList entries.
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-Main {
    param([string[]]$MainArgs)

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    $stdoutFile = Join-Path ([IO.Path]::GetTempPath()) (
        'btout_' + [guid]::NewGuid().ToString('N') + '.txt'
    )
    $stderrFile = Join-Path ([IO.Path]::GetTempPath()) (
        'bterr_' + [guid]::NewGuid().ToString('N') + '.txt'
    )

    try {
        $arguments = @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            $ScriptPath
        ) + $MainArgs

        $quotedArguments = @(
            $arguments | ForEach-Object {
                ConvertTo-ProcessArgument ([string]$_)
            }
        )

        $process = Start-Process -FilePath $psExe `
            -ArgumentList $quotedArguments `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile `
            -NoNewWindow -Wait -PassThru

        $stdout = if (Test-Path -LiteralPath $stdoutFile) {
            Get-Content -LiteralPath $stdoutFile -Raw
        } else { '' }

        $stderr = if (Test-Path -LiteralPath $stderrFile) {
            Get-Content -LiteralPath $stderrFile -Raw
        } else { '' }

        return [pscustomobject]@{
            Output   = (($stdout + "`n" + $stderr) -replace "`r", '')
            StdOut   = $stdout
            StdErr   = $stderr
            ExitCode = $process.ExitCode
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $previousEap
    }
}

Test-Case 'Invalid -Mode value is rejected by ValidateSet' {
    $result = Invoke-Main -MainArgs @('-Mode', 'nonsense')

    Assert-True ($result.ExitCode -ne 0) (
        "Expected non-zero exit, got $($result.ExitCode). Output: $($result.Output)"
    )
    Assert-True ($result.Output -match 'nonsense') (
        "Output does not name the invalid value. Output: $($result.Output)"
    )
    Assert-True ($result.Output -match 'does not belong to the set|ValidateSet|Cannot validate argument') `
        "Output does not look like a ValidateSet rejection. Output: $($result.Output)"
}
Test-Case 'send mode without -FilePath reports an error' {
    $result = Invoke-Main -MainArgs @('-Mode', 'send')
    Assert-True ($result.Output -match 'Specify -FilePath') "Unexpected output: $($result.Output)"
    Assert-Equal 1 $result.ExitCode
}
Test-Case 'send mode with nonexistent file reports an error' {
    $result = Invoke-Main -MainArgs @('-Mode', 'send', '-FilePath', 'C:\does\not\exist.bin')
    Assert-True ($result.Output -match 'File not found') "Unexpected output: $($result.Output)"
    Assert-Equal 1 $result.ExitCode
}
Test-Case 'chatjoin without target reports an error' {
    $result = Invoke-Main -MainArgs @('-Mode', 'chatjoin')
    Assert-True ($result.Output -match 'Specify -DeviceAddress or -DeviceName') `
        "Unexpected output: $($result.Output)"
    Assert-Equal 1 $result.ExitCode
}
Test-Case 'chatjoin with malformed address reports an error' {
    $result = Invoke-Main -MainArgs @('-Mode', 'chatjoin', '-DeviceAddress', 'not-a-mac')
    Assert-True ($result.Output -match 'Invalid Bluetooth address') "Unexpected output: $($result.Output)"
    Assert-Equal 1 $result.ExitCode
}
Test-Case 'chatjoin with unknown paired name reports an error' {
    $result = Invoke-Main -MainArgs @('-Mode', 'chatjoin', '-DeviceName', '__no_such_device_zzz__')
    Assert-True ($result.Output -match 'No paired device matching name') "Unexpected output: $($result.Output)"
    Assert-Equal 1 $result.ExitCode
}

Write-Host ''
if ($IncludeHardware) {
Write-Host '=== Hardware smoke test ===' -ForegroundColor Cyan

$radio = $null
$radioQuerySucceeded = $false

try {
    $bluetoothDevices = @(
        Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction Stop
    )
    $radioQuerySucceeded = $true


    $radio = $bluetoothDevices |
        Where-Object {
            $_.FriendlyName -match 'Bluetooth' -and
            $_.FriendlyName -notmatch 'Enumerator'
        } |
        Select-Object -First 1
}
catch {
    Write-Host ("  Bluetooth PnP query unavailable: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

if (-not $radioQuerySucceeded) {
    Skip-Case 'paired mode enumerates devices through the Windows Bluetooth stack' 'could not query present Bluetooth PnP devices'
    Skip-Case 'scan mode runs against the Windows Bluetooth stack' 'could not query present Bluetooth PnP devices'
    Skip-Case 'blescan mode starts the Windows BLE watcher' 'could not query present Bluetooth PnP devices'
}
elseif ($null -eq $radio) {
    Skip-Case 'paired mode enumerates devices through the Windows Bluetooth stack' 'no Bluetooth adapter detected'
    Skip-Case 'scan mode runs against the Windows Bluetooth stack' 'no Bluetooth adapter detected'
    Skip-Case 'blescan mode starts the Windows BLE watcher' 'no Bluetooth adapter detected'
}
else {
    Write-Host ("  Adapter: {0} (PnP status: {1})" -f
        $radio.FriendlyName, $radio.Status) -ForegroundColor DarkGray


    Test-Case '-Mode paired enumerates devices through the Windows Bluetooth stack' {
        $result = Invoke-Main -MainArgs @('-Mode', 'paired')

        Assert-Equal 0 $result.ExitCode (
            "Unexpected exit code: $($result.ExitCode). Output: $($result.Output)"
        )
        Assert-False ($result.Output -match '(?m)^ERROR:') "Script errored: $($result.Output)"
        Assert-True ($result.Output -match 'Paired Bluetooth devices') `
            'Did not reach the paired-devices section.'

        $hasEmpty = $result.Output -match 'No paired devices found'
        $hasTable = $result.Output -match '(?m)^\s*Name\s+Address\s+Paired\s+Connected\s*$'

        Assert-True ($hasTable -or $hasEmpty) "Unexpected paired-mode output: $($result.Output)"

        if ($hasEmpty) {
            Write-Host '  (no paired devices found; valid result)' -ForegroundColor DarkGray
            return
        }

        $lines = $result.Output -split "`r?`n"
        $headerIndex = -1

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*Name\s+Address\s+Paired\s+Connected\s*$') {
                $headerIndex = $i
                break
            }
        }

        Assert-True ($headerIndex -ge 0) 'Paired-device table header not found.'

        $dataStart = $headerIndex + 1
        if ($dataStart -lt $lines.Count -and $lines[$dataStart] -match '^\s*-+') {
            $dataStart++
        }

        $rows = @()
        $badRows = @()

        for ($i = $dataStart; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]

            if ([string]::IsNullOrWhiteSpace($line)) { break }

            if ($line -match '^\s*(?<Name>.+?)\s+(?<Address>[0-9A-Fa-f]{12}|\?)\s+(?<Paired>True|False)\s+(?<Connected>True|False|\?)\s*$') {
                $rows += [pscustomobject]@{
                    Name      = $Matches['Name'].Trim()
                    Address   = $Matches['Address']
                    Paired    = $Matches['Paired']
                    Connected = $Matches['Connected']
                }
            }
            else {
                $badRows += $line
            }
        }

        Assert-True ($rows.Count -gt 0) 'No paired-device rows were parsed.'
        Assert-Equal 0 $badRows.Count "Unrecognized paired-device rows: $($badRows -join '; ')"

        foreach ($row in $rows) {
            Assert-True (
                $row.Address -eq '?' -or
                $row.Address -match '^[0-9A-Fa-f]{12}$'
            ) "Invalid address for '$($row.Name)': $($row.Address)"

            Assert-Equal 'True' $row.Paired "Device '$($row.Name)' is not marked as paired."
            Assert-True ($row.Connected -in @('True', 'False', '?')) `
                "Invalid connection state for '$($row.Name)': $($row.Connected)"
        }

        Write-Host ("  Validated {0} paired-device row(s)." -f $rows.Count) -ForegroundColor DarkGray
    }



    Test-Case '-Mode scan runs a live Bluetooth discovery session' {
        $result = Invoke-Main -MainArgs @('-Mode', 'scan', '-ScanSeconds', '3')

        Assert-Equal 0 $result.ExitCode (
            "Unexpected exit code: $($result.ExitCode). Output: $($result.Output)"
        )
        Assert-False ($result.Output -match '(?m)^ERROR:') "Script errored: $($result.Output)"
        Assert-True ($result.Output -match 'Live Bluetooth scan \(3 seconds\)') `
            'Did not reach the live Bluetooth scan section.'

        $hasEmpty = $result.Output -match 'No devices in range'
        $hasTable = $result.Output -match '(?m)^\s*Name\s+Address\s+InRange\s+Paired\s+Connected\s*$'

        Assert-True ($hasEmpty -or $hasTable) "Unexpected scan output: $($result.Output)"

        if ($hasEmpty) {
            Write-Host '  (no nearby devices discovered; valid scan result)' -ForegroundColor DarkGray
            return
        }

        $lines = $result.Output -split "`r?`n"
        $headerIndex = -1

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*Name\s+Address\s+InRange\s+Paired\s+Connected\s*$') {
                $headerIndex = $i
                break
            }
        }

        Assert-True ($headerIndex -ge 0) 'Live-scan table header not found.'

        $dataStart = $headerIndex + 1
        if ($dataStart -lt $lines.Count -and $lines[$dataStart] -match '^\s*-+') {
            $dataStart++
        }

        $rows = @()
        $badRows = @()

        for ($i = $dataStart; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { break }

            if ($line -match '^\s*(?<Name>.+?)\s+(?<Address>[0-9A-Fa-f]{12}|\?)\s+(?<InRange>True|False)\s+(?<Paired>True|False)\s+(?<Connected>True|False)\s*$') {
                $rows += [pscustomobject]@{
                    Name      = $Matches['Name'].Trim()
                    Address   = $Matches['Address']
                    InRange   = $Matches['InRange']
                    Paired    = $Matches['Paired']
                    Connected = $Matches['Connected']
                }
            }
            else {
                $badRows += $line
            }
        }

        Assert-True ($rows.Count -gt 0) 'Scan table was displayed but no device rows were parsed.'
        Assert-Equal 0 $badRows.Count "Unrecognized scan rows: $($badRows -join '; ')"

        foreach ($row in $rows) {
            Assert-True (
                $row.Address -eq '?' -or
                $row.Address -match '^[0-9A-Fa-f]{12}$'
            ) "Invalid scan address for '$($row.Name)': $($row.Address)"

            Assert-Equal 'True' $row.InRange "Discovered device '$($row.Name)' is not marked in range."
            Assert-True ($row.Paired -in @('True', 'False')) "Invalid paired state for '$($row.Name)'."
            Assert-True ($row.Connected -in @('True', 'False')) "Invalid connection state for '$($row.Name)'."
        }

        Write-Host ("  Validated {0} discovered-device row(s)." -f $rows.Count) -ForegroundColor DarkGray
    }

    Test-Case '-Mode blescan starts the Windows BLE watcher' {
        $result = Invoke-Main -MainArgs @('-Mode', 'blescan', '-ScanSeconds', '3')
        Assert-Equal 0 $result.ExitCode ("Unexpected exit code: $($result.ExitCode). Output: $($result.Output)")
        Assert-False ($result.Output -match '(?m)^ERROR:') "BLE scan errored: $($result.Output)"
        Assert-True ($result.Output -match 'Bluetooth LE scan \(3 seconds\)') 'BLE scan section was not reached.'
        Assert-True (
            $result.Output -match 'No BLE advertisements received|Name\s+Address\s+RSSI\s+EstimatedDistance\s+Samples'
        ) "BLE scan did not produce a recognized result: $($result.Output)"
    }
}

}
else {
    Skip-Case 'Bluetooth hardware smoke tests' 'use -IncludeHardware to run them'
}

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
Write-Host ("Passed : {0}" -f $script:Passed) -ForegroundColor Green

if ($script:Skipped -gt 0) {
    Write-Host ("Skipped: {0}" -f $script:Skipped) -ForegroundColor DarkYellow
}
if ($script:Failed -gt 0) {
    Write-Host ("Failed : {0}" -f $script:Failed) -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host ("  - {0}" -f $failure) -ForegroundColor Red
    }
    exit 1
}

Write-Host 'All executed tests passed.' -ForegroundColor Green
exit 0
