param(
    [Parameter(Mandatory = $true)]
    [string]$RunRoot,
    [Parameter(Mandatory = $true)]
    [string]$StageName,
    [Parameter(Mandatory = $true)]
    [string]$AckTimers,
    [int]$DurationSec = 1200,
    [int]$UseUtopia = 0,
    [string]$ScenarioName = 'default flood',
    [string]$TagPrefix = 'batch',
    [int]$PortSeed = 63000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:RunRoot = (Resolve-Path $RunRoot).Path
$script:BinRoot = Join-Path $script:RunRoot '_bin'
$script:DataTimer = 2200
$script:BacklogFactor = 3
$script:PortSeed = $PortSeed
$script:UseUtopiaFlag = ($UseUtopia -ne 0)
$script:AckTimerValues = @($AckTimers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { [int]$_ })
if ($script:AckTimerValues.Count -eq 0) {
    throw 'No ACK_TIMER values provided.'
}

function New-Directory {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return (Resolve-Path $Path).Path
}

function Get-LastStat {
    param([string]$Text)

    $pattern = '(?m)^(?<ts>\d+(?:\.\d+)?)\s+\.\.\.\.\s+(?<packets>\d+)\s+packets received,\s+(?<bps>\d+)\s+bps,\s+(?<util>\d+(?:\.\d+)?)%,\s+Err\s+(?<errCount>\d+)\s+\((?<errRate>[^)]+)\)'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -eq 0) {
        return $null
    }

    $last = $matches[$matches.Count - 1]
    $times = @()
    foreach ($match in $matches) {
        $times += [double]$match.Groups['ts'].Value
    }

    $maxGap = 0.0
    for ($i = 1; $i -lt $times.Count; $i++) {
        $gap = $times[$i] - $times[$i - 1]
        if ($gap -gt $maxGap) {
            $maxGap = $gap
        }
    }

    return [pscustomobject]@{
        Time = [double]$last.Groups['ts'].Value
        Packets = [int]$last.Groups['packets'].Value
        Bps = [int]$last.Groups['bps'].Value
        Util = [double]$last.Groups['util'].Value
        ErrCount = [int]$last.Groups['errCount'].Value
        ErrRate = $last.Groups['errRate'].Value
        StatsCount = $matches.Count
        MaxGap = [math]::Round($maxGap, 3)
    }
}

function Get-Count {
    param(
        [string]$Text,
        [string]$Pattern
    )

    return [regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline).Count
}

function Get-Candidate {
    param([int]$AckTimer)

    $candidateDir = Join-Path $script:BinRoot ("ack{0}" -f $AckTimer)
    $exePath = Join-Path $candidateDir ("datalink-ack{0}.exe" -f $AckTimer)
    $buildLog = Join-Path $candidateDir ("build-ack{0}.txt" -f $AckTimer)
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Missing candidate executable: $exePath"
    }

    return [pscustomobject]@{
        ACK_TIMER = $AckTimer
        ExePath = $exePath
        BuildLog = $buildLog
    }
}

