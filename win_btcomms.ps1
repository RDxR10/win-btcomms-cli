[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('paired', 'scan', 'send', 'receive', 'chathost', 'chatjoin')]
    [string]$Mode = 'paired',

    [Parameter()]
    [string]$FilePath,

    # 12 hex digits, with or without separators (AABBCCDDEEFF / AA:BB:CC:DD:EE:FF)
    [Parameter()]
    [string]$DeviceAddress,

    # Alternative to DeviceAddress: part of the paired device's name
    [Parameter()]
    [string]$DeviceName,

    # Receive mode: folder where incoming files are saved (default: your Downloads folder)
    [Parameter()]
    [string]$SaveDir,

    # Receive mode: keep listening for more files instead of stopping after the first one
    [Parameter()]
    [switch]$Continuous,

    # Receive / chathost mode: advertise this PC as discoverable while listening
    [Parameter()]
    [switch]$Discoverable,

    # Scan mode: how long to listen for devices
    [Parameter()]
    [int]$ScanSeconds = 15,

    # Scan mode: also list remembered devices that are not currently in range
    [Parameter()]
    [switch]$ShowAll,

    # Chat modes: name shown to the other side
    [Parameter()]
    [string]$Nickname = $env:COMPUTERNAME
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Message)
    Write-Host ''
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Initialize-WinRT {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        throw 'Run it with powershell.exe'
    }

    Add-Type -AssemblyName System.Runtime.WindowsRuntime

    $null = [Windows.Devices.Bluetooth.BluetoothDevice,                 Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothCacheMode,              Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.Rfcomm.RfcommServiceId,          Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.Rfcomm.RfcommServiceProvider,    Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceServicesResult, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformation,             Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationCollection,   Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationKind,         Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationUpdate,       Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceWatcher,                 Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $null = [Windows.Networking.Sockets.StreamSocket,                   Windows.Networking, ContentType = WindowsRuntime]
    $null = [Windows.Networking.Sockets.StreamSocketListener,           Windows.Networking, ContentType = WindowsRuntime]
    $null = [Windows.Networking.Sockets.SocketProtectionLevel,          Windows.Networking, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.DataReader,                        Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.DataWriter,                        Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IInputStream,                      Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IOutputStream,                     Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Foundation.IAsyncAction,                           Windows.Foundation, ContentType = WindowsRuntime]

    $ext = [System.WindowsRuntimeSystemExtensions]
    $script:AsTaskOp = $ext.GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1

    $script:AsTaskAction = $ext.GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
    } | Select-Object -First 1

    if ($null -eq $script:AsTaskOp -or $null -eq $script:AsTaskAction) {
        throw 'Could not set up Windows Runtime async helpers on this system.'
    }

    # Register-ObjectEvent refuses Windows Runtime events, so a tiny helper class (compiled
    # from C# source by Add-Type, no external files) subscribes instead and queues the
    # event arguments for the script to pick up.
    if (-not ('WinRtEventQueue' -as [type])) {
        $source = @'
using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Linq.Expressions;
using System.Reflection;
using System.Runtime.InteropServices.WindowsRuntime;

public class WinRtEventQueue
{
    private readonly BlockingCollection<object> queue = new BlockingCollection<object>();

    public void OnEvent(object sender, object args)
    {
        queue.Add(args);
    }

    // Reads one entry from a DeviceInformation / DeviceInformationUpdate "Properties" map.
    
    public static object GetProperty(object info, string key)
    {
        if (info == null) { return null; }
        PropertyInfo pi = info.GetType().GetProperty("Properties");
        if (pi == null) { return null; }
        var map = pi.GetValue(info, null) as System.Collections.Generic.IReadOnlyDictionary<string, object>;
        object value;
        if (map != null && map.TryGetValue(key, out value)) { return value; }
        return null;
    }

    // Returns the next event's arguments, or null if none arrived within the timeout.
    public object Take(int timeoutMs)
    {
        object item;
        if (queue.TryTake(out item, timeoutMs)) { return item; }
        return null;
    }

    public void Subscribe(object target, string eventName)
    {
        EventInfo evt = target.GetType().GetEvent(eventName);
        if (evt == null) { throw new InvalidOperationException("Event not found: " + eventName); }

        Type handlerType = evt.EventHandlerType;
        MethodInfo invoke = handlerType.GetMethod("Invoke");
        ParameterExpression[] ps = invoke.GetParameters()
            .Select(p => Expression.Parameter(p.ParameterType, p.Name)).ToArray();

        MethodCallExpression call = Expression.Call(
            Expression.Constant(this),
            typeof(WinRtEventQueue).GetMethod("OnEvent"),
            Expression.Convert(ps[0], typeof(object)),
            Expression.Convert(ps[1], typeof(object)));

        Delegate handler = Expression.Lambda(handlerType, call, ps).Compile();

        Type tokenType = typeof(EventRegistrationToken);
        MethodInfo add = evt.GetAddMethod();
        MethodInfo remove = evt.GetRemoveMethod();

        Delegate addDelegate = Delegate.CreateDelegate(
            typeof(Func<,>).MakeGenericType(handlerType, tokenType), target, add);
        Delegate removeDelegate = Delegate.CreateDelegate(
            typeof(Action<>).MakeGenericType(tokenType), target, remove);

        MethodInfo addHandler = typeof(WindowsRuntimeMarshal)
            .GetMethod("AddEventHandler")
            .MakeGenericMethod(handlerType);
        addHandler.Invoke(null, new object[] { addDelegate, removeDelegate, handler });
    }
}
'@
        Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Core'
    }
}

