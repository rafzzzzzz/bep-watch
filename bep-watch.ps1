param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),
    [switch]$Prime,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Read-JsonFile($Path, $DefaultValue) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $DefaultValue
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $DefaultValue
    }

    return $raw | ConvertFrom-Json
}

function Save-JsonFile($Path, $Value) {
    $json = $Value | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Convert-HtmlToText([string]$Html) {
    $text = [regex]::Replace($Html, "<script\b[^<]*(?:(?!</script>)<[^<]*)*</script>", "", "IgnoreCase")
    $text = [regex]::Replace($text, "<style\b[^<]*(?:(?!</style>)<[^<]*)*</style>", "", "IgnoreCase")
    $text = [regex]::Replace($text, "<[^>]+>", " ")
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = [regex]::Replace($text, "\s+", " ").Trim()
    return $text
}

function Get-InputFields([string]$Html) {
    $fields = @{}
    foreach ($match in [regex]::Matches($Html, "<input\b[^>]*>", "IgnoreCase")) {
        $tag = $match.Value
        $nameMatch = [regex]::Match($tag, "name\s*=\s*[""']([^""']+)[""']", "IgnoreCase")
        if (-not $nameMatch.Success) { continue }

        $value = ""
        $valueMatch = [regex]::Match($tag, "value\s*=\s*[""']([^""']*)[""']", "IgnoreCase")
        if ($valueMatch.Success) {
            $value = [System.Net.WebUtility]::HtmlDecode($valueMatch.Groups[1].Value)
        }

        $fields[$nameMatch.Groups[1].Value] = $value
    }
    return $fields
}

function Invoke-BepSearch([string]$Term, [int]$TimeoutSeconds) {
    $url = "https://www.bep.gov.pt/pages/oferta/Oferta_Pesquisa_basica.aspx"
    $headers = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) BEP watcher"
    }

    $first = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $headers -TimeoutSec $TimeoutSeconds
    $body = Get-InputFields $first.Content

    $body["ctl00`$ctl00`$FormMasterContentPlaceHolder`$ContentPlaceHolder1`$txtValor"] = $Term
    $body["ctl00`$ctl00`$FormMasterContentPlaceHolder`$ContentPlaceHolder1`$ucSearch"] = "Pesquisar"

    return (Invoke-WebRequest -Uri $url -Method Post -Body $body -UseBasicParsing -Headers $headers -TimeoutSec $TimeoutSeconds).Content
}

function Get-OfferCodeFromCodOferta([int]$CodOferta, [int]$TimeoutSeconds) {
    $url = "https://www.bep.gov.pt/pages/oferta/Oferta_Detalhes.aspx?CodOferta=$CodOferta"
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSeconds -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) BEP watcher"
        }
        $match = [regex]::Match($response.Content, "OE\d{6}/\d+")
        if ($match.Success) {
            return [pscustomobject]@{
                Code = $match.Value
                Url = $url
            }
        }
    } catch {
        return $null
    }

    return $null
}

function Resolve-BepDetailUrls($Offers, $Config) {
    $timeoutSeconds = [int]$Config.TimeoutSeconds
    $start = if ($Config.DetailCodOfertaStart) { [int]$Config.DetailCodOfertaStart } else { 151000 }
    $end = if ($Config.DetailCodOfertaEnd) { [int]$Config.DetailCodOfertaEnd } else { 153000 }
    $maxRequests = if ($Config.DetailCodOfertaMaxRequests) { [int]$Config.DetailCodOfertaMaxRequests } else { 800 }
    $scanned = 0

    $needed = @{}
    foreach ($offer in $Offers) {
        if (-not ($offer.Url -and $offer.Url.Contains("Oferta_Detalhes.aspx?CodOferta="))) {
            $needed[$offer.Code] = $offer
        }
    }
    if ($needed.Count -eq 0) { return }

    Write-Host "Resolving direct BEP detail links..."
    for ($codOferta = $start; $codOferta -le $end -and $needed.Count -gt 0 -and $scanned -lt $maxRequests; $codOferta++) {
        $scanned++
        $detail = Get-OfferCodeFromCodOferta -CodOferta $codOferta -TimeoutSeconds $timeoutSeconds
        if ($detail -and $needed.ContainsKey($detail.Code)) {
            $needed[$detail.Code].Url = $detail.Url
            $needed.Remove($detail.Code)
        }
    }

    if ($needed.Count -gt 0) {
        Write-Host "Could not resolve $($needed.Count) direct link(s) within lookup limit; using search page fallback."
    }
}

