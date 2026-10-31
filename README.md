# Win BTshare CLI

## Usage

```powershell
powershell -ep bypass -f ./win_btshare.ps1 -Mode <paired|scan|send|receive> [options]
```

### List paired devices

```powershell
powershell -ep bypass -f ./win_btshare.ps1 -Mode paired
```

### Live scan for nearby devices

```powershell
powershell -ep bypass -f ./win_btshare.ps1 -Mode scan
powershell -ep bypass -f ./win_btshare.ps1 -Mode scan -ScanSeconds 30
powershell -ep bypass -f ./win_btshare.ps1 -Mode scan -ScanSeconds 30 -ShowAll
```

### Send a file

```powershell
powershell -ep bypass -f ./win_btshare.ps1 -Mode send -FilePath "D:\file.pdf" -DeviceName "MyDevice"
powershell -ep bypass -f ./win_btshare.ps1 -Mode send -FilePath "D:\file.pdf" -DeviceAddress <HH:HH:HH:HH:HH:HH | HHHHHHHHHHHH>
```

### Receive files

```powershell
powershell -ep bypass -f ./win_btshare.ps1 -Mode receive
powershell -ep bypass -f ./win_btshare.ps1 -Mode receive -SaveDir "D:\Incoming"
powershell -ep bypass -f ./win_btshare.ps1 -Mode receive -SaveDir "D:\Incoming" -Continuous
powershell -ep bypass -f ./win_btshare.ps1 -Mode receive -Discoverable
```
