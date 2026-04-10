Get-Module Cicada -All | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module "$PSScriptRoot\..\Cicada.psd1" -Force

Describe 'Get-CicadaFunFact' {
    It 'returns a non-empty string' {
        InModuleScope Cicada {
            $fact = Get-CicadaFunFact
            $fact | Should Not BeNullOrEmpty
        }
    }

    It 'returns a string type' {
        InModuleScope Cicada {
            $fact = Get-CicadaFunFact
            $fact.GetType().Name | Should Be 'String'
        }
    }

    It 'returns a fact from the known list' {
        InModuleScope Cicada {
            $knownFragments = @(
                'prime numbers'
                '100 decibels'
                'every continent'
                '3,000 known species'
                'do not bite'
                'tree cricket'
                'tymbals'
                '1700s'
                'hollow shell'
                'Ancient Greeks'
                '8 mph'
                'billions'
            )

            $fact = Get-CicadaFunFact
            $matched = $false
            foreach ($fragment in $knownFragments) {
                if ($fact -match [regex]::Escape($fragment)) {
                    $matched = $true
                    break
                }
            }
            $matched | Should Be $true
        }
    }

    It 'produces varying results over multiple calls' {
        InModuleScope Cicada {
            $results = 1..20 | ForEach-Object { Get-CicadaFunFact }
            $unique = $results | Sort-Object -Unique
            $unique.Count | Should BeGreaterThan 1
        }
    }
}
