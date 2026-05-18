param(
    [int[]]$AckCandidates = @(80, 100, 120, 140, 160, 180, 200),
    [int]$Stage1DurationSec = 120,
    [int]$Stage2DurationSec = 1200,
    [int]$Stage3DurationSec = 1200,
    [int]$Stage4DurationSec = 120,
    [double]$NoErrorBaselineUtil = 95.93,
    [double]$NoErrorUtilDropAllowance = 0.30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:MsBuild = 'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe'
$script:DataTimer = 2200
$script:BacklogFactor = 3
$script:PortSeed = 61000
$script:Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:RunRoot = Join-Path $script:RepoRoot ("docs\测试记录\4.3-ACK搭载定时器\ack-opt-dt2200-bg3-{0}" -f $script:Timestamp)
$script:BinRoot = Join-Path $script:RunRoot '_bin'
$script:AllResults = New-Object System.Collections.Generic.List[object]
$script:BuiltCandidates = @{}

function New-Directory {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return (Resolve-Path $Path).Path
}

function Invoke-MSBuild {
    param(
        [int]$AckTimer,
        [string]$BuildLog
    )

    $env:_CL_ = "/DACK_TIMER=$AckTimer"
    try {
        & $script:MsBuild datalink.sln /t:Rebuild /p:Configuration=Debug /p:Platform=Win32 /m *> $BuildLog
        if ($LASTEXITCODE -ne 0) {
            throw "MSBuild failed for ACK_TIMER=$AckTimer."
        }
    }
    finally {
        Remove-Item Env:\_CL_ -ErrorAction SilentlyContinue
    }
}

function Build-Candidate {
    param([int]$AckTimer)

    if ($script:BuiltCandidates.ContainsKey($AckTimer)) {
        return $script:BuiltCandidates[$AckTimer]
    }

    $candidateDir = New-Directory (Join-Path $script:BinRoot ("ack{0}" -f $AckTimer))
    $buildLog = Join-Path $candidateDir ("build-ack{0}.txt" -f $AckTimer)
    $exePath = Join-Path $candidateDir ("datalink-ack{0}.exe" -f $AckTimer)

    Invoke-MSBuild -AckTimer $AckTimer -BuildLog $buildLog
    Copy-Item (Join-Path $script:RepoRoot 'Debug\datalink.exe') $exePath -Force

    $candidate = [pscustomobject]@{
        ACK_TIMER = $AckTimer
        ExePath = $exePath
        BuildLog = $buildLog
    }
    $script:BuiltCandidates[$AckTimer] = $candidate
    return $candidate
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

function Start-Run {
    param(
        [pscustomobject]$Candidate,
        [string]$StageName,
        [string]$ScenarioName,
        [bool]$UseUtopia,
        [int]$DurationSec,
        [string]$TagPrefix
    )

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
    if ($UseUtopia) {
        $argsBase = @('-u') + $argsBase
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $procA = Start-Process -FilePath $Candidate.ExePath -ArgumentList ($argsBase + @('-l', $paths.ALog, 'A')) -WorkingDirectory $script:RepoRoot -WindowStyle Hidden -RedirectStandardOutput $paths.AStdout -RedirectStandardError $paths.AStderr -PassThru
    Start-Sleep -Milliseconds 200
    $procB = Start-Process -FilePath $Candidate.ExePath -ArgumentList ($argsBase + @('-l', $paths.BLog, 'B')) -WorkingDirectory $script:RepoRoot -WindowStyle Hidden -RedirectStandardOutput $paths.BStdout -RedirectStandardError $paths.BStderr -PassThru

    return [pscustomobject]@{
        Candidate = $Candidate
        StageName = $StageName
        ScenarioName = $ScenarioName
        UseUtopia = $UseUtopia
        DurationSec = $DurationSec
        Tag = $tag
        Port = $port
        Paths = $paths
        Stopwatch = $stopwatch
        ProcessA = $procA
        ProcessB = $procB
    }
}

function Finish-Run {
    param([pscustomobject]$Run)

    $forcedStop = $false
    try {
        Wait-Process -Id @($Run.ProcessA.Id, $Run.ProcessB.Id) -Timeout ($Run.DurationSec + 180)
    }
    catch {
        foreach ($proc in @($Run.ProcessA, $Run.ProcessB)) {
            $proc.Refresh()
            if (-not $proc.HasExited) {
                $forcedStop = $true
                Stop-Process -Id $proc.Id -Force
            }
        }
    }
    $Run.Stopwatch.Stop()

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

    $result = [pscustomobject]@{
        Stage = $Run.StageName
        Scenario = $Run.ScenarioName
        Utopia = $Run.UseUtopia
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
    $script:AllResults.Add($result) | Out-Null
    return $result
}

function Invoke-StageBatch {
    param(
        [string]$StageName,
        [string]$ScenarioName,
        [bool]$UseUtopia,
        [int]$DurationSec,
        [string]$TagPrefix,
        [int[]]$AckTimers
    )

    $candidates = foreach ($ack in $AckTimers) { Build-Candidate -AckTimer $ack }
    $jobs = foreach ($candidate in $candidates) {
        [pscustomobject]@{
            Candidate = $candidate
            StageName = $StageName
            ScenarioName = $ScenarioName
            UseUtopia = $UseUtopia
            DurationSec = $DurationSec
            TagPrefix = $TagPrefix
        }
    }

    $runs = foreach ($job in $jobs) {
        Start-Run -Candidate $job.Candidate -StageName $job.StageName -ScenarioName $job.ScenarioName -UseUtopia $job.UseUtopia -DurationSec $job.DurationSec -TagPrefix $job.TagPrefix
    }

    $results = @()
    foreach ($job in $jobs) {
        $run = $runs | Where-Object { $_.Candidate.ACK_TIMER -eq $job.Candidate.ACK_TIMER } | Select-Object -First 1
        $results += Finish-Run -Run $run
    }
    return $results
}

function Sort-Results {
    param([object[]]$Results)

    return $Results | Sort-Object `
        @{ Expression = { if ($_.Valid) { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = 'Score'; Descending = $true }, `
        @{ Expression = 'AvgUtil'; Descending = $true }, `
        @{ Expression = 'DataTimeoutPerMin'; Descending = $false }, `
        @{ Expression = 'SendAckPerMin'; Descending = $false }, `
        @{ Expression = { if ($_.ACK_TIMER -eq 120) { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = 'ACK_TIMER'; Descending = $false }
}

function Write-StageArtifacts {
    param(
        [string]$StageName,
        [object[]]$Results,
        [string]$Purpose
    )

    $stageDir = New-Directory (Join-Path $script:RunRoot $StageName)
    $csvPath = Join-Path $stageDir 'results.csv'
    $summaryPath = Join-Path $stageDir '阶段摘要.md'

    $Results | Sort-Object ACK_TIMER | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    $sorted = Sort-Results -Results $Results
    $tableLines = foreach ($result in $sorted) {
        '| `{0}` | `{1}%` | `{2}` | `{3}` | `{4}` | `{5}` | `{6}` | `{7}` |' -f `
            $result.ACK_TIMER, `
            $result.AvgUtil, `
            $result.DataTimeoutTotal, `
            $result.DataTimeoutPerMin, `
            $result.SendAckTotal, `
            $result.SendAckPerMin, `
            $result.Score, `
            $result.Valid
    }

    $content = @(
        "# $StageName"
        ''
        "生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ''
        "测试目的：$Purpose"
        ''
        '| ACK_TIMER | 平均利用率 | DATA timeout | timeout/min | 独立ACK | ack/min | Score | Valid |'
        '| ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |'
    ) + $tableLines

    Set-Content -Path $summaryPath -Value $content -Encoding UTF8
}

function Get-TopStage2Candidates {
    param([object[]]$Stage1Results)

    $valid = Sort-Results -Results $Stage1Results | Where-Object { $_.Valid }
    $selected = New-Object System.Collections.Generic.List[int]
    $selected.Add(120) | Out-Null

    foreach ($result in $valid) {
        if (-not $selected.Contains($result.ACK_TIMER)) {
            $selected.Add($result.ACK_TIMER) | Out-Null
        }
        if ($selected.Count -ge 3) {
            break
        }
    }

    return ($selected | Select-Object -Unique)
}

function Get-LongRunRanking {
    param([object[]]$LongResults)

    $grouped = foreach ($group in ($LongResults | Group-Object ACK_TIMER)) {
        $rows = $group.Group
        [pscustomobject]@{
            ACK_TIMER = [int]$group.Name
            Runs = $rows.Count
            AvgScore = [math]::Round((($rows | Measure-Object Score -Average).Average), 3)
            AvgUtil = [math]::Round((($rows | Measure-Object AvgUtil -Average).Average), 3)
            AvgDataTimeoutPerMin = [math]::Round((($rows | Measure-Object DataTimeoutPerMin -Average).Average), 3)
            AvgSendAckPerMin = [math]::Round((($rows | Measure-Object SendAckPerMin -Average).Average), 3)
            AllValid = -not ($rows | Where-Object { -not $_.Valid })
        }
    }

    return $grouped | Sort-Object `
        @{ Expression = { if ($_.AllValid) { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = 'AvgScore'; Descending = $true }, `
        @{ Expression = 'AvgUtil'; Descending = $true }, `
        @{ Expression = 'AvgDataTimeoutPerMin'; Descending = $false }, `
        @{ Expression = 'AvgSendAckPerMin'; Descending = $false }, `
        @{ Expression = { if ($_.ACK_TIMER -eq 120) { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = 'ACK_TIMER'; Descending = $false }
}

function Write-FinalAnalysis {
    param(
        [object[]]$Stage1Results,
        [object[]]$Stage2Results,
        [object[]]$Stage3Results,
        [object[]]$Stage4Results,
        [object]$FinalSelection
    )

    $reportPath = Join-Path $script:RunRoot 'ACK_TIMER-2200ms基础优化报告.md'
    $ranking = Get-LongRunRanking -LongResults ($Stage2Results + $Stage3Results)

    $content = @(
        '# ACK_TIMER 在 DATA_TIMER=2200 / BACKLOG=3 下的重新优化报告'
        ''
        "生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ''
        '## 目标'
        ''
        '- 固定 `DATA_TIMER = 2200 ms`。'
        '- 固定 `MAX_PHL_BACKLOG = 3 * FRAME_WIRE_BYTES(DATA_FRAME_LEN)`。'
        '- 在默认误码率双向洪水场景下，以折中评分重新选择 `ACK_TIMER`。'
        ''
        '## 评分公式'
        ''
        '- `Score = AvgUtil - 0.03 * DataTimeoutPerMin - 0.002 * SendAckPerMin`'
        '- 仅当 `BothQuit=True`、`Fatal=False`、`BadPacket=False`、`PhlOverflow=False`、`ForcedStop=False` 时记为有效。'
        ''
        '## 长测候选平均排名'
        ''
        '| ACK_TIMER | Runs | AvgScore | AvgUtil | Avg timeout/min | Avg ack/min | AllValid |'
        '| ---: | ---: | ---: | ---: | ---: | ---: | --- |'
    )

    foreach ($row in $ranking) {
        $content += '| `{0}` | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` | `{6}` |' -f `
            $row.ACK_TIMER, $row.Runs, $row.AvgScore, $row.AvgUtil, $row.AvgDataTimeoutPerMin, $row.AvgSendAckPerMin, $row.AllValid
    }

    $content += @(
        ''
        '## 最终结论'
        ''
        ('- 最终采用 `ACK_TIMER = {0} ms`。' -f $FinalSelection.ACK_TIMER)
        ('- 采用原因：`AvgScore = {0}`，`AvgUtil = {1}%`，`Avg timeout/min = {2}`，`Avg ack/min = {3}`。' -f `
            $FinalSelection.AvgScore, $FinalSelection.AvgUtil, $FinalSelection.AvgDataTimeoutPerMin, $FinalSelection.AvgSendAckPerMin)
        ''
        '## 产物'
        ''
        ('- 粗筛结果：`{0}`' -f (Join-Path '01-粗筛-2min' 'results.csv'))
        ('- 长测结果：`{0}`' -f (Join-Path '02-长测-20min' 'results.csv'))
        ('- 复测结果：`{0}`' -f (Join-Path '03-冠军复测-20min' 'results.csv'))
        ('- 无误码校验：`{0}`' -f (Join-Path '04-无误码校验-2min' 'results.csv'))
    )

    Set-Content -Path $reportPath -Value $content -Encoding UTF8
}

New-Directory $script:RunRoot | Out-Null
New-Directory $script:BinRoot | Out-Null

Write-Host "Building initial ACK_TIMER candidates..."
foreach ($ack in $AckCandidates) {
    Build-Candidate -AckTimer $ack | Out-Null
}

Write-Host "Stage 1: coarse screening (parallel candidate builds, batched execution)."
$stage1Results = Invoke-StageBatch -StageName '01-粗筛-2min' -ScenarioName '默认误码洪水' -UseUtopia:$false -DurationSec $Stage1DurationSec -TagPrefix 'coarse-default-flood' -AckTimers $AckCandidates
$stage1Sorted = Sort-Results -Results $stage1Results
$bestStage1 = $stage1Sorted[0]

if ($bestStage1.ACK_TIMER -eq 80) {
    Build-Candidate -AckTimer 60 | Out-Null
    $stage1Results += Invoke-StageBatch -StageName '01-粗筛-2min' -ScenarioName '默认误码洪水' -UseUtopia:$false -DurationSec $Stage1DurationSec -TagPrefix 'coarse-default-flood-ext' -AckTimers @(60)
}
elseif ($bestStage1.ACK_TIMER -eq 200) {
    Build-Candidate -AckTimer 220 | Out-Null
    $stage1Results += Invoke-StageBatch -StageName '01-粗筛-2min' -ScenarioName '默认误码洪水' -UseUtopia:$false -DurationSec $Stage1DurationSec -TagPrefix 'coarse-default-flood-ext' -AckTimers @(220)
}

Write-StageArtifacts -StageName '01-粗筛-2min' -Results $stage1Results -Purpose '固定 DATA_TIMER=2200 / BACKLOG=3，对 ACK_TIMER 候选做 2 分钟默认误码双向洪水粗筛。'

$stage2Candidates = Get-TopStage2Candidates -Stage1Results $stage1Results
Write-Host ("Stage 2 candidates: {0}" -f (($stage2Candidates | Sort-Object) -join ', '))
$stage2Results = Invoke-StageBatch -StageName '02-长测-20min' -ScenarioName '默认误码洪水' -UseUtopia:$false -DurationSec $Stage2DurationSec -TagPrefix 'long-default-flood' -AckTimers $stage2Candidates
Write-StageArtifacts -StageName '02-长测-20min' -Results $stage2Results -Purpose '固定 DATA_TIMER=2200 / BACKLOG=3，对入选 ACK_TIMER 做 20 分钟默认误码双向洪水长测。'

$stage2Ranking = Get-LongRunRanking -LongResults $stage2Results
$stage3Champion = [int]$stage2Ranking[0].ACK_TIMER
Write-Host ("Stage 3 champion retest: ACK_TIMER={0}" -f $stage3Champion)
$stage3Results = Invoke-StageBatch -StageName '03-冠军复测-20min' -ScenarioName '默认误码洪水' -UseUtopia:$false -DurationSec $Stage3DurationSec -TagPrefix 'retest-default-flood' -AckTimers @($stage3Champion)
Write-StageArtifacts -StageName '03-冠军复测-20min' -Results $stage3Results -Purpose '对长测第一名 ACK_TIMER 做 20 分钟默认误码双向洪水复测。'

$longRunResults = @($stage2Results + $stage3Results)
$longRanking = Get-LongRunRanking -LongResults $longRunResults
$baseline120 = $longRanking | Where-Object { $_.ACK_TIMER -eq 120 } | Select-Object -First 1
if (-not $baseline120) {
    throw 'Missing current-run 120 ms baseline in long-test ranking.'
}

$selected = $longRanking[0]
if ($selected.ACK_TIMER -ne 120 -and $selected.AvgScore -le $baseline120.AvgScore) {
    $selected = $baseline120
}

$stage4Results = @()
$stage4Attempts = @{}
$stage4Rejected = New-Object System.Collections.Generic.HashSet[int]
while ($true) {
    if (-not $stage4Attempts.ContainsKey($selected.ACK_TIMER)) {
        Write-Host ("Stage 4 no-error validation: ACK_TIMER={0}" -f $selected.ACK_TIMER)
        $attempts = Invoke-StageBatch -StageName '04-无误码校验-2min' -ScenarioName '无误码洪水' -UseUtopia:$true -DurationSec $Stage4DurationSec -TagPrefix 'utopia-flood' -AckTimers @([int]$selected.ACK_TIMER)
        $stage4Results += $attempts
        $stage4Attempts[$selected.ACK_TIMER] = $attempts[0]
    }

    $check = $stage4Attempts[$selected.ACK_TIMER]
    $threshold = $NoErrorBaselineUtil - $NoErrorUtilDropAllowance
    if ($check.Valid -and $check.AvgUtil -ge $threshold) {
        break
    }

    $stage4Rejected.Add([int]$selected.ACK_TIMER) | Out-Null
    $fallback = $longRanking | Where-Object { -not $stage4Rejected.Contains([int]$_.ACK_TIMER) } | Select-Object -First 1
    if (-not $fallback) {
        throw 'No valid fallback ACK_TIMER after no-error validation failure.'
    }
    $selected = $fallback
}

Write-StageArtifacts -StageName '04-无误码校验-2min' -Results $stage4Results -Purpose '对最终候选 ACK_TIMER 做 2 分钟无误码双向洪水校验。'

$allCsvPath = Join-Path $script:RunRoot 'all-results.csv'
$script:AllResults | Export-Csv -Path $allCsvPath -NoTypeInformation -Encoding UTF8
Write-FinalAnalysis -Stage1Results $stage1Results -Stage2Results $stage2Results -Stage3Results $stage3Results -Stage4Results $stage4Results -FinalSelection $selected

Write-Host ''
Write-Host ("FINAL_ACK_TIMER={0}" -f $selected.ACK_TIMER)
Write-Host ("RUN_ROOT={0}" -f $script:RunRoot)
