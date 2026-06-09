# Push paas/jenkins/Jenkinsfile.paas-deploy to lab Jenkins (run from Windows dev machine).
# Uses JENKINS_PROBE_URL from paas/frontend/docker-compose.env (192.168.56.129:30090).
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Script = Join-Path $RepoRoot "paas\scripts\create_jenkins_paas_deploy_job.py"
if (-not (Test-Path $Script)) {
    throw "Missing $Script"
}
Write-Host "Syncing Jenkins pipeline from repo to lab Jenkins..."
python $Script --force --force-full
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "OK. Next deploy console must show: marker=multi-framework-20260611"
