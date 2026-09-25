# TVRenamer.ps1

# Queries api.themoviedb.org for TV show ID then individual episode titles
[CmdletBinding()]
param(
    # Folder containing new downloads to process (searched recursively)
    [Parameter(Mandatory, Position = 0)]
    [string]$Source,

    # Library root; files are moved to <Show>\Season NN\ under here
    [Parameter(Mandatory, Position = 1)]
    [string]$Destination,

    # Show what would happen without prompting or moving anything
    [switch]$DryRun
)

if ("SecurityProtocol" -in [Net.ServicePointManager].GetProperties().Name) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# TMDb API key comes from the environment so it never lives in the repo. Set it once with:
#   [Environment]::SetEnvironmentVariable("TMDB_API_KEY", "<your key>", "User")
$APIKey = $env:TMDB_API_KEY
if ([string]::IsNullOrWhiteSpace($APIKey)) {
    Write-Error "TMDB_API_KEY environment variable is not set. See the comment at the top of TVRenamer.ps1."
    exit 1
}
foreach ($folder in @($Source, $Destination)) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        Write-Error "Folder not found: $folder"
        exit 1
    }
}
$ToBeProcessed = $Source.TrimEnd('\')
$TVSeries = $Destination.TrimEnd('\')

$requestCount = 0
try { Clear-Host } catch { }   # no console handle when run non-interactively

$seasonCache = @{}
$showCache = @{}

Function Remove-InvalidFileNameChars {
    param([string]$Name)
    # If the colon is between digits (time like 11:59), use a period. Otherwise use " -".
    $Name = ($Name -replace '(?<=\d):(?=\d)','.').Replace(":", " -")
    $invalidChars = [IO.Path]::GetInvalidFileNameChars() -join ''
    $re = "[{0}]" -f [RegEx]::Escape($invalidChars)
    return ($Name -replace $re)
}

Function Normalize-Title {
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) { return "" }

    # Drop apostrophes entirely (straight, curly, or backtick) so Don't == Dont == Don`t,
    # spell out ampersands so "Yes & Baby" == "Yes and Baby",
    # then strip remaining punctuation and collapse whitespace
    $t = $Title -replace '[''`‘’]',''
    $t = $t -replace '&',' and '
    $t = $t.ToLowerInvariant()
    $t = $t -replace '[^a-z0-9]+',' '  # keep alnum only
    $t = ($t -replace '\s+',' ').Trim()

    return $t
}

Function Get-ExpectedEpisodeTitle {
    param([string]$BaseName)

    # Strip everything up to and including S00E00, and optional second episode marker (E00 or -E00)
    $t = ($BaseName -replace '(?i)^.*s\d{2}e\d{2}((?:-e\d{2})|(?:e\d{2}))?[\.\s_-]*','').Trim()

    # Cut off common quality/source tokens and anything after
    $t = ($t -split '(?i)\b(2160p|1080p|720p|480p|uhd|hdr|dv|webrip|web[- ]dl|bdrip|bluray|x264|x265|h\.?264|h\.?265|hevc|aac|dts|proper|repack)\b')[0].Trim()

    # Drop a trailing unclosed bracket left behind by the cut above
    $t = ($t -replace '[\(\[\{][^\)\]\}]*$','').Trim()

    return ($t -replace '\.+',' ').Trim()
}

Function Digits-Only {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return (($Text -replace '[^\d]','') )
}

Function Invoke-TMDb {
    # Single choke point for every API call: counts requests, backs off when TMDb
    # rate limits us, retries transient failures, and returns $null for a genuine
    # 404 instead of throwing and killing the whole run.
    param(
        [string]$Uri,
        [int]$MaxRetries = 3
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {

        # Requests are limited to 40 every 10 seconds, so if we're getting near that then wait 10 secs to allow the timer to reset
        if ($script:requestCount -ge 39) {
            "Pausing for 10 seconds to avoid exceeding request limit.."
            Start-Sleep -Seconds 10
            $script:requestCount = 0
        }

        try {
            $script:requestCount++
            return Invoke-RestMethod $Uri -ErrorAction Stop
        } catch {
            $status = $null
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
            }

            if ($status -eq 404) { return $null }          # asked for something that doesn't exist
            if ($status -eq 401) {
                Write-Error "TMDb rejected the API key (401). Check the TMDB_API_KEY environment variable."
                return $null
            }

            if ($attempt -eq $MaxRetries) {
                Write-Warning "TMDb request failed after $MaxRetries attempts: $($_.Exception.Message)"
                return $null
            }

            if ($status -eq 429) {
                $script:requestCount = 0
                Start-Sleep -Seconds 10
            } else {
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }

    return $null
}

Function Get-ShowSearchInfo {
    # Turns the part of the filename before S00E00 into an ordered list of
    # candidate search terms plus the year, if the filename carries one.
    #
    # The old code did BaseName.Replace(".", " ") unconditionally, which turned
    # "11.22.63 (2016) - S01E01 - ..." into a search for "11 22 63 (2016) -" and
    # matched nothing. Dots are only separators when the name has no spaces.
    param([string]$Prefix)

    $raw = $Prefix.Trim()

    # Pull out a year in brackets or standing on its own, and remember it as a search hint
    $year = $null
    if ($raw -match '[\(\[](19|20)\d{2}[\)\]]') {
        $year = ($matches[0] -replace '[^\d]','')
    } elseif ($raw -match '(?:^|[\s\.\-_])((19|20)\d{2})(?:$|[\s\.\-_])') {
        $year = $matches[1]
    }

    $candidates = New-Object System.Collections.Generic.List[string]

    # Candidate 1: treat dots as separators only if the name looks dot-separated
    $primary = $raw
    if ($primary -notmatch '\s') { $primary = $primary.Replace(".", " ") }
    $candidates.Add($primary)

    # Candidate 2: the name exactly as written, in case the title itself contains
    # dots (11.22.63, S.W.A.T.) and the whole filename was dot-separated
    $candidates.Add($raw)

    $cleaned = New-Object System.Collections.Generic.List[string]
    foreach ($c in $candidates) {
        $t = $c
        $t = $t -replace '[\(\[](19|20)\d{2}[\)\]]',' '           # (2016)
        $t = $t -replace '(?:^|[\s\.\-_])((19|20)\d{2})\s*$',' '  # trailing bare year
        $t = $t -replace '[\s_]+',' '
        $t = $t.Trim()
        $t = $t -replace '^[\s\-_\.]+','' -replace '[\s\-_\.]+$',''   # strip leading/trailing separators
        $t = $t.Trim()

        if (-not [string]::IsNullOrWhiteSpace($t) -and -not $cleaned.Contains($t)) {
            $cleaned.Add($t)
        }
    }

    return [PSCustomObject]@{
        Candidates = $cleaned
        Year       = $year
    }
}

Function Resolve-Show {
    # Finds the TMDb show for a set of candidate names. Tries the year-filtered
    # search first, then unfiltered, and prefers an exact normalized title match
    # before falling back to TMDb's own top hit.
    param(
        [string[]]$Candidates,
        [string]$Year
    )

    foreach ($candidate in $Candidates) {

        $cacheKey = "$candidate|$Year"
        if ($showCache.ContainsKey($cacheKey)) {
            if ($showCache[$cacheKey]) { return $showCache[$cacheKey] }
            continue
        }

        $queries = @()
        if ($Year) {
            $queries += "https://api.themoviedb.org/3/search/tv?api_key=$APIKey&query=$([uri]::EscapeDataString($candidate))&first_air_date_year=$Year"
        }
        $queries += "https://api.themoviedb.org/3/search/tv?api_key=$APIKey&query=$([uri]::EscapeDataString($candidate))"

        foreach ($q in $queries) {
            $showResponse = Invoke-TMDb -Uri $q
            if (-not $showResponse -or $showResponse.results.Count -eq 0) { continue }

            $wanted = Normalize-Title $candidate

            # Exact match on the normalized title wins
            $showResult = $showResponse.results | Where-Object { (Normalize-Title $_.name) -eq $wanted } | Select-Object -First 1

            # Then a prefix match either way round
            if (-not $showResult) {
                $showResult = $showResponse.results | Where-Object {
                    $n = Normalize-Title $_.name
                    $n -and ($n -like "$wanted*" -or $wanted -like "$n*")
                } | Select-Object -First 1
            }

            # Otherwise trust TMDb's ranking
            if (-not $showResult) { $showResult = $showResponse.results[0] }

            if ($showResult) {
                $showCache[$cacheKey] = $showResult
                return $showResult
            }
        }

        $showCache[$cacheKey] = $null
    }

    return $null
}

# Get list of tv files to rename/move from base folder & size over 100mb
$tvFiles = Get-ChildItem -LiteralPath $ToBeProcessed -Recurse -File -ErrorAction Stop | Where-Object { $_.Length -gt 100MB }

if (-not $tvFiles) {
    Write-Warning "No files over 100MB found under $ToBeProcessed"
    if (-not $DryRun) { pause }
    return
}

# Create regular expression to split filename string at S00E00 - entire regex wrapped in brackets to retain the matched season/episode in the result
$regex = [regex]'(?i)s(\d\d)e(\d\d)'
$plannedActions = @()
$skipped = @()

foreach ($tvFile in $tvFiles) {

    "-"*100
    "File: $($tvFile.FullName)"

    # Split filename into 4 elements - Name, Season, Episode, rest of the string (not needed)
    $splitTv = $regex.Split($tvFile.BaseName)

    if ($splitTv.Count -lt 3) {
        Write-Warning "No S00E00 marker in $($tvFile.Name). Skipping."
        $skipped += "$($tvFile.Name) - no S00E00 marker"
        continue
    }

    $season  = $splitTv[1].Trim()
    $episode = $splitTv[2].Trim()
    $rejectedTitle = $null

    $searchInfo = Get-ShowSearchInfo -Prefix $splitTv[0]

    if ($searchInfo.Candidates.Count -eq 0) {
        Write-Warning "Could not work out a show name from $($tvFile.Name). Skipping."
        $skipped += "$($tvFile.Name) - unparsable show name"
        continue
    }

    $yearNote = ""
    if ($searchInfo.Year) { $yearNote = " (year $($searchInfo.Year))" }
    "Searching: $($searchInfo.Candidates -join ' | ')$yearNote"

    $showResult = Resolve-Show -Candidates $searchInfo.Candidates -Year $searchInfo.Year

    if (-not $showResult) {
        Write-Warning "No show results for $($tvFile.Name)"
        $skipped += "$($tvFile.Name) - show not found on TMDb"
        continue
    }

    $showID = $showResult.id
    $expectedTitle = Get-ExpectedEpisodeTitle -BaseName $tvFile.BaseName

    $episodeURI = "https://api.themoviedb.org/3/tv/$showID/season/$season/episode/$($episode)?api_key=$APIKey"
    $episodeResponse = Invoke-TMDb -Uri $episodeURI

    # If TMDb title doesn't match what the filename claims, match by title within the season and use TMDb's episode_number
    if ($episodeResponse -and $expectedTitle) {
        $tmdbTitleNorm = Normalize-Title $episodeResponse.name
        $expectedNorm  = Normalize-Title $expectedTitle

        $tmdbDigits     = Digits-Only $episodeResponse.name
        $expectedDigits = Digits-Only $expectedTitle

        if (-not (
            $tmdbTitleNorm -like "$expectedNorm*" -or
            $expectedNorm -like "$tmdbTitleNorm*" -or
            ($tmdbDigits -and $expectedDigits -and $tmdbDigits -eq $expectedDigits)
        )) {
            $rejectedTitle = $episodeResponse.name
            $episodeResponse = $null
        }
    }

    if (-not $episodeResponse -and $expectedTitle) {
        $cacheKey = "$showID|$season"
        if (-not $seasonCache.ContainsKey($cacheKey)) {
            $seasonURI = "https://api.themoviedb.org/3/tv/$showID/season/$($season)?api_key=$APIKey"
            $seasonCache[$cacheKey] = Invoke-TMDb -Uri $seasonURI
        }

        $seasonData = $seasonCache[$cacheKey]
        $expectedNorm   = Normalize-Title $expectedTitle
        $expectedDigits = Digits-Only $expectedTitle

        $match = $null
        if ($seasonData) {
            $match = $seasonData.episodes | Where-Object {
                $n = Normalize-Title $_.name
                $d = Digits-Only $_.name
                ($n -like "$expectedNorm*" -or $expectedNorm -like "$n*" -or ($d -and $expectedDigits -and $d -eq $expectedDigits))
            } | Select-Object -First 1
        }

        if ($match) {
            $episode = "{0:D2}" -f [int]$match.episode_number
            $episodeResponse = Invoke-TMDb -Uri "https://api.themoviedb.org/3/tv/$showID/season/$season/episode/$($episode)?api_key=$APIKey"
        }
    }

    if (-not $episodeResponse -or [string]::IsNullOrWhiteSpace($episodeResponse.name)) {
        $why = "TMDb has no S$($season)E$($episode) for '$($showResult.name)'"
        if ($rejectedTitle) { $why = "filename says '$expectedTitle' but TMDb S$($season)E$($episode) is '$rejectedTitle', and no other episode in the season matched" }
        Write-Warning "No episode title resolved for $($tvFile.Name): $why. Skipping."
        $skipped += "$($tvFile.Name) - $why"
        continue
    }

    $safeShow = Remove-InvalidFileNameChars($showResult.name)
    $newName = "$safeShow - S$($season)E$($episode) - $(Remove-InvalidFileNameChars($episodeResponse.name))$($tvFile.Extension)"
    $targetDir = "$TVSeries\$safeShow\Season $season"
    $targetPath = Join-Path $targetDir $newName

    # Don't queue something that would overwrite an existing file or collide with another queued move
    if (Test-Path -LiteralPath $targetPath) {
        Write-Warning "Target already exists, skipping: $targetPath"
        $skipped += "$($tvFile.Name) - target already exists"
        continue
    }
    if ($plannedActions.NewPath -contains $targetPath) {
        Write-Warning "Two files both want to become $targetPath. Skipping $($tvFile.Name)."
        $skipped += "$($tvFile.Name) - duplicate target"
        continue
    }

    $plannedActions += [PSCustomObject]@{
        OriginalPath = $tvFile.FullName
        NewPath      = $targetPath
        TargetFolder = $targetDir
        FileObject   = $tvFile
    }

    "Old name: $($tvFile.Name)"
    "New name: $newName"
}

"-"*100
"Matched: $($plannedActions.Count)   Skipped: $($skipped.Count)   API requests: $requestCount"
if ($skipped.Count -gt 0) {
    "Skipped files:"
    $skipped | ForEach-Object { "  - $_" }
}

if ($plannedActions.Count -eq 0) {
    Write-Warning "No valid rename operations were prepared."
    if (-not $DryRun) { pause }
    return
}

if ($DryRun) {
    "`nDry run - nothing was moved."
    return
}

$response = Read-Host "`nDoes this look okay? Type Y to proceed, anything else to cancel"
if ($response -match '^[Yy]$') {
    foreach ($action in $plannedActions) {
        if (!(Test-Path -LiteralPath $action.TargetFolder)) {
            New-Item $action.TargetFolder -ItemType Directory -Force | Out-Null
        }
        try {
            $action.FileObject.MoveTo($action.NewPath)
            Write-Host "Moved: $($action.OriginalPath) -> $($action.NewPath)"
        } catch {
            Write-Warning "Failed to move: $($action.OriginalPath) - $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $plannedActions[0].TargetFolder) {
        Invoke-Item $plannedActions[0].TargetFolder
    }
} else {
    Write-Host "No changes made. Exiting."
}
pause
