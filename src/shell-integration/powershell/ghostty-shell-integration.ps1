# Ghostty Shell Integration for PowerShell
#
# This script provides terminal integration features when running inside
# Ghostty. It is automatically sourced when shell-integration is enabled.
#
# Features (controlled by $env:GHOSTTY_SHELL_FEATURES):
#   - Semantic prompt marking (OSC 133)
#   - Current working directory reporting (OSC 7)
#   - Window title updates (OSC 2)
#   - Cursor shape changes at prompt

if (-not $env:GHOSTTY_SHELL_FEATURES) { return }

$GhosttyFeatures = $env:GHOSTTY_SHELL_FEATURES -split ','

# Save the original prompt function so we can call it.
if (Test-Path Function:\prompt) {
    $Function:__ghostty_original_prompt = $Function:prompt
} else {
    function __ghostty_original_prompt { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
}

# Track prompt state for OSC 133 sequencing.
$Script:__ghostty_prompt_state = 'initial'

function prompt {
    # Capture exit code before anything else can clobber it.
    $realLASTEXITCODE = $global:LASTEXITCODE
    $cmdSuccess = $?

    # OSC 133;D — end of previous command output (with exit status).
    # Skip on the very first prompt (no command has run yet).
    if ($Script:__ghostty_prompt_state -ne 'initial') {
        $exitCode = if ($cmdSuccess) { 0 } else { if ($realLASTEXITCODE) { $realLASTEXITCODE } else { 1 } }
        [Console]::Write("`e]133;D;$exitCode`a")
    }

    # OSC 133;A — fresh line / new prompt.
    [Console]::Write("`e]133;A`a")

    # Cursor shape: blinking bar at prompt (if cursor feature enabled).
    if ($GhosttyFeatures -contains 'cursor') {
        [Console]::Write("`e[5 q")
    }

    # OSC 7 — report current working directory as a file:// URI.
    #
    # The host component is $env:COMPUTERNAME (the same value Ghostty's
    # local-hostname validation compares against, via GetComputerName).
    # Each path segment is percent-encoded with [uri]::EscapeDataString
    # so spaces and non-ASCII characters survive URI parsing; backslashes
    # become '/' separators. UNC paths (\\server\share) are emitted as
    # file://server/share, which Ghostty converts back to a UNC path.
    $loc = Get-Location
    if ($loc.Provider.Name -eq 'FileSystem') {
        $segments = ($loc.ProviderPath -replace '\\', '/') -split '/'
        $escaped = ($segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        if ($escaped.StartsWith('//')) {
            # UNC path: //server/share/... -> file://server/share/...
            [Console]::Write("`e]7;file:$escaped`a")
        } else {
            [Console]::Write("`e]7;file://$env:COMPUTERNAME/$escaped`a")
        }
    } else {
        # Non-filesystem provider (registry, cert store, ...): report an
        # empty pwd so the terminal resets any stale value.
        [Console]::Write("`e]7;`a")
    }

    # OSC 2 — window title (current directory).
    if ($GhosttyFeatures -contains 'title') {
        $leaf = Split-Path -Leaf (Get-Location)
        [Console]::Write("`e]2;$leaf`a")
    }

    # Call the original prompt to get the prompt string.
    $promptText = __ghostty_original_prompt

    # OSC 133;B — end of prompt, start of user input.
    [Console]::Write("`e]133;B`a")

    $Script:__ghostty_prompt_state = 'prompt-end'

    # Restore LASTEXITCODE so the user sees the real value.
    $global:LASTEXITCODE = $realLASTEXITCODE

    return $promptText
}

# PSReadLine key handler to emit OSC 133;C when Enter is pressed
# (marks end of input, start of command output).
if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
        # OSC 133;C — end of input, start of output.
        [Console]::Write("`e]133;C`a")

        # Reset cursor to default shape before command runs.
        if ($GhosttyFeatures -contains 'cursor') {
            [Console]::Write("`e[0 q")
        }

        $Script:__ghostty_prompt_state = 'pre-exec'

        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
}

# TODO(ssh): port the upstream `ghostty +ssh` integration once the CLI
# lands in this fork. Upstream replaced the per-shell ssh wrapper
# functions (the ssh-env/ssh-terminfo logic still present in our
# bash/zsh scripts, which talk to `ghostty +ssh-cache`) with a single
# `ghostty +ssh` CLI action (upstream src/cli/ssh.zig) that handles
# TERM fallback, env propagation, and terminfo installation itself.
# That CLI does not exist at this fork's base commit, so there is
# nothing to invoke yet. When it lands, gate on
# $env:GHOSTTY_SHELL_FEATURES containing 'ssh-env'/'ssh-terminfo' and
# define an ssh function that delegates, mirroring the bash/zsh
# pattern, e.g.:
#
#   if ($GhosttyFeatures -match 'ssh-') {
#       function ssh { & (Join-Path $env:GHOSTTY_BIN_DIR 'ghostty.exe') +ssh @args }
#   }
#
# Do not vendor the old wrapper logic; wait for the CLI.

# Clean up the integration env vars (don't leak to child processes).
Remove-Item Env:GHOSTTY_SHELL_INTEGRATION_XDG_DIR -ErrorAction SilentlyContinue