function Parse-BepOffers([string]$Html, [string]$SourceTerm, [string]$SearchUrl) {
    $offers = @()
    $tableMatch = [regex]::Match($Html, "<table[^>]+summary\s*=\s*[""']GvOfertaGestao[""'][\s\S]*?</table>", "IgnoreCase")
    if (-not $tableMatch.Success) {
        return $offers
    }

    foreach ($rowMatch in [regex]::Matches($tableMatch.Value, "<tr[^>]*>([\s\S]*?)</tr>", "IgnoreCase")) {
        $row = $rowMatch.Groups[1].Value
        if ($row -match "<th\b") { continue }

        $cells = @()
        foreach ($cellMatch in [regex]::Matches($row, "<td[^>]*>([\s\S]*?)</td>", "IgnoreCase")) {
            $cells += Convert-HtmlToText $cellMatch.Groups[1].Value
        }
        if ($cells.Count -lt 9) { continue }

        $codeMatch = [regex]::Match($row, ">(OE\d{6}/\d+)<", "IgnoreCase")
        $code = if ($codeMatch.Success) { $codeMatch.Groups[1].Value } else { $cells[0] }
        if ([string]::IsNullOrWhiteSpace($code)) { continue }

        $offers += [pscustomobject]@{
            Code = $code
            Type = $cells[1]
            Contract = $cells[2]
            Career = $cells[3]
            Category = $cells[4]
            District = $cells[5]
            Organization = $cells[6]
            Education = $cells[7]
            Deadline = $cells[8]
            SourceTerm = $SourceTerm
            Url = $SearchUrl
        }
    }

    return $offers
}

function Test-OfferMatches($Offer, [string[]]$IncludeTerms, [string[]]$ExcludeTerms) {
    $haystack = @(
        $Offer.Code, $Offer.Type, $Offer.Contract, $Offer.Career, $Offer.Category,
        $Offer.District, $Offer.Organization, $Offer.Education, $Offer.SourceTerm
    ) -join " "

    $haystack = $haystack.ToLowerInvariant()
    $includeOk = $false
    foreach ($term in $IncludeTerms) {
        if ($haystack.Contains($term.ToLowerInvariant())) {
            $includeOk = $true
            break
        }
    }
    if (-not $includeOk) { return $false }

    foreach ($term in $ExcludeTerms) {
        if ($haystack.Contains($term.ToLowerInvariant())) {
            return $false
        }
    }

    return $true
}

