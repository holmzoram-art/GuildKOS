@echo off
rem Oppdaterer GuildKOS til nyeste versjon fra GitHub.
rem Legg denne fila i World of Warcraft\_forever_\Interface\AddOns og dobbeltklikk pa den.
rem Den laster ned GuildKOS, bytter ut mappa GuildKOS og ror ingen andre addons.
rem Virker ikke nedlastingen av release-fila, hentes samme kode fra GitHubs kodearkiv i stedet.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$ErrorActionPreference = 'Stop';" ^
 "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;" ^
 "if ((Get-Location).Path -notlike '*\Interface\AddOns') { Write-Host 'Legg fila i World of Warcraft\_forever_\Interface\AddOns og prov igjen.'; exit 1 };" ^
 "if (Test-Path 'GuildKOS\.git') { Write-Host 'Denne GuildKOS-mappa er utviklerens egen kopi og blir ikke endret.'; exit 1 };" ^
 "$zip = Join-Path $env:TEMP 'GuildKOS-oppdatering.zip';" ^
 "$unpack = 'GuildKOS-oppdatering';" ^
 "Write-Host 'Laster ned nyeste GuildKOS ...';" ^
 "try { Invoke-WebRequest -UseBasicParsing 'https://github.com/holmzoram-art/GuildKOS/releases/latest/download/GuildKOS.zip' -OutFile $zip } catch { try { Invoke-WebRequest -UseBasicParsing 'https://github.com/holmzoram-art/GuildKOS/archive/refs/heads/main.zip' -OutFile $zip } catch { Write-Host 'Fikk ikke lastet ned GuildKOS. Sjekk nettet og prov igjen om litt. Ingenting er endret.'; exit 1 } };" ^
 "if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force };" ^
 "Expand-Archive -Path $zip -DestinationPath $unpack -Force;" ^
 "$folder = Get-ChildItem $unpack -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'GuildKOS.toc') } | Select-Object -First 1;" ^
 "if (-not $folder) { Remove-Item $unpack -Recurse -Force; Write-Host 'Fant ikke GuildKOS i nedlastingen. Ingenting er endret.'; exit 1 };" ^
 "if (Test-Path 'GuildKOS') { Remove-Item 'GuildKOS' -Recurse -Force };" ^
 "Move-Item $folder.FullName 'GuildKOS';" ^
 "Remove-Item $unpack -Recurse -Force; Remove-Item $zip -Force;" ^
 "$version = (Select-String -Path 'GuildKOS\GuildKOS.toc' -Pattern '^## Version: (.+)').Matches[0].Groups[1].Value;" ^
 "Write-Host ('GuildKOS er oppdatert til versjon ' + $version + '. Skriv /reload i spillet.')"
pause
