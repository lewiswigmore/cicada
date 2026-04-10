# Comprehensive Pester tests for the Get-CicadaFunFact feature (Issue #1)
# Covers: return types, exact value matching, array integrity, randomness,
#         distribution, integration with Show-CicadaHelp, and edge cases.

Get-Module Cicada -All | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module "$PSScriptRoot\..\Cicada.psd1" -Force

# Canonical list — must stay in sync with Get-CicadaFunFact in Cicada.psm1
$script:ExpectedFacts = @(
    'Periodical cicadas spend 13 or 17 years underground before emerging — both prime numbers.'
    'A cicada chorus can reach 100 decibels, as loud as a lawnmower.'
    'Cicadas are found on every continent except Antarctica.'
    'There are over 3,000 known species of cicada worldwide.'
    'Cicadas do not bite or sting — they are harmless to humans.'
    'The word "cicada" comes directly from Latin, where Romans used it to describe the insect and its song.'
    'Cicadas vibrate drum-like organs called tymbals to produce their song.'
    'Some cicada broods have been tracked since the 1700s.'
    'Cicadas molt their exoskeleton and leave behind a perfect hollow shell.'
    'Ancient Greeks kept cicadas in cages to enjoy their song.'
    'Cicadas can fly up to 8 mph despite their clumsy appearance.'
    'A single cicada emergence can number in the billions.'
    'Male cicadas are the singers — females are silent and respond by flicking their wings.'
    'Cicadas feed exclusively on xylem sap from tree roots, essentially drinking diluted tree water.'
    'After 17 years underground, adult cicadas live only 4 to 6 weeks above ground.'
)

# ── Unit tests: Get-CicadaFunFact ──────────────────────────────────────

Describe 'Get-CicadaFunFact' {

    It 'returns a non-empty string' {
        InModuleScope Cicada {
            $fact = Get-CicadaFunFact
            $fact | Should Not BeNullOrEmpty
        }
    }

    It 'returns a [string] type' {
        InModuleScope Cicada {
            $fact = Get-CicadaFunFact
            $fact | Should BeOfType [string]
        }
    }

    It 'returns an exact match from the known facts list' {
        InModuleScope Cicada {
            $expected = @(
                'Periodical cicadas spend 13 or 17 years underground before emerging — both prime numbers.'
                'A cicada chorus can reach 100 decibels, as loud as a lawnmower.'
                'Cicadas are found on every continent except Antarctica.'
                'There are over 3,000 known species of cicada worldwide.'
                'Cicadas do not bite or sting — they are harmless to humans.'
                'The word "cicada" comes directly from Latin, where Romans used it to describe the insect and its song.'
                'Cicadas vibrate drum-like organs called tymbals to produce their song.'
                'Some cicada broods have been tracked since the 1700s.'
                'Cicadas molt their exoskeleton and leave behind a perfect hollow shell.'
                'Ancient Greeks kept cicadas in cages to enjoy their song.'
                'Cicadas can fly up to 8 mph despite their clumsy appearance.'
                'A single cicada emergence can number in the billions.'
                'Male cicadas are the singers — females are silent and respond by flicking their wings.'
                'Cicadas feed exclusively on xylem sap from tree roots, essentially drinking diluted tree water.'
                'After 17 years underground, adult cicadas live only 4 to 6 weeks above ground.'
            )
            $fact = Get-CicadaFunFact
            ($fact -in $expected) | Should Be $true
        }
    }

    It 'never returns a value outside the known list (100 samples)' {
        InModuleScope Cicada {
            $expected = @(
                'Periodical cicadas spend 13 or 17 years underground before emerging — both prime numbers.'
                'A cicada chorus can reach 100 decibels, as loud as a lawnmower.'
                'Cicadas are found on every continent except Antarctica.'
                'There are over 3,000 known species of cicada worldwide.'
                'Cicadas do not bite or sting — they are harmless to humans.'
                'The word "cicada" comes directly from Latin, where Romans used it to describe the insect and its song.'
                'Cicadas vibrate drum-like organs called tymbals to produce their song.'
                'Some cicada broods have been tracked since the 1700s.'
                'Cicadas molt their exoskeleton and leave behind a perfect hollow shell.'
                'Ancient Greeks kept cicadas in cages to enjoy their song.'
                'Cicadas can fly up to 8 mph despite their clumsy appearance.'
                'A single cicada emergence can number in the billions.'
                'Male cicadas are the singers — females are silent and respond by flicking their wings.'
                'Cicadas feed exclusively on xylem sap from tree roots, essentially drinking diluted tree water.'
                'After 17 years underground, adult cicadas live only 4 to 6 weeks above ground.'
            )
            $outliers = @()
            1..100 | ForEach-Object {
                $f = Get-CicadaFunFact
                if ($f -notin $expected) { $outliers += $f }
            }
            $outliers.Count | Should Be 0
        }
    }

    It 'produces more than one unique result over 50 calls (randomness)' {
        InModuleScope Cicada {
            $results = 1..50 | ForEach-Object { Get-CicadaFunFact }
            $unique = $results | Sort-Object -Unique
            $unique.Count | Should BeGreaterThan 1
        }
    }

    It 'reaches at least half the facts over 200 calls (distribution)' {
        InModuleScope Cicada {
            $results = 1..200 | ForEach-Object { Get-CicadaFunFact }
            $unique = $results | Sort-Object -Unique
            # 15 facts, 200 draws: expected unique ~ 15; >= 7 is safe threshold
            $unique.Count | Should BeGreaterThan 6
        }
    }

    It 'does not throw on rapid sequential invocation' {
        InModuleScope Cicada {
            { 1..50 | ForEach-Object { Get-CicadaFunFact } } | Should Not Throw
        }
    }

    It 'returns a single string, not an array' {
        InModuleScope Cicada {
            $fact = Get-CicadaFunFact
            # If the function accidentally returned multiple items, .Count > 1
            @($fact).Count | Should Be 1
        }
    }
}

