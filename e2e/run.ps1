# End-to-end smoke test: connects a Windows forgejo-runner.exe as a repository-level runner to a running,
# throwaway Forgejo server (15 LTS or newer, admin user already created), then dispatches e2e/cancel.yml and
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

# Forgejo 15 has no API for cancelling runs, job logs or artifacts; use the endpoints its web UI calls.
function Web([string]$Method, [string]$Path) {
    $request = @{ Method = $Method; Uri = "$Url/$repo/actions/runs/$Path"; WebSession = $web }
    if ($Method -eq 'Post') { $request.Body = '{"logCursors":[]}'; $request.ContentType = 'application/json' }
    Invoke-RestMethod @request
}

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
    Invoke-WebRequest -Method Post "$Url/user/login" -Body @{ user_name = $User; password = $Password } -SessionVariable web | Out-Null

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
    Web Post "$($run.run_number)/cancel" | Out-Null
    $status = WaitFor { $s = (Api GET "/repos/$repo/actions/runs/$($run.id)").status; if ($s -in $terminal) { $s } } 120 'cancelled run to finish'
    if ($status -ne 'cancelled') { throw "Cancelled run ended as '$status'" }
    WaitFor { -not (Get-Process -Id $stepPid -ErrorAction SilentlyContinue) } 60 "step process $stepPid to exit" | Out-Null
    Write-Host 'OK: run cancelled and step process stopped'
    if ($daemon.HasExited) { throw 'runner daemon exited after cancellation' }

    # 2. Smoke run on the same daemon: checkout, shells, .NET, job summary, artifact upload + download.
    $run = Dispatch 'smoke.yml'
    $status = WaitFor { $s = (Api GET "/repos/$repo/actions/runs/$($run.id)").status; if ($s -in $terminal) { $s } } 900 'smoke run to finish'
    $jobs = @((Web Post "$($run.run_number)/jobs/0/attempt/1").state.run.jobs)
    $logs = @{}
    $summaries = @()
    $hasSummaries = $false
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $name = $jobs[$i].name
        $logs[$name] = [string](Web Get "$($run.run_number)/jobs/$i/attempt/1/logs")
        Write-Host "::group::Forgejo log of job '$name' ($($jobs[$i].status))"; Write-Host $logs[$name]; Write-Host '::endgroup::'
        $current = (Web Post "$($run.run_number)/jobs/$i/attempt/1").state.currentJob
        if ($current.PSObject.Properties['summaries']) { $hasSummaries = $true; $summaries += $current.summaries }
    }
    if ($status -ne 'success') { throw "Smoke run ended as '$status'" }
    foreach ($marker in 'CHECKOUT_OK', 'DEFAULT_SHELL_OK Core', 'WINPS_OK 5.', 'DOTNET_OK') { AssertContains $logs['host'] $marker 'host job log' }
    AssertContains $logs['download'] 'ARTIFACT_OK' 'download job log'

    if (-not ((Web Get "$($run.run_number)/artifacts").artifacts | Where-Object name -eq 'e2e-payload')) { throw 'artifact e2e-payload not listed' }
    Write-Host 'OK: artifact listed by Forgejo'

    # Job summaries are shown by Forgejo 17+ (runner >= 13.2); older servers have no summaries field.
    if ($hasSummaries) { AssertContains ($summaries -join "`n") 'E2E_SUMMARY_OK' 'job summary' }
    else { Write-Host "SKIP: job summaries (not supported by Forgejo $((Api GET '/version').version))" }
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