function Convert-ToHtmlText($Value) {
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-DistrictRank($District, $Config) {
    $districtText = if ($District) { ([string]$District).ToLowerInvariant() } else { "" }
    $priority = @($Config.DistrictPriority)

    for ($i = 0; $i -lt $priority.Count; $i++) {
        $item = ([string]$priority[$i]).ToLowerInvariant()
        if ($districtText.Contains($item)) {
            return $i
        }
    }

    if ($districtText.Contains("raa") -or $districtText.Contains("ram") -or $districtText.Contains("açores") -or $districtText.Contains("acores") -or $districtText.Contains("madeira")) {
        return 900
    }

    return 500
}

function Sort-OffersByLocation($Offers, $Config) {
    return @($Offers | Sort-Object `
        @{ Expression = { Get-DistrictRank -District $_.District -Config $Config }; Ascending = $true }, `
        @{ Expression = { $_.District }; Ascending = $true }, `
        @{ Expression = { $_.Deadline }; Ascending = $true }, `
        @{ Expression = { $_.Code }; Ascending = $true })
}

function New-OfferEmailHtml($Config, $Offers) {
    $title = if ($Config.Email.SubjectPrefix) { $Config.Email.SubjectPrefix } else { "[BEP] novas vagas" }
    $rows = @()

    foreach ($offer in $Offers) {
        $code = Convert-ToHtmlText $offer.Code
        $organization = Convert-ToHtmlText $offer.Organization
        $career = Convert-ToHtmlText $offer.Career
        $category = Convert-ToHtmlText $offer.Category
        $district = Convert-ToHtmlText $offer.District
        $deadline = Convert-ToHtmlText $offer.Deadline
        $sourceTerm = Convert-ToHtmlText $offer.SourceTerm
        $url = Convert-ToHtmlText $offer.Url

        $rows += @"
        <tr>
          <td style="padding:14px 16px;border-bottom:1px solid #e5e7eb;">
            <div style="font-size:15px;font-weight:700;color:#111827;margin-bottom:4px;">$code</div>
            <div style="font-size:14px;color:#374151;">$organization</div>
            <div style="font-size:13px;color:#6b7280;margin-top:4px;">$career / $category</div>
          </td>
          <td style="padding:14px 16px;border-bottom:1px solid #e5e7eb;font-size:14px;color:#111827;">$district</td>
          <td style="padding:14px 16px;border-bottom:1px solid #e5e7eb;font-size:14px;color:#111827;white-space:nowrap;">$deadline</td>
          <td style="padding:14px 16px;border-bottom:1px solid #e5e7eb;font-size:14px;">
            <a href="$url" style="color:#0f766e;font-weight:700;text-decoration:none;">Abrir vaga</a>
            <div style="font-size:12px;color:#9ca3af;margin-top:5px;">$sourceTerm</div>
          </td>
        </tr>
"@
    }

    $rowsHtml = $rows -join [Environment]::NewLine
    $safeTitle = Convert-ToHtmlText $title
    $count = $Offers.Count

    return @"
<!doctype html>
<html>
  <body style="margin:0;padding:0;background:#f3f4f6;font-family:Segoe UI,Arial,sans-serif;color:#111827;">
    <div style="max-width:920px;margin:0 auto;padding:24px;">
      <div style="background:#ffffff;border:1px solid #e5e7eb;border-radius:8px;overflow:hidden;">
        <div style="padding:22px 24px;background:#0f766e;color:#ffffff;">
          <div style="font-size:20px;font-weight:700;">$safeTitle</div>
          <div style="font-size:14px;margin-top:6px;opacity:.92;">$count nova(s) vaga(s) encontradas no BEP, ordenadas por proximidade a Viseu/Guarda.</div>
        </div>
        <table role="presentation" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:collapse;background:#ffffff;">
          <thead>
            <tr>
              <th align="left" style="padding:12px 16px;background:#f9fafb;border-bottom:1px solid #e5e7eb;font-size:12px;text-transform:uppercase;color:#6b7280;">Vaga</th>
              <th align="left" style="padding:12px 16px;background:#f9fafb;border-bottom:1px solid #e5e7eb;font-size:12px;text-transform:uppercase;color:#6b7280;">Distrito</th>
              <th align="left" style="padding:12px 16px;background:#f9fafb;border-bottom:1px solid #e5e7eb;font-size:12px;text-transform:uppercase;color:#6b7280;">Prazo</th>
              <th align="left" style="padding:12px 16px;background:#f9fafb;border-bottom:1px solid #e5e7eb;font-size:12px;text-transform:uppercase;color:#6b7280;">Link</th>
            </tr>
          </thead>
          <tbody>
$rowsHtml
          </tbody>
        </table>
      </div>
      <div style="font-size:12px;color:#6b7280;margin-top:12px;">Email automatico gerado pelo monitor BEP local.</div>
    </div>
  </body>
</html>
"@
}

function Send-OfferEmail($Config, $Offers) {
    if ($Offers.Count -eq 0) { return }

    $subjectPrefix = if ($Config.Email.SubjectPrefix) { $Config.Email.SubjectPrefix } else { "[BEP] nova(s) vaga(s)" }
    $subject = "${subjectPrefix}: $($Offers.Count) nova(s) vaga(s)"
    $lines = @(
        "Foram encontradas novas vagas no BEP:",
        ""
    )

    foreach ($offer in $Offers) {
        $lines += "Codigo: $($offer.Code)"
        $lines += "Organismo: $($offer.Organization)"
        $lines += "Carreira/Categoria: $($offer.Career) / $($offer.Category)"
        $lines += "Distrito: $($offer.District)"
        $lines += "Prazo: $($offer.Deadline)"
        $lines += "Pesquisa BEP: $($offer.Url)"
        $lines += ""
    }

    $mail = [System.Net.Mail.MailMessage]::new()
    $mail.From = $Config.Email.From
    foreach ($recipient in @($Config.Email.To)) {
        if (-not [string]::IsNullOrWhiteSpace($recipient)) {
            [void]$mail.To.Add($recipient)
        }
    }
    $mail.Subject = $subject
    $mail.Body = New-OfferEmailHtml -Config $Config -Offers $Offers
    $mail.IsBodyHtml = $true

    $client = [System.Net.Mail.SmtpClient]::new($Config.Email.SmtpHost, [int]$Config.Email.SmtpPort)
    $client.EnableSsl = [bool]$Config.Email.EnableSsl

    $password = $Config.Email.Password
    if (-not $password -and $Config.Email.PasswordEnv) {
        $password = [Environment]::GetEnvironmentVariable([string]$Config.Email.PasswordEnv, "User")
        if (-not $password) {
            $password = [Environment]::GetEnvironmentVariable([string]$Config.Email.PasswordEnv, "Process")
        }
    }

    if ($Config.Email.Username -and $password) {
        $client.Credentials = [System.Net.NetworkCredential]::new($Config.Email.Username, $password)
    }

    $client.Send($mail)
}

$config = Read-JsonFile $ConfigPath $null
if (-not $config) {
    throw "Config file not found. Copy config.example.json to config.json and fill in your email settings."
}

$statePath = if ($config.StatePath) { $config.StatePath } else { Join-Path $PSScriptRoot "bep-state.json" }
$state = Read-JsonFile $statePath ([pscustomobject]@{ Seen = @() })
$seen = @{}
foreach ($code in @($state.Seen)) {
    if ($code) { $seen[[string]$code] = $true }
}

$allOffers = @()
$searchUrl = "https://www.bep.gov.pt/pages/oferta/Oferta_Pesquisa_basica.aspx"
foreach ($term in @($config.SearchTerms)) {
    if ([string]::IsNullOrWhiteSpace($term)) { continue }
    Write-Host "Searching BEP for: $term"
    $html = Invoke-BepSearch -Term $term -TimeoutSeconds ([int]$config.TimeoutSeconds)
    $allOffers += Parse-BepOffers -Html $html -SourceTerm $term -SearchUrl $searchUrl
    Start-Sleep -Milliseconds ([int]$config.DelayBetweenSearchesMs)
}

$unique = @{}
foreach ($offer in $allOffers) {
    $unique[$offer.Code] = $offer
}

$newMatches = @()
foreach ($offer in $unique.Values) {
    if ($seen.ContainsKey($offer.Code)) { continue }
    if (Test-OfferMatches -Offer $offer -IncludeTerms @($config.IncludeTerms) -ExcludeTerms @($config.ExcludeTerms)) {
        $newMatches += $offer
    }
}

foreach ($offer in $unique.Values) {
    $seen[$offer.Code] = $true
}

$state = [pscustomobject]@{
    LastRun = (Get-Date).ToString("s")
    Seen = @($seen.Keys | Sort-Object)
}

if ($Prime) {
    Save-JsonFile -Path $statePath -Value $state
    Write-Host "Prime mode: marked $($unique.Count) current offer(s) as seen. No email sent."
    exit 0
}

if ($DryRun) {
    Write-Host "Dry run: $($newMatches.Count) new matching offer(s). No email sent and state not saved."
    $newMatches | Format-Table Code, Organization, Career, Category, District, Deadline -AutoSize
    exit 0
}

if ($newMatches.Count -gt 0) {
    Resolve-BepDetailUrls -Offers $newMatches -Config $config
    $newMatches = Sort-OffersByLocation -Offers $newMatches -Config $config
    Send-OfferEmail -Config $config -Offers $newMatches
    Write-Host "Sent email with $($newMatches.Count) new matching offer(s)."
} else {
    Write-Host "No new matching offers."
}

Save-JsonFile -Path $statePath -Value $state
