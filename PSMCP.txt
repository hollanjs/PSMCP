#Requires -Version 7.0
<#
  Minimal MCP server (stdio, newline-delimited JSON-RPC 2.0) in pure PowerShell.
  File CRUD + directory management, sandboxed to a root directory.
  Root: env PSMCP_ROOT, or the -Root parameter, or the current directory.
#>
param([string]$Root = $(if ($env:PSMCP_ROOT) { $env:PSMCP_ROOT } else { (Get-Location).Path }))

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$stdout = [System.IO.StreamWriter]::new([Console]::OpenStandardOutput(), $utf8)
$stdout.AutoFlush = $true
$stdin = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8)

$RootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
$ProtocolVersion = '2025-06-18'

function Send($obj) { $stdout.WriteLine(($obj | ConvertTo-Json -Depth 20 -Compress)) }
function Log($msg) { [Console]::Error.WriteLine("[PSMCP] $msg") }

# Resolve a user path inside the root; throws if it escapes.
function Resolve-SafePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path is required' }
    $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RootFull, $Path))
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    if (-not ($full.Equals($RootFull, $cmp) -or $full.StartsWith($RootFull + [System.IO.Path]::DirectorySeparatorChar, $cmp))) {
        throw "Path '$Path' is outside the allowed root '$RootFull'"
    }
    $full
}

function Rel([string]$Full) {
    if ($Full.Equals($RootFull, 'OrdinalIgnoreCase')) { return '.' }
    $Full.Substring($RootFull.Length + 1)
}

function Schema($props, $required = @()) {
    @{ type = 'object'; properties = $props; required = @($required) }
}
$S = { param($d) @{ type = 'string'; description = $d } }
$B = { param($d) @{ type = 'boolean'; description = $d } }

$Tools = @(
    @{ name = 'file_create'; description = 'Create a new file (fails if it exists unless overwrite=true).'
       inputSchema = Schema @{ path = & $S 'File path relative to root'; content = & $S 'File content'; overwrite = & $B 'Overwrite if exists' } @('path', 'content') }
    @{ name = 'file_read'; description = 'Read a text file.'
       inputSchema = Schema @{ path = & $S 'File path relative to root' } @('path') }
    @{ name = 'file_update'; description = 'Replace the content of an existing file, or append to it.'
       inputSchema = Schema @{ path = & $S 'File path relative to root'; content = & $S 'New content'; append = & $B 'Append instead of replace' } @('path', 'content') }
    @{ name = 'file_delete'; description = 'Delete a file.'
       inputSchema = Schema @{ path = & $S 'File path relative to root' } @('path') }
    @{ name = 'file_move'; description = 'Move or rename a file or directory.'
       inputSchema = Schema @{ source = & $S 'Source path'; destination = & $S 'Destination path' } @('source', 'destination') }
    @{ name = 'file_copy'; description = 'Copy a file or directory.'
       inputSchema = Schema @{ source = & $S 'Source path'; destination = & $S 'Destination path' } @('source', 'destination') }
    @{ name = 'dir_create'; description = 'Create a directory (including parents).'
       inputSchema = Schema @{ path = & $S 'Directory path relative to root' } @('path') }
    @{ name = 'dir_list'; description = 'List directory contents.'
       inputSchema = Schema @{ path = & $S 'Directory path (default ".")'; recursive = & $B 'Recurse into subdirectories' } @() }
    @{ name = 'dir_delete'; description = 'Delete a directory (non-empty requires recursive=true).'
       inputSchema = Schema @{ path = & $S 'Directory path relative to root'; recursive = & $B 'Delete contents too' } @('path') }
)

function Get-Bool($a, $name) { [bool]($a.ContainsKey($name) -and $a[$name]) }

