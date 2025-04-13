# SQL bağlantı bilgileri
$server = "ServerName"
$database = "PerfDB"
$table = "PerfMon_Stats"
$connString = "Server=$server;Database=$database;Integrated Security=True"


<# 
CREATE DATABASE PerfDB
GO
USE [PerfDB]
GO

/****** Object:  Table [dbo].[PerfMon_Stats]    Script Date: 4/13/2025 11:02:43 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[PerfMon_Stats](
	[ID] [int] IDENTITY(1,1) NOT NULL,
	[CollectedAt] [datetime] NULL,
	[ProcessName] [nvarchar](100) NULL,
	[CPU] [float] NULL,
	[DiskKBPerSec] [float] NULL,
	[MemoryMB] [float] NULL,
	[Description] [nvarchar](2000) NULL,
	[Path] [nvarchar](2000) NULL,
PRIMARY KEY CLUSTERED 
(
	[ID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO





CREATE VIEW VWTOP20Disk  
AS
SELECT TOP 20 ProcessName,SUM(DiskKBPerSec) AS DiskKBPerSec FROM PerfMon_Stats 
group by ProcessName
ORDER BY DiskKBPerSec desc

GO

CREATE VIEW VWTOP20Cpu 
AS
SELECT TOP 20 ProcessName,SUM(CPU) AS CPU FROM PerfMon_Stats 
group by ProcessName
ORDER BY CPU desc

GO

CREATE VIEW VWTOP20Memory
AS
SELECT TOP 20 ProcessName,SUM(MemoryMB) AS MemoryMB FROM PerfMon_Stats 
group by ProcessName
ORDER BY MemoryMB desc



SELECT * FROM VWTOP20Disk
SELECT * FROM VWTOP20Cpu
SELECT * FROM VWTOP20Memory
#>



$sampleInterval = 5
$counterSamples = Get-Counter -Counter "\Process(*)\% Processor Time","\Process(*)\IO Data Bytes/sec","\Process(*)\Working Set - Private" -SampleInterval $sampleInterval -MaxSamples 1

# Dictionary’ler
$cpuMap = @{}
$diskMap = @{}
$memMap = @{}

foreach ($c in $counterSamples.CounterSamples) {
    $proc = $c.InstanceName
    if (!$proc -or $proc -eq "_Total" -or $proc -eq "Idle") { continue }

    $value = [math]::Round($c.CookedValue, 2)
    if ($c.Path -like "*% Processor Time") {
        $cpuMap[$proc] = $value
    } elseif ($c.Path -like "*IO Data Bytes/sec") {
        $diskMap[$proc] = [math]::Round($value / 1KB, 2)  # KB
    } elseif ($c.Path -like "*Working Set - Private") {
        $memMap[$proc] = [math]::Round($value / 1MB, 2)  # MB
    }
}

# Process detaylarını al (path, description)
$procInfo = Get-Process | Where-Object { $_.Name -and $_.Path } | ForEach-Object {
    [PSCustomObject]@{
        Name        = $_.Name
        Description = $_.MainModule.FileVersionInfo.FileDescription
        Path        = $_.Path
        Id          = $_.Id
    }
}

# Tüm bilgileri birleştir
$finalStats = @()

foreach ($proc in ($cpuMap.Keys + $diskMap.Keys + $memMap.Keys | Sort-Object -Unique)) {
    $info = $procInfo | Where-Object { $_.Name -eq $proc }

    $finalStats += [PSCustomObject]@{
        ProcessName  = $proc
        CPU          = $cpuMap[$proc]
        DiskKBPerSec = $diskMap[$proc]
        MemoryMB     = $memMap[$proc]
        Description  = $info.Description
        Path         = $info.Path
    }
}

# En çok tüketen ilk 10'lar
$topCPU    = $finalStats | Sort-Object CPU -Descending | Select-Object -First 10
$topDisk   = $finalStats | Sort-Object DiskKBPerSec -Descending | Select-Object -First 10
$topMemory = $finalStats | Sort-Object MemoryMB -Descending | Select-Object -First 10

# Yazdır
"=== 🧠 Top 10 CPU Consumers ==="
$topCPU | Format-Table -AutoSize

"=== 💾 Top 10 Disk I/O Consumers ==="
$topDisk | Format-Table -AutoSize

"=== 🧬 Top 10 Memory Consumers ==="
$topMemory | Format-Table -AutoSize

# SQL'e yaz
$collectedAt = Get-Date

$allTop = $topCPU + $topDisk + $topMemory | Sort-Object ProcessName -Unique

foreach ($proc in $allTop) {
    $query = @"
INSERT INTO $table (CollectedAt, ProcessName, CPU, DiskKBPerSec, MemoryMB, Description, Path)
VALUES ('$collectedAt', '$($proc.ProcessName)', $($proc.CPU), $($proc.DiskKBPerSec), $($proc.MemoryMB), N'$($proc.Description)', N'$($proc.Path)')
"@
    Invoke-Sqlcmd -Query $query -ConnectionString $connString
}