function Wait-Task {
    param($Task)
    try { $Task.Wait() }
    catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        throw $e.Message
    }
}

# Await an IAsyncOperation<T>; $Type is T
function Await-Op {
    param($Op, [Type]$Type)
    $task = $script:AsTaskOp.MakeGenericMethod($Type).Invoke($null, @($Op))
    Wait-Task $task
    return $task.Result
}

# Await an IAsyncAction (no result)
function Await-Action {
    param($Op)
    $task = $script:AsTaskAction.Invoke($null, @($Op))
    Wait-Task $task
}

# ---------------------------------------------------------------------------
# Device discovery
# ---------------------------------------------------------------------------

function Get-BtDeviceInfos {
    param([bool]$Paired)
    $selector = [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromPairingState($Paired)
    $col = Await-Op ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
    return @($col)
}

function Show-Devices {
    Write-Section 'Paired Bluetooth devices (Windows device list, not a live scan)'

    $infos = @(Get-BtDeviceInfos -Paired $true)

    $seen = @{}
    $rows = @()
    foreach ($info in $infos) {
        if ($seen.ContainsKey($info.Id)) { continue }
        $seen[$info.Id] = $true

        $addr = '?'
        $conn = '?'
        try {
            $d = Await-Op ([Windows.Devices.Bluetooth.BluetoothDevice]::FromIdAsync($info.Id)) ([Windows.Devices.Bluetooth.BluetoothDevice])
            if ($null -ne $d) {
                $addr = '{0:X12}' -f $d.BluetoothAddress
                $conn = ($d.ConnectionStatus.ToString() -eq 'Connected')
                $d.Dispose()
            }
        }
        catch { }

        $rows += [pscustomobject]@{
            Name      = $info.Name
            Address   = $addr
            Paired    = $true
            Connected = $conn
        }
    }

    if ($rows.Count -eq 0) {
        Write-Host 'No paired devices found. Pair the device in Windows Settings first.'
        return
    }
    $rows | Sort-Object Name | Format-Table -AutoSize
}

function Get-AddressFromId {
    # Classic Bluetooth device ids end with the MAC address, e.g. "...-ac:c0:48:20:b6:2c"
    param([string]$Id)
    if ($Id -match '([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\s*$') {
        return ($Matches[1] -replace ':', '').ToUpperInvariant()
    }
    return '?'
}

function Show-LiveScan {
    Write-Section "Live Bluetooth scan ($ScanSeconds seconds)"

    # Addresses of devices Windows has paired, used to fill in the Paired column reliably
    $pairedAddr = @{}
    foreach ($p in (Get-BtDeviceInfos -Paired $true)) {
        $a = Get-AddressFromId $p.Id
        if ($a -ne '?') { $pairedAddr[$a] = $true }
    }

    $kProps = @('System.Devices.Aep.IsPresent', 'System.Devices.Aep.IsPaired', 'System.Devices.Aep.IsConnected')
    $aqs = '(System.Devices.Aep.ProtocolId:="{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}")'   # classic Bluetooth

    $watcher = [Windows.Devices.Enumeration.DeviceInformation]::CreateWatcher(
        $aqs, [string[]]$kProps, [Windows.Devices.Enumeration.DeviceInformationKind]::AssociationEndpoint)

    $addedQ   = New-Object WinRtEventQueue
    $updatedQ = New-Object WinRtEventQueue
    $addedQ.Subscribe($watcher, 'Added')
    $updatedQ.Subscribe($watcher, 'Updated')

    $devices = @{}

    function Set-ScanState($id, $source, $name) {
        if (-not $devices.ContainsKey($id)) {
            $devices[$id] = [pscustomobject]@{ Id = $id; Name = $name; Present = $null; Paired = $null; Connected = $null }
        }
        $d = $devices[$id]
        if ($name) { $d.Name = $name }
        $v = [WinRtEventQueue]::GetProperty($source, 'System.Devices.Aep.IsPresent');   if ($null -ne $v) { $d.Present = [bool]$v }
        $v = [WinRtEventQueue]::GetProperty($source, 'System.Devices.Aep.IsPaired');    if ($null -ne $v) { $d.Paired = [bool]$v }
        $v = [WinRtEventQueue]::GetProperty($source, 'System.Devices.Aep.IsConnected'); if ($null -ne $v) { $d.Connected = [bool]$v }
    }

    try {
        $watcher.Start()
        $end = (Get-Date).AddSeconds($ScanSeconds)
        while ((Get-Date) -lt $end) {
            $left = [int]($end - (Get-Date)).TotalSeconds
            Write-Progress -Activity 'Scanning for Bluetooth devices' -Status "$left s left - found $($devices.Count)" -PercentComplete ([int](100 * (1 - $left / [double]$ScanSeconds)))

            $a = $addedQ.Take(150)
            if ($null -ne $a) { Set-ScanState $a.Id $a $a.Name }

            $u = $updatedQ.Take(150)
            if ($null -ne $u) { Set-ScanState $u.Id $u $null }
        }
    }
    finally {
        Write-Progress -Activity 'Scanning for Bluetooth devices' -Completed
        try { $watcher.Stop() } catch { }
    }

    $rows = @()
    foreach ($d in $devices.Values) {
        $addr = Get-AddressFromId $d.Id
        $inRange = ($d.Present -ne $false)            # unknown counts as in range
        if (-not $inRange -and -not $ShowAll) { continue }

        $isPaired = ($d.Paired -eq $true) -or ($addr -ne '?' -and $pairedAddr.ContainsKey($addr))
        $rows += [pscustomobject]@{
            Name      = $d.Name
            Address   = $addr
            InRange   = $inRange
            Paired    = $isPaired
            Connected = ($d.Connected -eq $true)
        }
    }

    if ($rows.Count -eq 0) {
        Write-Host 'No devices in range. Make sure Bluetooth is on and the target is discoverable (check Bluetooth settings screen).'
        if (-not $ShowAll) { Write-Host 'Use -ShowAll to include remembered devices that are not currently in range.' }
        return
    }
    $rows | Sort-Object @{Expression = 'InRange'; Descending = $true}, Name | Format-Table -AutoSize
    
}

function ConvertTo-CleanAddress {
    param([string]$Address)
    $clean = ($Address -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($clean.Length -ne 12) { throw "Invalid Bluetooth address '$Address'. Expected 12 hex digits." }
    return $clean
}

function Get-TargetDevice {
    if (-not [string]::IsNullOrWhiteSpace($DeviceAddress)) {
        $clean = ConvertTo-CleanAddress $DeviceAddress
        $value = [Convert]::ToUInt64($clean, 16)
        $dev = Await-Op ([Windows.Devices.Bluetooth.BluetoothDevice]::FromBluetoothAddressAsync($value)) ([Windows.Devices.Bluetooth.BluetoothDevice])
        if ($null -eq $dev) { throw "No Bluetooth device found with address $clean." }
        return $dev
    }

    if (-not [string]::IsNullOrWhiteSpace($DeviceName)) {
        $found = @(Get-BtDeviceInfos -Paired $true | Where-Object { $_.Name -like "*$DeviceName*" })
        if ($found.Count -eq 0) { throw "No paired device matching name '$DeviceName'. Run -Mode paired to list devices." }
        if ($found.Count -gt 1) {
            $names = ($found | ForEach-Object { $_.Name }) -join '; '
            throw "More than one device matches '$DeviceName': $names. Use -DeviceAddress instead."
        }
        $dev = Await-Op ([Windows.Devices.Bluetooth.BluetoothDevice]::FromIdAsync($found[0].Id)) ([Windows.Devices.Bluetooth.BluetoothDevice])
        if ($null -eq $dev) { throw "Could not open device '$($found[0].Name)'." }
        return $dev
    }

    throw 'Specify -DeviceAddress or -DeviceName for send / chatjoin mode.'
}

# ---------------------------------------------------------------------------
# OBEX packet helpers
# ---------------------------------------------------------------------------

function Get-NetStreams {
    param($Socket)
    $ext = [System.IO.WindowsRuntimeStreamExtensions]
    $asRead  = $ext.GetMethod('AsStreamForRead',  [Type[]]@([Windows.Storage.Streams.IInputStream]))
    $asWrite = $ext.GetMethod('AsStreamForWrite', [Type[]]@([Windows.Storage.Streams.IOutputStream]))
    if ($null -eq $asRead -or $null -eq $asWrite) { throw 'Could not find the stream conversion helpers on this system.' }

    $in  = $asRead.Invoke($null,  @($Socket.InputStream))
    $out = $asWrite.Invoke($null, @($Socket.OutputStream))
    return [pscustomobject]@{ In = $in; Out = $out }
}

function Read-Exact {
    param([System.IO.Stream]$Reader, [int]$Count)
    if ($Count -le 0) { return ,(New-Object byte[] 0) }
    $buf = New-Object byte[] $Count
    $off = 0
    while ($off -lt $Count) {
        $n = $Reader.Read($buf, $off, $Count - $off)
        if ($n -le 0) { throw 'Connection closed by the remote device.' }
        $off += $n
    }
    return ,$buf
}

function Read-ObexPacket {
    param($Reader)
    $head = Read-Exact $Reader 3
    $len = ([int]$head[1] -shl 8) -bor [int]$head[2]
    if ($len -lt 3) { throw "Malformed OBEX packet (length $len)." }
    $payload = Read-Exact $Reader ($len - 3)
    return [pscustomobject]@{ Opcode = [int]$head[0]; Payload = $payload }
}

function Send-ObexPacket {
    param([System.IO.Stream]$Writer, [byte[]]$Bytes)
    $Writer.Write($Bytes, 0, $Bytes.Length)
    $Writer.Flush()
}

function New-ObexPacket {
    # Builds [opcode][len hi][len lo][body...]
    param([byte]$Opcode, [byte[]]$Body)
    $total = 3 + $Body.Length
    $list = New-Object System.Collections.Generic.List[byte]
    $list.Add($Opcode)
    $list.Add([byte]($total -shr 8))
    $list.Add([byte]($total -band 0xFF))
    if ($Body.Length -gt 0) { $list.AddRange($Body) }
    return ,$list.ToArray()
}

function New-NameHeader {
    param([string]$Name)
    $bytes = [System.Text.Encoding]::BigEndianUnicode.GetBytes($Name + [string][char]0)
    $len = $bytes.Length + 3
    $list = New-Object System.Collections.Generic.List[byte]
    $list.Add(0x01)
    $list.Add([byte]($len -shr 8))
    $list.Add([byte]($len -band 0xFF))
    $list.AddRange($bytes)
    return ,$list.ToArray()
}

function Read-ObexHeaders {
    param([byte[]]$Data)
    $headers = @()
    $i = 0
    while ($i -lt $Data.Length) {
        $id = [int]$Data[$i]
        $kind = $id -band 0xC0

        if ($kind -eq 0x00 -or $kind -eq 0x40) {
            if ($i + 3 -gt $Data.Length) { break }
            $l = ([int]$Data[$i + 1] -shl 8) -bor [int]$Data[$i + 2]
            if ($l -lt 3 -or $i + $l -gt $Data.Length) { break }
            $chunk = New-Object byte[] ($l - 3)
            [Array]::Copy($Data, $i + 3, $chunk, 0, $l - 3)
            $i += $l
        }
        elseif ($kind -eq 0x80) {
            if ($i + 2 -gt $Data.Length) { break }
            $chunk = [byte[]]@($Data[$i + 1])
            $i += 2
        }
        else {
            if ($i + 5 -gt $Data.Length) { break }
            $chunk = New-Object byte[] 4
            [Array]::Copy($Data, $i + 1, $chunk, 0, 4)
            $i += 5
        }
        $headers += [pscustomobject]@{ Id = $id; Data = $chunk }
    }
    return $headers
}

# ---------------------------------------------------------------------------
# SEND
# ---------------------------------------------------------------------------

function Send-BluetoothFile {
    if ([string]::IsNullOrWhiteSpace($FilePath)) { throw 'Specify -FilePath for send mode.' }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "File not found: $FilePath" }

    $file = (Resolve-Path -LiteralPath $FilePath).Path
    $name = [IO.Path]::GetFileName($file)
    $size = (Get-Item -LiteralPath $file).Length
    if ($size -gt [uint32]::MaxValue) { throw 'File is larger than 4 GB, which OBEX cannot describe in one header.' }

    $dev = Get-TargetDevice
    $socket = $null
    $fs = $null
    try {
        Write-Section 'Sending file over Bluetooth (OBEX Object Push)'
        Write-Host "File:   $file ($size bytes)"
        Write-Host ("Target: {0} [{1:X12}]" -f $dev.Name, $dev.BluetoothAddress)

        $sid = [Windows.Devices.Bluetooth.Rfcomm.RfcommServiceId]::ObexObjectPush
        $res = Await-Op ($dev.GetRfcommServicesForIdAsync($sid, [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) ([Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceServicesResult])
        if ($res.Error.ToString() -ne 'Success') { throw "Could not query the device's services: $($res.Error)" }
        # An empty WinRT list shows up as $null in PowerShell, so wrap it in @() before counting
        $services = @($res.Services)

        if ($services.Count -eq 0) {
            Write-Host 'Object Push service not found. Listing every RFCOMM service the device reports...' -ForegroundColor Yellow
            try {
                $all = Await-Op ($dev.GetRfcommServicesAsync([Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) ([Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceServicesResult])
                $allServices = @($all.Services)
                if ($allServices.Count -eq 0) {
                    Write-Host '  (none reported)'
                }
                foreach ($s in $allServices) {
                    Write-Host ("  - {0}" -f $s.ServiceId.AsString())
                }
            }
            catch {
                Write-Host "  Could not list services: $($_.Exception.Message)"
            }
            throw 'The device does not offer an Object Push service to this script. Make sure the device is paired, unlocked, Bluetooth is on, and try again'
        }
        $svc = $services[0]

        Write-Host 'Connecting...'
        $socket = New-Object Windows.Networking.Sockets.StreamSocket
        Await-Action ($socket.ConnectAsync($svc.ConnectionHostName, $svc.ConnectionServiceName))

        $streams = Get-NetStreams $socket
        $writer = $streams.Out
        $reader = $streams.In

        # OBEX CONNECT: version 1.0, flags 0, max packet 0x2000
        Send-ObexPacket $writer (New-ObexPacket 0x80 ([byte[]]@(0x10, 0x00, 0x20, 0x00)))
        $resp = Read-ObexPacket $reader
        if ($resp.Opcode -ne 0xA0) { throw ("OBEX connect refused (0x{0:X2})." -f $resp.Opcode) }

        $serverMax = 8192
        if ($resp.Payload.Length -ge 4) {
            $serverMax = ([int]$resp.Payload[2] -shl 8) -bor [int]$resp.Payload[3]
        }
        $maxPkt = [Math]::Min($serverMax, 8192)
        if ($maxPkt -lt 255) { throw "Receiver's packet size ($serverMax) is too small." }

        $nameHdr = New-NameHeader $name
        $fs = [IO.File]::OpenRead($file)
        $first = $true
        $sent = 0L
        Write-Host 'Waiting for the receiving device to accept...'

        do {
            $room = $maxPkt - 3 - 3          # packet header + body header
            if ($first) { $room -= ($nameHdr.Length + 5) }
            if ($room -lt 1) { throw 'Filename is too long for the receiver''s packet size.' }

            $buf = New-Object byte[] $room
            $n = $fs.Read($buf, 0, $room)
            $data = New-Object byte[] $n
            [Array]::Copy($buf, $data, $n)
            $isLast = ($fs.Position -ge $fs.Length)

            $body = New-Object System.Collections.Generic.List[byte]
            if ($first) {
                $body.AddRange($nameHdr)
                $body.Add(0xC3)                                  # Length header (4 bytes)
                $body.Add([byte](($size -shr 24) -band 0xFF))
                $body.Add([byte](($size -shr 16) -band 0xFF))
                $body.Add([byte](($size -shr 8) -band 0xFF))
                $body.Add([byte]($size -band 0xFF))
            }
            $bodyLen = $n + 3
            if ($isLast) { $body.Add(0x49) } else { $body.Add(0x48) }   # End-of-Body / Body
            $body.Add([byte]($bodyLen -shr 8))
            $body.Add([byte]($bodyLen -band 0xFF))
            if ($n -gt 0) { $body.AddRange($data) }

            if ($isLast) { $op = [byte]0x82 } else { $op = [byte]0x02 }
            Send-ObexPacket $writer (New-ObexPacket $op $body.ToArray())

            $resp = Read-ObexPacket $reader
            if ($isLast) { $expected = 0xA0 } else { $expected = 0x90 }
            if ($resp.Opcode -ne $expected) {
                throw ("Receiver rejected the transfer (response 0x{0:X2}). It may have been declined on the other device." -f $resp.Opcode)
            }

            $first = $false
            $sent += $n
            if ($size -gt 0) {
                Write-Progress -Activity 'Sending over Bluetooth' -Status "$sent / $size bytes" -PercentComplete ([int](100 * $sent / $size))
            }
        } while (-not $isLast)

        Write-Progress -Activity 'Sending over Bluetooth' -Completed

        # OBEX DISCONNECT (best effort)
        try {
            Send-ObexPacket $writer (New-ObexPacket 0x81 (New-Object byte[] 0))
            $null = Read-ObexPacket $reader
        }
        catch { }

        Write-Host "File sent ($sent bytes)." -ForegroundColor Green
    }
    finally {
        if ($null -ne $fs)     { $fs.Dispose() }
        if ($null -ne $socket) { $socket.Dispose() }
        if ($null -ne $dev)    { $dev.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# RECEIVE
# ---------------------------------------------------------------------------

function Get-UniquePath {
    param([string]$Directory, [string]$FileName)

    $safe = [IO.Path]::GetFileName($FileName)
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $safe = $safe.Replace([string]$c, '_') }
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'bluetooth_file_' + (Get-Date -Format 'yyyyMMdd_HHmmss') }

    $target = Join-Path $Directory $safe
    $base = [IO.Path]::GetFileNameWithoutExtension($safe)
    $ext  = [IO.Path]::GetExtension($safe)
    $i = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $Directory ("{0} ({1}){2}" -f $base, $i, $ext)
        $i++
    }
    return $target
}

# Handles one connected sender. Returns the number of files saved.
function Invoke-ObexServerSession {
    param($Socket, [string]$Directory)

    $streams = Get-NetStreams $Socket
    $reader = $streams.In
    $writer = $streams.Out

    $saved = 0
    $stream = $null
    $tmp = $null
    $name = $null
    $received = 0L
    $done = $false

    try {
        while (-not $done) {
            $pkt = Read-ObexPacket $reader
            $op = $pkt.Opcode

            if ($op -eq 0x80) {
                # CONNECT -> accept, max packet 0x2000
                Send-ObexPacket $writer ([byte[]]@(0xA0, 0x00, 0x07, 0x10, 0x00, 0x20, 0x00))
            }
            elseif ($op -eq 0x02 -or $op -eq 0x82) {
                $isFinal = (($op -band 0x80) -ne 0)

                foreach ($h in (Read-ObexHeaders $pkt.Payload)) {
                    if ($h.Id -eq 0x01) {
                        $name = [System.Text.Encoding]::BigEndianUnicode.GetString($h.Data).TrimEnd([char]0)
                    }
                    elseif ($h.Id -eq 0x48 -or $h.Id -eq 0x49) {
                        if ($null -eq $stream) {
                            $tmp = Join-Path $Directory ('.bt_incoming_' + [guid]::NewGuid().ToString('N') + '.part')
                            $stream = [IO.File]::Create($tmp)
                            if ($name) { Write-Host "Incoming file: $name" }
                        }
                        if ($h.Data.Length -gt 0) {
                            $stream.Write($h.Data, 0, $h.Data.Length)
                            $received += $h.Data.Length
                        }
                    }
                }

                if ($isFinal) {
                    if ($null -eq $stream) {
                        $tmp = Join-Path $Directory ('.bt_incoming_' + [guid]::NewGuid().ToString('N') + '.part')
                        $stream = [IO.File]::Create($tmp)
                    }
                    $stream.Dispose()
                    $stream = $null

                    $dest = Get-UniquePath -Directory $Directory -FileName $name
                    Move-Item -LiteralPath $tmp -Destination $dest
                    $tmp = $null

                    if ($received -eq 0) {
                        Write-Host "WARNING: empty file saved: $dest" -ForegroundColor Yellow
                    }
                    else {
                        Write-Host "Received $received bytes: $dest" -ForegroundColor Green
                    }
                    $saved++
                    $name = $null
                    $received = 0L
                    Send-ObexPacket $writer ([byte[]]@(0xA0, 0x00, 0x03))
                }
                else {
                    Send-ObexPacket $writer ([byte[]]@(0x90, 0x00, 0x03))   # Continue
                }
            }
            elseif ($op -eq 0x81) {
                Send-ObexPacket $writer ([byte[]]@(0xA0, 0x00, 0x03))
                $done = $true
            }
            elseif ($op -eq 0xFF) {
                Send-ObexPacket $writer ([byte[]]@(0xA0, 0x00, 0x03))
                Write-Host 'Sender aborted the transfer.' -ForegroundColor Yellow
                $done = $true
            }
            else {
                Send-ObexPacket $writer ([byte[]]@(0xD1, 0x00, 0x03))      # Not implemented
            }
        }
    }
    catch {
        if ($null -ne $tmp) {
            Write-Host "Transfer interrupted: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        elseif ($saved -eq 0) {
            Write-Host "Session ended: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        $Socket.Dispose()
    }
    return $saved
}

function Receive-BluetoothFile {
    $dir = $SaveDir
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = 'D:\Users\User\Downloads' }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $dir = (Resolve-Path -LiteralPath $dir).Path

    Write-Section 'Bluetooth receive (OBEX Object Push server)'
    Write-Host "Saving to: $dir"

    $sid = [Windows.Devices.Bluetooth.Rfcomm.RfcommServiceId]::ObexObjectPush
    $provider = Await-Op ([Windows.Devices.Bluetooth.Rfcomm.RfcommServiceProvider]::CreateAsync($sid)) ([Windows.Devices.Bluetooth.Rfcomm.RfcommServiceProvider])

    $listener = New-Object Windows.Networking.Sockets.StreamSocketListener
    $queue = New-Object WinRtEventQueue
    $advertising = $false

    try {
        $queue.Subscribe($listener, 'ConnectionReceived')

        Await-Action ($listener.BindServiceNameAsync(
            $provider.ServiceId.AsString(),
            [Windows.Networking.Sockets.SocketProtectionLevel]::BluetoothEncryptionAllowNullAuthentication))

        # SDP attributes that phones look for on an Object Push server
        try {
            $bufExt = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]

            $formats = [byte[]]@(0x35, 0x02, 0x08, 0xFF)                  # Supported Formats: any
            $null = [Windows.Storage.Streams.IBuffer, Windows.Storage.Streams, ContentType = WindowsRuntime]
            $dictType = [System.Collections.Generic.IDictionary`2].MakeGenericType([uint32], [Windows.Storage.Streams.IBuffer])
            $setItem = $dictType.GetProperty('Item')
            $attrs = $provider.SdpRawAttributes

            $svcName = [System.Text.Encoding]::ASCII.GetBytes('OBEX Object Push')
            $nameAttr = [byte[]](@(0x25, [byte]$svcName.Length) + $svcName)      # Service Name

            $setItem.SetValue($attrs, $bufExt::AsBuffer($formats), [object[]]@([uint32]0x0303))
            $setItem.SetValue($attrs, $bufExt::AsBuffer($nameAttr), [object[]]@([uint32]0x0100))
        }
        catch {
            Write-Warning "Could not set SDP attributes: $($_.Exception.Message)"
        }

        $provider.StartAdvertising($listener, [bool]$Discoverable)
        $advertising = $true

        Write-Host 'Listening. Send a file from the other device now... (Ctrl+C to stop)'
        if (-not $Discoverable) {
            Write-Host 'Tip: the sender should already be paired with this PC (or use -Discoverable).'
        }

        $total = 0
        while ($true) {
            $evArgs = $null
            while ($null -eq $evArgs) { $evArgs = $queue.Take(500) }   # short wait keeps Ctrl+C responsive
            $socket = $evArgs.Socket

            Write-Host 'Device connected.'
            $total += [int](Invoke-ObexServerSession -Socket $socket -Directory $dir)

            if (-not $Continuous -and $total -gt 0) { break }
            Write-Host 'Waiting for the next connection...'
        }
    }
    finally {
        if ($advertising) { try { $provider.StopAdvertising() } catch { } }
        $listener.Dispose()
    }
}

# ---------------------------------------------------------------------------
# CHAT (real-time, line based, over an RFCOMM Serial Port connection)
# ---------------------------------------------------------------------------

# Runs an interactive chat on a connected socket. Messages are UTF-8 lines ending in \n.
function Start-ChatSession {
    param($Socket)

    $streams = Get-NetStreams $Socket
    $reader  = $streams.In
    $writer  = $streams.Out

    $enc     = New-Object System.Text.UTF8Encoding($false)
    $decoder = $enc.GetDecoder()          # handles multi-byte characters split across packets
    $buf     = New-Object byte[] 4096
    $pending = ''
    $line    = New-Object System.Text.StringBuilder
    $quit    = $false

    # Always one read in flight, so incoming messages show up the moment they arrive
    $readTask = $reader.ReadAsync($buf, 0, $buf.Length)

    Write-Host 'Connected. Type a message and press Enter. Type /quit to leave.' -ForegroundColor Green
    Write-Host '> ' -NoNewline

    try {
        while (-not $quit) {

            # ---- incoming data ----
            if ($readTask.IsCompleted) {
                if ($readTask.IsFaulted -or $readTask.IsCanceled) { throw 'Connection lost.' }
                $n = $readTask.Result
                if ($n -le 0) {
                    Write-Host ''
                    Write-Host 'The other side disconnected.' -ForegroundColor Yellow
                    break
                }

                $chars = New-Object char[] ($n + 4)
                $cnt = $decoder.GetChars($buf, 0, $n, $chars, 0)
                $pending += [string]::new($chars, 0, $cnt)
                $readTask = $reader.ReadAsync($buf, 0, $buf.Length)

                while (($idx = $pending.IndexOf("`n")) -ge 0) {
                    $msg = $pending.Substring(0, $idx).TrimEnd("`r")
                    $pending = $pending.Substring($idx + 1)
                    if ($msg.Length -eq 0) { continue }

                    # wipe the current input line, print the message, redraw the input line
                    $w = [Math]::Max(10, [Console]::WindowWidth - 1)
                    Write-Host ("`r" + (' ' * $w) + "`r") -NoNewline
                    Write-Host $msg -ForegroundColor Yellow
                    Write-Host ('> ' + $line.ToString()) -NoNewline
                }
            }

            # ---- keyboard ----
            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)

                if ($key.Key -eq 'Enter') {
                    $text = $line.ToString().Trim()
                    [void]$line.Clear()
                    Write-Host ''
                    if ($text -eq '/quit') { $quit = $true; break }
                    if ($text.Length -gt 0) {
                        $bytes = $enc.GetBytes("${Nickname}: $text`n")
                        $writer.Write($bytes, 0, $bytes.Length)
                        $writer.Flush()
                    }
                    Write-Host '> ' -NoNewline
                }
                elseif ($key.Key -eq 'Backspace') {
                    if ($line.Length -gt 0) {
                        [void]$line.Remove($line.Length - 1, 1)
                        Write-Host "`b `b" -NoNewline
                    }
                }
                elseif (-not [char]::IsControl($key.KeyChar)) {
                    [void]$line.Append($key.KeyChar)
                    Write-Host $key.KeyChar -NoNewline
                }
            }

            Start-Sleep -Milliseconds 10
        }
    }
    finally {
        $Socket.Dispose()
    }
}

# Wait for another device to connect, then chat.
function Start-ChatHost {
    Write-Section 'Bluetooth chat (host)'

    $sid = [Windows.Devices.Bluetooth.Rfcomm.RfcommServiceId]::SerialPort
    $provider = Await-Op ([Windows.Devices.Bluetooth.Rfcomm.RfcommServiceProvider]::CreateAsync($sid)) ([Windows.Devices.Bluetooth.Rfcomm.RfcommServiceProvider])

    $listener = New-Object Windows.Networking.Sockets.StreamSocketListener
    $queue = New-Object WinRtEventQueue
    $advertising = $false

    try {
        $queue.Subscribe($listener, 'ConnectionReceived')

        Await-Action ($listener.BindServiceNameAsync(
            $provider.ServiceId.AsString(),
            [Windows.Networking.Sockets.SocketProtectionLevel]::BluetoothEncryptionAllowNullAuthentication))

        $provider.StartAdvertising($listener, [bool]$Discoverable)
        $advertising = $true

        Write-Host "Nickname: $Nickname"
        Write-Host 'Waiting for someone to connect (Serial Port service)... Ctrl+C to cancel.'
        if (-not $Discoverable) {
            Write-Host 'Tip: the other device should already be paired with this PC (or use -Discoverable).'
        }

        $evArgs = $null
        while ($null -eq $evArgs) { $evArgs = $queue.Take(500) }

        Start-ChatSession -Socket $evArgs.Socket
    }
    finally {
        if ($advertising) { try { $provider.StopAdvertising() } catch { } }
        $listener.Dispose()
    }
}

# Connect to a paired device that is hosting a chat, then chat.
function Start-ChatJoin {
    $dev = Get-TargetDevice
    $socket = $null
    try {
        Write-Section 'Bluetooth chat (join)'
        Write-Host ("Target: {0} [{1:X12}]" -f $dev.Name, $dev.BluetoothAddress)
        Write-Host "Nickname: $Nickname"

        $sid = [Windows.Devices.Bluetooth.Rfcomm.RfcommServiceId]::SerialPort
        $res = Await-Op ($dev.GetRfcommServicesForIdAsync($sid, [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) ([Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceServicesResult])
        if ($res.Error.ToString() -ne 'Success') { throw "Could not query the device's services: $($res.Error)" }
        $services = @($res.Services)
        if ($services.Count -eq 0) {
            throw 'The device does not offer a Serial Port service. Start -Mode chathost on it first.'
        }
        $svc = $services[0]

        Write-Host 'Connecting...'
        $socket = New-Object Windows.Networking.Sockets.StreamSocket
        Await-Action ($socket.ConnectAsync($svc.ConnectionHostName, $svc.ConnectionServiceName))

        Start-ChatSession -Socket $socket
        $socket = $null          # session disposed it
    }
    finally {
        if ($null -ne $socket) { $socket.Dispose() }
        if ($null -ne $dev)    { $dev.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Host ''
    Write-Host 'Win BTComms CLI' -ForegroundColor Cyan
    Write-Host '---------------' -ForegroundColor DarkCyan

    Initialize-WinRT

    switch ($Mode) {
        'paired'   { Show-Devices }
        'scan'     { Show-LiveScan }
        'send'     { Send-BluetoothFile }
        'receive'  { Receive-BluetoothFile }
        'chathost' { Start-ChatHost }
        'chatjoin' { Start-ChatJoin }
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    #Write-Host "Type:  $($_.Exception.GetType().FullName)" -ForegroundColor DarkRed
    #if ($_.Exception.InnerException) {
    #    Write-Host "Inner: $($_.Exception.InnerException.Message)" -ForegroundColor DarkRed
    #}
    #Write-Host "At:    $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
    exit 1
}
