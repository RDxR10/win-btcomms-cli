# Win BTComms CLI

A lightweight, dependency-free Windows CLI tool for Bluetooth file transfer, with basic chat support.

## Usage

```powershell
powershell -ep bypass -f .\win_btcomms.ps1 -Mode <paired|scan|send|receive|chathost|chatjoin> [options]
```

### List paired devices

```powershell
powershell -ep bypass -f .\win_btcomms.ps1 -Mode paired
```

### Live scan for nearby devices

```powershell
powershell -ep bypass -f .\win_btcomms.ps1 -Mode scan
powershell -ep bypass -f .\win_btcomms.ps1 -Mode scan -ScanSeconds 30
powershell -ep bypass -f .\win_btcomms.ps1 -Mode scan -ScanSeconds 30 -ShowAll
```

### Scan for Bluetooth Low Energy (BLE) advertisements

```powershell
powershell -ep bypass -f .\win_btcomms.ps1 -Mode blescan
powershell -ep bypass -f .\win_btcomms.ps1 -Mode blescan -ScanSeconds 30
```

### Send a file

```powershell
powershell -ep bypass -f .\win_btcomms.ps1 -Mode send -FilePath "D:\file.pdf" -DeviceName "MyDevice"
powershell -ep bypass -f .\win_btcomms.ps1 -Mode send -FilePath "D:\file.pdf" -DeviceAddress <HH:HH:HH:HH:HH:HH | HHHHHHHHHHHH>
```

### Receive files

```powershell
powershell -ep bypass -f .\win_btcomms.ps1 -Mode receive
powershell -ep bypass -f .\win_btcomms.ps1 -Mode receive -SaveDir "D:\Incoming"
powershell -ep bypass -f .\win_btcomms.ps1 -Mode receive -SaveDir "D:\Incoming" -Continuous
powershell -ep bypass -f .\win_btcomms.ps1 -Mode receive -Discoverable
```

### Host a chat

```powershell
powershell -ep bypass -f .\win_btcomms.ps1 -Mode chathost
powershell -ep bypass -f .\win_btcomms.ps1 -Mode chathost -Nickname "Alice"
powershell -ep bypass -f .\win_btcomms.ps1 -Mode chathost -Nickname "Alice" -Discoverable
```

### Join a chat

```powershell
powershell -ep bypass -f .\win_btcomms.ps1 -Mode chatjoin -DeviceName "MyDevice"
powershell -ep bypass -f .\win_btcomms.ps1 -Mode chatjoin -DeviceName "MyDevice" -Nickname "Bob"
powershell -ep bypass -f .\win_btcomms.ps1 -Mode chatjoin -DeviceAddress <HH:HH:HH:HH:HH:HH | HHHHHHHHHHHH> -Nickname "Bob"
```
