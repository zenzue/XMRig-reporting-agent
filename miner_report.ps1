$server = "http://YOUR.SERVER.IP:8000"    # change to your server
$report_endpoint = "$server/report"
$machine_id = "$env:COMPUTERNAME"
$worker = "worker-$env:COMPUTERNAME"
$interval = 3600                            

function Get-CPUUsage {
    $cpu = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
    return [math]::Round($cpu,2)
}

function Get-Hashrate {
    return 0
}

while ($true) {
    $report = @{
        machine_id = $machine_id
        worker = $worker
        cpu_usage = (Get-CPUUsage)
        hashrate = (Get-Hashrate)
        unpaid_estimate = 0.0
        note = ""
    }
    $json = $report | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri $report_endpoint -Method Post -Body $json -ContentType "application/json" -TimeoutSec 10
    }
    catch {
    }
    Start-Sleep -Seconds $interval
}
