# PSScriptAnalyzer settings for iis-deploy-kit (used by CI: Invoke-ScriptAnalyzer -Settings).
# Every excluded rule is a deliberate choice, explained below.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive operator scripts: colored, human-readable console output is the point.
        # Nothing parses their output; secrets are never written.
        'PSAvoidUsingWriteHost',
        # Internal helpers (Remove-OldReleases, Set-DeployKitSitePath, ...) are not exposed as
        # cmdlets; the scripts have explicit verification modes instead (-CheckOnly, -VerifyOnly,
        # -TestOnly).
        'PSUseShouldProcessForStateChangingFunctions',
        # Names such as Get-DeployKitSettings / Copy-DeployKitScripts read better in plural.
        'PSUseSingularNouns',
        # Generated secrets are handed to native tools (psql, pg_dump, the EF bundle) through a
        # process environment variable. A SecureString would be converted back to plain text
        # immediately and adds no protection here.
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUsernameAndPasswordParams',
        # False positive: the parameters are used inside a MatchEvaluator script block.
        'PSReviewUnusedParameter'
    )
}
