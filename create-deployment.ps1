param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{2,63}$')]
    [string]$DeploymentName,

    [ValidateSet("artist", "portfolio", "company", "store")]
    [string]$Type = "artist",

    [Parameter(Mandatory = $true)]
    [string]$Domain,

    [string]$VercelProject = ""
)

$ErrorActionPreference = "Stop"
$slug = $DeploymentName.ToLowerInvariant()
$envFile = ".env.$slug"

Write-Host "==> Creating or checking Neon branch '$slug'"
neon checkout $slug --create --no-env-pull
if ($LASTEXITCODE -ne 0) { throw "Neon branch setup failed." }

Write-Host "==> Applying Neon infrastructure to the branch"
neon deploy --branch $slug --update-existing -y
if ($LASTEXITCODE -ne 0) { throw "Neon infrastructure deployment failed." }

Write-Host "==> Pulling branch-specific database and storage variables"
neon env pull --branch $slug --file $envFile
if ($LASTEXITCODE -ne 0) { throw "Environment pull failed." }

$values = @{}
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $values[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    }
}

$domainInput = $Domain.Trim()
if ($domainInput -match '^https?://') {
    $parsedDomain = $null
    if (-not [Uri]::TryCreate($domainInput, [UriKind]::Absolute, [ref]$parsedDomain) -or
        $parsedDomain.Scheme -ne "https" -or $parsedDomain.AbsolutePath -ne "/" -or
        $parsedDomain.Query -or $parsedDomain.Fragment) {
        throw "Domain must be a hostname or an HTTPS origin without a path."
    }
    $domainHost = $parsedDomain.Host
} else {
    $domainHost = $domainInput.TrimEnd("/")
}
if ($domainHost -notmatch '^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))+$') {
    throw "Domain must be a valid hostname, such as ecommerce.example.com."
}

$randomBytes = New-Object byte[] 48
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $rng.GetBytes($randomBytes)
} finally {
    $rng.Dispose()
}
$secretKey = -join ($randomBytes | ForEach-Object { $_.ToString("x2") })
$values["DEBUG"] = "0"
$values["SECRET_KEY"] = $secretKey
$values["ALLOWED_HOSTS"] = "$domainHost,.vercel.app"
$values["CSRF_TRUSTED_ORIGINS"] = "https://$domainHost"
$values["HTTPS"] = "1"

$lines = @()
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        $name = $Matches[1]
        if ($values.ContainsKey($name)) {
            $lines += "$name=$($values[$name])"
        } else {
            $lines += $_
        }
    } elseif ($_ -and $_ -notmatch '^#') {
        $lines += $_
    }
}
foreach ($name in @("DEBUG", "SECRET_KEY", "ALLOWED_HOSTS", "CSRF_TRUSTED_ORIGINS", "HTTPS")) {
    if (-not (($lines | ForEach-Object { $_ -match "^$name=" }) -contains $true)) {
        $lines += "$name=$($values[$name])"
    }
}
$lines | Set-Content -Encoding UTF8 $envFile

foreach ($name in $values.Keys) {
    [Environment]::SetEnvironmentVariable($name, $values[$name], "Process")
}

Write-Host "==> Migrating and initializing the new branch"
& .\venv\Scripts\python.exe manage.py migrate --noinput
if ($LASTEXITCODE -ne 0) { throw "Migration failed." }
& .\venv\Scripts\python.exe manage.py provision_deployment --confirm $slug --type $Type
if ($LASTEXITCODE -ne 0) { throw "Starter content initialization failed." }

Write-Host ""
Write-Host "==> Create the owner account for this deployment"
& .\venv\Scripts\python.exe manage.py createsuperuser
if ($LASTEXITCODE -ne 0) { throw "Owner account creation failed." }

if ($VercelProject) {
    Write-Host "==> Linking Vercel project '$VercelProject'"
    vercel link --project $VercelProject --yes
    if ($LASTEXITCODE -ne 0) { throw "Vercel linking failed." }

    foreach ($target in @("production", "preview")) {
        foreach ($name in @(
            "DATABASE_URL",
            "DATABASE_URL_UNPOOLED",
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
            $value = $values[$name]
            if ([string]::IsNullOrEmpty($value)) { continue }
            $value | vercel env add $name $target --force --sensitive *> $null
            if ($LASTEXITCODE -ne 0) { throw "Could not set $name for $target." }
        }
    }
    Write-Host "Vercel environment variables configured."
}

Write-Host ""
Write-Host "Independent deployment setup complete."
Write-Host "Neon branch: $slug"
Write-Host "Private environment file: $envFile"
