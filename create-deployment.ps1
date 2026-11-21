param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{2,63}$')]
    [string]$DeploymentName,

    [ValidateSet("artist", "portfolio", "company", "store")]
    [string]$Type = "artist",

    [string]$Domain = "",

    [string]$VercelProject = ""
)

$ErrorActionPreference = "Stop"
$slug = $DeploymentName.ToLowerInvariant()
$envFile = ".env.$slug"

Write-Host "==> Creating Neon branch '$slug'"
neon checkout $slug --create --no-env-pull
if ($LASTEXITCODE -ne 0) { throw "Neon branch creation failed." }

Write-Host "==> Deploying the branch's storage configuration"
neon deploy --branch $slug --update-existing -y
if ($LASTEXITCODE -ne 0) { throw "Neon storage deployment failed." }

Write-Host "==> Pulling branch-specific database and storage values"
neon env pull --branch $slug --file $envFile
if ($LASTEXITCODE -ne 0) { throw "Neon environment pull failed." }

$lines = Get-Content $envFile -ErrorAction SilentlyContinue
$secret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(48)).ToLowerInvariant()
$allowedHosts = "localhost,127.0.0.1"
$csrfOrigins = ""
if ($Domain) {
    $allowedHosts = $Domain
    $csrfOrigins = "https://$Domain"
}

$values = @{
    DEBUG = "0"
    SECRET_KEY = $secret
    ALLOWED_HOSTS = $allowedHosts
    CSRF_TRUSTED_ORIGINS = $csrfOrigins
    HTTPS = "1"
}
foreach ($name in $values.Keys) {
    $escaped = $values[$name] -replace '\\', '\\' -replace '"', '\"'
    $pattern = "^$name="
    $matching = $lines | Where-Object { $_ -match $pattern }
    if ($matching) {
        $lines = $lines | ForEach-Object { if ($_ -match $pattern) { "$name=$escaped" } else { $_ } }
    } else {
        $lines += "$name=$escaped"
    }
}
$lines | Set-Content -Encoding UTF8 $envFile

Write-Host "==> Loading branch environment"
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
    }
}

Write-Host "==> Resetting PostgreSQL data and creating fresh $Type starter content"
& .\venv\Scripts\python.exe manage.py migrate --noinput
if ($LASTEXITCODE -ne 0) { throw "Database migrations failed." }
& .\venv\Scripts\python.exe manage.py provision_deployment --confirm $slug --type $Type
if ($LASTEXITCODE -ne 0) { throw "Deployment provisioning failed." }

Write-Host ""
Write-Host "==> Create this deployment's owner account"
& .\venv\Scripts\python.exe manage.py createsuperuser
if ($LASTEXITCODE -ne 0) { throw "Owner account creation failed." }

if ($VercelProject) {
    Write-Host "==> Linking Vercel project '$VercelProject'"
    vercel link --project $VercelProject --yes
    if ($LASTEXITCODE -ne 0) { throw "Vercel linking failed." }

    Write-Host "==> Installing branch variables in Vercel"
    foreach ($name in @(
        "DATABASE_URL",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_ENDPOINT_URL_S3",
        "AWS_REGION",
        "DEBUG",
        "SECRET_KEY",
        "ALLOWED_HOSTS",
        "CSRF_TRUSTED_ORIGINS",
        "HTTPS"
    )) {
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if ([string]::IsNullOrEmpty($value)) { continue }
        $value | vercel env add $name production --force --sensitive
        if ($LASTEXITCODE -ne 0) { throw "Could not set Vercel variable $name." }
        $value | vercel env add $name preview --force --sensitive
        if ($LASTEXITCODE -ne 0) { throw "Could not set Vercel preview variable $name." }
    }
}

Write-Host ""
Write-Host "Deployment provisioned."
Write-Host "Neon branch: $slug"
Write-Host "Environment file: $envFile"
Write-Host "If --VercelProject was omitted, copy the Neon/AWS variables from $envFile into that Vercel project."
