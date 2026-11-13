# End-to-end smoke test: connects a Windows forgejo-runner.exe as a repository-level runner to a running,
# throwaway Forgejo server (admin user already created), then dispatches e2e/cancel.yml and
# e2e/smoke.yml as native Windows host jobs and asserts their results through the Forgejo API.
param(
    [Parameter(Mandatory)][string]$Runner,
    [string]$Url = 'http://localhost:3000',
    [string]$User = 'admin_user',
    [string]$Password = 'admin_password'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Runner = (Resolve-Path $Runner).Path
$auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:${Password}")) }
$repo = "$User/e2e"
$terminal = 'success', 'failure', 'cancelled', 'skipped'

function Api([string]$Method, [string]$Path, $Body) {
    $request = @{ Method = $Method; Uri = "$Url/api/v1$Path"; Headers = $auth }
    if ($null -ne $Body) { $request.Body = ConvertTo-Json $Body -Depth 5; $request.ContentType = 'application/json' }
    Invoke-RestMethod @request | ForEach-Object { $_ }  # PS 7 returns a JSON array as one object; unroll it
}

function WaitFor([scriptblock]$Condition, [int]$Seconds, [string]$What) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $result = & $Condition
        if ($result) { return $result }
        Start-Sleep -Seconds 3
    }
    throw "Timed out after ${Seconds}s waiting for $What"
}

function Dispatch([string]$Workflow, $Inputs = @{}) {
    $run = Api POST "/repos/$repo/actions/workflows/$Workflow/dispatches" @{ ref = 'main'; inputs = $Inputs; return_run_info = $true }
    Write-Host "Dispatched $Workflow as run $($run.id) (#$($run.run_number))"
    $run
}

function JobLog($Job) { [string](Api GET "/repos/$repo/actions/jobs/$($Job.id)/logs") }

function AssertContains([string]$Text, [string]$Marker, [string]$Where) {
    if (-not $Text.Contains($Marker)) { throw "Expected '$Marker' in $Where" }
    Write-Host "OK: $Marker ($Where)"
}

$work = New-Item -ItemType Directory -Force -Path (Join-Path ([IO.Path]::GetTempPath()) 'forgejo-runner-e2e')
$workdirParent = 'C:\forgejo-runner-test\work'  # same value as examples/windows-test/config.yml
Push-Location $work
$daemon = $null
try {
    # Test repository holding the fixture workflows; public so the job view (summaries) needs no session.
    Api POST '/user/repos' @{ name = 'e2e'; auto_init = $true; default_branch = 'main' } | Out-Null
    $files = foreach ($name in 'smoke.yml', 'cancel.yml') {
        @{ operation = 'create'; path = ".forgejo/workflows/$name"; content = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $name))) }
    }
    Api POST "/repos/$repo/contents" @{ branch = 'main'; message = 'Add e2e workflows'; files = @($files) } | Out-Null

    # Create the runner in Forgejo and declare it in server.connections, the non-deprecated v13 flow
    # (Forgejo shows the same uuid/token/snippet under Settings > Actions > Runners > Create new runner).
    $registration = Api POST "/repos/$repo/actions/runners" @{ name = 'windows-e2e' }
    Set-Content config.yml @"
log:
  level: debug
runner:
  labels:
    - windows:host
host:
  workdir_parent: '$workdirParent'
server:
  connections:
    forgejo:
      url: $Url/
      uuid: $($registration.uuid)
      token: $($registration.token)
"@
    $daemon = Start-Process $Runner -ArgumentList 'daemon', '--config', 'config.yml' -PassThru -NoNewWindow `
        -RedirectStandardOutput runner.log -RedirectStandardError runner-stderr.log
    WaitFor { (Api GET "/repos/$repo/actions/runners") | Where-Object { $_.name -eq 'windows-e2e' -and $_.status -ne 'offline' } } 120 'runner to come online' | Out-Null
    Write-Host 'OK: runner online'

    # 1. Cancellation: the run must end as cancelled and the step's PowerShell process must be gone.
    $pidFile = Join-Path $work 'cancel.pid'
    $run = Dispatch 'cancel.yml' @{ pidfile = $pidFile }
    WaitFor { (Test-Path $pidFile) -and (Get-Content $pidFile) } 300 'cancel job step to start' | Out-Null
    $stepPid = [int](Get-Content $pidFile)
    Api POST "/repos/$repo/actions/runs/$($run.id)/cancel" | Out-Null
    $status = WaitFor { $s = (Api GET "/repos/$repo/actions/runs/$($run.id)").status; if ($s -in $terminal) { $s } } 120 'cancelled run to finish'
    if ($status -ne 'cancelled') { throw "Cancelled run ended as '$status'" }
    WaitFor { -not (Get-Process -Id $stepPid -ErrorAction SilentlyContinue) } 60 "step process $stepPid to exit" | Out-Null
    Write-Host 'OK: run cancelled and step process stopped'
    if ($daemon.HasExited) { throw 'runner daemon exited after cancellation' }

    # 2. Smoke run on the same daemon: checkout, shells, .NET, job summary, artifact upload + download.
    $run = Dispatch 'smoke.yml'
    $status = WaitFor { $s = (Api GET "/repos/$repo/actions/runs/$($run.id)").status; if ($s -in $terminal) { $s } } 900 'smoke run to finish'
    $jobs = @(Api GET "/repos/$repo/actions/runs/$($run.id)/jobs")
    $logs = @{}
    foreach ($j in $jobs) {
        $logs[$j.name] = JobLog $j
        Write-Host "::group::Forgejo log of job '$($j.name)' ($($j.status))"; Write-Host $logs[$j.name]; Write-Host '::endgroup::'
    }
    if ($status -ne 'success') { throw "Smoke run ended as '$status'" }
    foreach ($marker in 'CHECKOUT_OK', 'DEFAULT_SHELL_OK Core', 'WINPS_OK 5.', 'DOTNET_OK') { AssertContains $logs['host'] $marker 'host job log' }
    AssertContains $logs['download'] 'ARTIFACT_OK' 'download job log'

    $artifacts = @(Api GET "/repos/$repo/actions/runs/$($run.id)/artifacts")
    if (-not ($artifacts | Where-Object name -eq 'e2e-payload')) { throw 'artifact e2e-payload not listed by the API' }
    Write-Host 'OK: artifact listed by the API'

    # Job summaries are only exposed through the web job view (Forgejo 17 + runner >= 13.2).
    $summaries = foreach ($index in 0..($jobs.Count - 1)) {
        (Invoke-RestMethod -Method Post -Uri "$Url/$repo/actions/runs/$($run.run_number)/jobs/$index/attempt/1" `
            -ContentType 'application/json' -Body '{"logCursors":[]}').state.currentJob.summaries
    }
    AssertContains ($summaries -join "`n") 'E2E_SUMMARY_OK' 'job summary'
    if ($daemon.HasExited) { throw 'runner daemon exited during the smoke run' }
    if (-not (Get-ChildItem $workdirParent -ErrorAction SilentlyContinue)) { throw "host.workdir_parent $workdirParent was not used" }
    Write-Host "OK: jobs ran under host.workdir_parent $workdirParent"
    Write-Host 'E2E PASSED'
}
finally {
    if ($daemon -and -not $daemon.HasExited) { Stop-Process -Id $daemon.Id -Force }
    foreach ($log in 'runner.log', 'runner-stderr.log') {
        if (Test-Path $log) { Write-Host "::group::$log"; Get-Content $log | Write-Host; Write-Host '::endgroup::' }
    }
    Pop-Location
}
