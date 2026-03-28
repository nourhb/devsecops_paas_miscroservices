$ErrorActionPreference = "Stop"

Set-Location "$PSScriptRoot/../frontend"

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
  Write-Host "Created frontend/.env from .env.example"
}

npm install
npm run prisma:generate
npm run prisma:migrate

Write-Host "Bootstrap completed. Run: npm run dev"
