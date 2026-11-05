$tmp = Join-Path $env:TEMP 'psmcp_test'
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $tmp | Out-Null
function C($id, $n, $a) { @{ jsonrpc = '2.0'; id = $id; method = 'tools/call'; params = @{ name = $n; arguments = $a } } | ConvertTo-Json -Depth 9 -Compress }
$in = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    C 3 dir_create @{ path = 'a/b' }
    C 4 file_create @{ path = 'a/b/x.txt'; content = 'héllo' }
    C 5 file_update @{ path = 'a/b/x.txt'; content = ' world'; append = $true }
    C 6 file_read @{ path = 'a/b/x.txt' }
    C 7 dir_list @{ recursive = $true }
    C 8 file_read @{ path = '..\..\Windows\win.ini' }
    C 9 dir_delete @{ path = 'a' }
    C 10 file_delete @{ path = 'a/b/x.txt' }
    C 11 dir_delete @{ path = 'a'; recursive = $true }
    C 12 dir_list @{}
)
$in | pwsh -NoProfile -File (Join-Path $PSScriptRoot 'PSMCP.ps1') -Root $tmp | ForEach-Object { if ($_.Length -gt 300) { $_.Substring(0, 300) + '...' } else { $_ } }