function Start-Run {
    param([pscustomobject]$Candidate)

    $stageDir = New-Directory (Join-Path $script:RunRoot $StageName)
    $tag = "{0}-ack{1}-{2}" -f $TagPrefix, $Candidate.ACK_TIMER, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $port = $script:PortSeed
    $script:PortSeed += 1

    $paths = @{
        ALog = Join-Path $stageDir ("{0}-A.log" -f $tag)
        BLog = Join-Path $stageDir ("{0}-B.log" -f $tag)
        AStdout = Join-Path $stageDir ("{0}-A.stdout.txt" -f $tag)
        BStdout = Join-Path $stageDir ("{0}-B.stdout.txt" -f $tag)
        AStderr = Join-Path $stageDir ("{0}-A.stderr.txt" -f $tag)
        BStderr = Join-Path $stageDir ("{0}-B.stderr.txt" -f $tag)
    }

    $argsBase = @('-f', '-d7', '-t', "$DurationSec", '-p', "$port")
    if ($script:UseUtopiaFlag) {
        $argsBase = @('-u') + $argsBase
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $procA = Start-Process -FilePath $Candidate.ExePath -ArgumentList ($argsBase + @('-l', $paths.ALog, 'A')) -WorkingDirectory $script:RepoRoot -WindowStyle Hidden -RedirectStandardOutput $paths.AStdout -RedirectStandardError $paths.AStderr -PassThru
    Start-Sleep -Milliseconds 200
    $procB = Start-Process -FilePath $Candidate.ExePath -ArgumentList ($argsBase + @('-l', $paths.BLog, 'B')) -WorkingDirectory $script:RepoRoot -WindowStyle Hidden -RedirectStandardOutput $paths.BStdout -RedirectStandardError $paths.BStderr -PassThru

    return [pscustomobject]@{
        Candidate = $Candidate
        DurationSec = $DurationSec
        Tag = $tag
        Port = $port
        Paths = $paths
        Stopwatch = $stopwatch
        ProcessA = $procA
        ProcessB = $procB
    }
}

function Wait-Run {
    param([pscustomobject]$Run)

    $deadline = (Get-Date).AddSeconds($Run.DurationSec + 180)
    $forcedStop = $false
    while ($true) {
        $Run.ProcessA.Refresh()
        $Run.ProcessB.Refresh()
        if ($Run.ProcessA.HasExited -and $Run.ProcessB.HasExited) {
            break
        }
        if ((Get-Date) -ge $deadline) {
            foreach ($proc in @($Run.ProcessA, $Run.ProcessB)) {
                $proc.Refresh()
                if (-not $proc.HasExited) {
                    Stop-Process -Id $proc.Id -Force
                    $forcedStop = $true
                }
            }
            break
        }
        Start-Sleep -Seconds 1
    }
    $Run.Stopwatch.Stop()
    return $forcedStop
}

function Finish-Run {
    param([pscustomobject]$Run)

    $forcedStop = Wait-Run -Run $Run

    $textA = if (Test-Path $Run.Paths.AStdout) { Get-Content -Raw $Run.Paths.AStdout } else { '' }
    $textB = if (Test-Path $Run.Paths.BStdout) { Get-Content -Raw $Run.Paths.BStdout } else { '' }

    $statsA = Get-LastStat -Text $textA
    $statsB = Get-LastStat -Text $textB

    $sendAckTotal = (Get-Count -Text $textA -Pattern 'Send ACK') + (Get-Count -Text $textB -Pattern 'Send ACK')
    $ackTimeoutTotal = (Get-Count -Text $textA -Pattern '---- ACK timeout') + (Get-Count -Text $textB -Pattern '---- ACK timeout')
    $dataTimeoutTotal = (Get-Count -Text $textA -Pattern '---- DATA \d+ timeout') + (Get-Count -Text $textB -Pattern '---- DATA \d+ timeout')
    $sendNakTotal = (Get-Count -Text $textA -Pattern 'Send NAK') + (Get-Count -Text $textB -Pattern 'Send NAK')
    $badCrcTotal = (Get-Count -Text $textA -Pattern 'Bad CRC') + (Get-Count -Text $textB -Pattern 'Bad CRC')

    $bothQuit = $textA.Contains('Quit.') -and $textB.Contains('Quit.')
    $fatal = ($textA.Contains('FATAL:') -or $textB.Contains('FATAL:') -or $textA.Contains('Abort.') -or $textB.Contains('Abort.'))
    $badPacket = ($textA.Contains('Network Layer received a bad packet') -or $textB.Contains('Network Layer received a bad packet') -or $textA.Contains('Bad Packet length') -or $textB.Contains('Bad Packet length'))
    $phlOverflow = ($textA.Contains('Physical Layer Sending Queue overflow') -or $textB.Contains('Physical Layer Sending Queue overflow'))
    $valid = $bothQuit -and (-not $forcedStop) -and (-not $fatal) -and (-not $badPacket) -and (-not $phlOverflow)

    $aUtil = if ($statsA) { $statsA.Util } else { 0.0 }
    $bUtil = if ($statsB) { $statsB.Util } else { 0.0 }
    $avgUtil = [math]::Round((($aUtil + $bUtil) / 2.0), 3)
    $minutes = $Run.DurationSec / 60.0
    $dataTimeoutPerMin = [math]::Round($dataTimeoutTotal / $minutes, 3)
    $sendAckPerMin = [math]::Round($sendAckTotal / $minutes, 3)
    $score = [math]::Round(($avgUtil - (0.03 * $dataTimeoutPerMin) - (0.002 * $sendAckPerMin)), 3)

    return [pscustomobject]@{
        Stage = $StageName
        Scenario = $ScenarioName
        Utopia = $script:UseUtopiaFlag
        DurationSec = $Run.DurationSec
        DATA_TIMER = $script:DataTimer
        BACKLOG_FACTOR = $script:BacklogFactor
        ACK_TIMER = $Run.Candidate.ACK_TIMER
        Port = $Run.Port
        Tag = $Run.Tag
        AUtil = $aUtil
        BUtil = $bUtil
        AvgUtil = $avgUtil
        APackets = if ($statsA) { $statsA.Packets } else { 0 }
        BPackets = if ($statsB) { $statsB.Packets } else { 0 }
        AStatsCount = if ($statsA) { $statsA.StatsCount } else { 0 }
        BStatsCount = if ($statsB) { $statsB.StatsCount } else { 0 }
        AMaxStatsGap = if ($statsA) { $statsA.MaxGap } else { 0.0 }
        BMaxStatsGap = if ($statsB) { $statsB.MaxGap } else { 0.0 }
        SendAckTotal = $sendAckTotal
        AckTimeoutTotal = $ackTimeoutTotal
        DataTimeoutTotal = $dataTimeoutTotal
        DataTimeoutPerMin = $dataTimeoutPerMin
        SendAckPerMin = $sendAckPerMin
        SendNakTotal = $sendNakTotal
        BadCrcTotal = $badCrcTotal
        BothQuit = $bothQuit
        ForcedStop = $forcedStop
        Fatal = $fatal
        BadPacket = $badPacket
        PhlOverflow = $phlOverflow
        Valid = $valid
        Score = $score
        ALog = $Run.Paths.ALog
        BLog = $Run.Paths.BLog
        AStdout = $Run.Paths.AStdout
        BStdout = $Run.Paths.BStdout
        BuildLog = $Run.Candidate.BuildLog
        WallSeconds = [math]::Round($Run.Stopwatch.Elapsed.TotalSeconds, 1)
    }
}

function Write-StageArtifacts {
    param([object[]]$Results)

    $stageDir = New-Directory (Join-Path $script:RunRoot $StageName)
    $csvPath = Join-Path $stageDir 'results.csv'
    $summaryPath = Join-Path $stageDir '阶段摘要.md'
    $Results | Sort-Object ACK_TIMER | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    $rows = foreach ($result in ($Results | Sort-Object Score -Descending)) {
        '| `{0}` | `{1}%` | `{2}` | `{3}` | `{4}` | `{5}` | `{6}` | `{7}` |' -f `
            $result.ACK_TIMER, $result.AvgUtil, $result.DataTimeoutTotal, $result.DataTimeoutPerMin, `
            $result.SendAckTotal, $result.SendAckPerMin, $result.Score, $result.Valid
    }

    $content = @(
        "# $StageName"
        ''
        "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ''
        "Scenario: $ScenarioName"
        ''
        '| ACK_TIMER | Avg util | DATA timeout | timeout/min | Send ACK | ack/min | Score | Valid |'
        '| ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |'
    ) + $rows
    Set-Content -Path $summaryPath -Value $content -Encoding UTF8
}

Write-Host ("RUN_ROOT={0}" -f $script:RunRoot)
Write-Host ("Stage batch: {0}; ACK_TIMER={1}; Duration={2}; Utopia={3}" -f $StageName, (($script:AckTimerValues | Sort-Object) -join ', '), $DurationSec, $script:UseUtopiaFlag)

$runs = @()
foreach ($ack in $script:AckTimerValues) {
    $runs += Start-Run -Candidate (Get-Candidate -AckTimer $ack)
}

$results = @()
foreach ($run in $runs) {
    $results += Finish-Run -Run $run
}

Write-StageArtifacts -Results $results
Write-Host ("RESULTS={0}" -f (Join-Path $script:RunRoot (Join-Path $StageName 'results.csv')))