# ── Facts array integrity ───────────────────────────────────────────────

Describe 'Fun facts array integrity' {

    It 'contains exactly 15 facts' {
        $script:ExpectedFacts.Count | Should Be 15
    }

    It 'has no duplicate entries' {
        $unique = $script:ExpectedFacts | Sort-Object -Unique
        $unique.Count | Should Be $script:ExpectedFacts.Count
    }

    It 'has no empty or whitespace-only entries' {
        foreach ($f in $script:ExpectedFacts) {
            [string]::IsNullOrWhiteSpace($f) | Should Be $false
        }
    }

    It 'every fact ends with proper punctuation' {
        foreach ($f in $script:ExpectedFacts) {
            # Accept period, exclamation, question mark, or closing quote
            $f[-1] | Should Match '[.!?"]'
        }
    }

    It 'every fact contains the word cicada (case-insensitive)' {
        foreach ($f in $script:ExpectedFacts) {
            $f | Should Match '(?i)cicada'
        }
    }
}

# ── Integration: Show-CicadaHelp includes a fun fact ────────────────────

Describe 'Show-CicadaHelp fun fact integration' {

    It 'outputs the "Did you know?" line' {
        InModuleScope Cicada {
            $output = Show-CicadaHelp 6>&1 | Out-String
            $output | Should Match 'Did you know\?'
        }
    }

    It 'the "Did you know?" line contains actual fact text after the prefix' {
        InModuleScope Cicada {
            $output = Show-CicadaHelp 6>&1 | Out-String
            $lines = $output -split "`n"
            $factLine = $lines | Where-Object { $_ -match 'Did you know\?' } | Select-Object -First 1
            $factLine | Should Not BeNullOrEmpty

            # Strip the prefix and check remaining text is non-empty
            $afterPrefix = $factLine -replace '.*Did you know\?\s*', ''
            $afterPrefix.Trim().Length | Should BeGreaterThan 0
        }
    }
}