function Invoke-Tool([string]$Name, [hashtable]$a) {
    switch ($Name) {
        'file_create' {
            $p = Resolve-SafePath $a.path
            if ((Test-Path -LiteralPath $p) -and -not (Get-Bool $a 'overwrite')) { throw "File already exists: $($a.path)" }
            if (Test-Path -LiteralPath $p -PathType Container) { throw "Path is a directory: $($a.path)" }
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent)
            [System.IO.File]::WriteAllText($p, [string]$a.content, $utf8)
            "Created $(Rel $p)"
        }
        'file_read' {
            $p = Resolve-SafePath $a.path
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "File not found: $($a.path)" }
            [System.IO.File]::ReadAllText($p, $utf8)
        }
        'file_update' {
            $p = Resolve-SafePath $a.path
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "File not found: $($a.path)" }
            if (Get-Bool $a 'append') { [System.IO.File]::AppendAllText($p, [string]$a.content, $utf8); "Appended to $(Rel $p)" }
            else { [System.IO.File]::WriteAllText($p, [string]$a.content, $utf8); "Updated $(Rel $p)" }
        }
        'file_delete' {
            $p = Resolve-SafePath $a.path
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "File not found: $($a.path)" }
            Remove-Item -LiteralPath $p -Force
            "Deleted $(Rel $p)"
        }
        'file_move' {
            $s = Resolve-SafePath $a.source; $d = Resolve-SafePath $a.destination
            if (-not (Test-Path -LiteralPath $s)) { throw "Source not found: $($a.source)" }
            if (Test-Path -LiteralPath $d) { throw "Destination exists: $($a.destination)" }
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $d -Parent)
            Move-Item -LiteralPath $s -Destination $d
            "Moved $(Rel $s) -> $(Rel $d)"
        }
        'file_copy' {
            $s = Resolve-SafePath $a.source; $d = Resolve-SafePath $a.destination
            if (-not (Test-Path -LiteralPath $s)) { throw "Source not found: $($a.source)" }
            if (Test-Path -LiteralPath $d) { throw "Destination exists: $($a.destination)" }
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $d -Parent)
            Copy-Item -LiteralPath $s -Destination $d -Recurse
            "Copied $(Rel $s) -> $(Rel $d)"
        }
        'dir_create' {
            $p = Resolve-SafePath $a.path
            if (Test-Path -LiteralPath $p -PathType Leaf) { throw "A file exists at: $($a.path)" }
            $null = New-Item -ItemType Directory -Force -Path $p
            "Created directory $(Rel $p)"
        }
        'dir_list' {
            $p = Resolve-SafePath $(if ($a.path) { $a.path } else { '.' })
            if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw "Directory not found: $($a.path)" }
            $items = Get-ChildItem -LiteralPath $p -Force -Recurse:(Get-Bool $a 'recursive')
            $lines = foreach ($i in $items) {
                if ($i.PSIsContainer) { "[dir]  $(Rel $i.FullName)" } else { "[file] $(Rel $i.FullName) ($($i.Length) bytes)" }
            }
            if ($lines) { $lines -join "`n" } else { '(empty)' }
        }
        'dir_delete' {
            $p = Resolve-SafePath $a.path
            if ($p.Equals($RootFull, 'OrdinalIgnoreCase')) { throw 'Refusing to delete the root directory' }
            if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw "Directory not found: $($a.path)" }
            if (-not (Get-Bool $a 'recursive') -and (Get-ChildItem -LiteralPath $p -Force | Select-Object -First 1)) {
                throw 'Directory not empty; set recursive=true'
            }
            Remove-Item -LiteralPath $p -Recurse -Force
            "Deleted directory $(Rel $p)"
        }
        default { throw "Unknown tool: $Name" }
    }
}

function ConvertTo-Hashtable($o) { if ($null -eq $o) { @{} } else { $o | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable } }

Log "Started. Root: $RootFull"
while ($null -ne ($line = $stdin.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $id = $null
    try {
        $msg = $line | ConvertFrom-Json -AsHashtable
        $id = $msg['id']
        $method = $msg['method']
        $isRequest = $msg.ContainsKey('id') -and $method

        switch ($method) {
            'initialize' {
                Send @{ jsonrpc = '2.0'; id = $id; result = @{
                    protocolVersion = $ProtocolVersion
                    capabilities = @{ tools = @{ listChanged = $false } }
                    serverInfo = @{ name = 'PSMCP'; version = '1.0.0' } } }
            }
            'ping' { Send @{ jsonrpc = '2.0'; id = $id; result = @{} } }
            'tools/list' { Send @{ jsonrpc = '2.0'; id = $id; result = @{ tools = $Tools } } }
            'tools/call' {
                $p = $msg['params']
                try {
                    $text = Invoke-Tool $p['name'] (ConvertTo-Hashtable $p['arguments'])
                    $res = @{ content = @(@{ type = 'text'; text = [string]$text }); isError = $false }
                } catch {
                    $res = @{ content = @(@{ type = 'text'; text = $_.Exception.Message }); isError = $true }
                }
                Send @{ jsonrpc = '2.0'; id = $id; result = $res }
            }
            default {
                if ($isRequest) {
                    Send @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32601; message = "Method not found: $method" } }
                }
            }
        }
    } catch {
        Log "Error: $($_.Exception.Message)"
        if ($null -ne $id) { Send @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32603; message = $_.Exception.Message } } }
    }
}
