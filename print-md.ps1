param(
    [string]$FilePath = "",
    [switch]$NoBrowser,
    [switch]$InstallDeps
)

# ---- Platform detection ----
$script:isWin = $false
$script:isMac = $false
if ($env:OS -and $env:OS -match "Windows") { $script:isWin = $true }
elseif ($IsMacOS -or (uname 2>$null) -match "Darwin") { $script:isMac = $true }

# ---- File dialog to select markdown file ----
if (-not $FilePath) {
    if ($script:isWin) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = "Select a Markdown file to print"
        $dialog.Filter = "Markdown Files (*.md;*.markdown;*.mdown)|*.md;*.markdown;*.mdown|All Files (*.*)|*.*"
        $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
        if ($dialog.ShowDialog() -eq 'Cancel') { Write-Host "Cancelled."; exit }
        $FilePath = $dialog.FileName
    } elseif ($script:isMac) {
        $result = & osascript -e 'set f to choose file with prompt "Select a Markdown file to print" default location (path to desktop)' -e 'POSIX path of f' 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $result) { Write-Host "Cancelled."; exit }
        $FilePath = $result.Trim()
    } else {
        $FilePath = Read-Host "Enter path to Markdown file"
    }
}

if (-not (Test-Path $FilePath)) { Write-Error "File not found: $FilePath"; exit 1 }
$FilePath = (Resolve-Path $FilePath).Path

# ---- Check for Node.js ----
$nodePath = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodePath) {
    Write-Error "Node.js is required but not found. Install from https://nodejs.org"
    exit 1
}

# ---- Temp directory (cross-platform) ----
if ($script:isWin) { $tmpBase = $env:TEMP } else { $tmpBase = "/tmp" }
$tmpDir = Join-Path $tmpBase "Print-Markdown"
$null = New-Item -ItemType Directory -Path $tmpDir -Force

$modulesDir = Join-Path $tmpDir "node_modules"
$pkgPath = Join-Path $tmpDir "package.json"

if ($InstallDeps -or -not (Test-Path $modulesDir)) {
    Write-Host "Installing Node.js dependencies (marked, highlight.js)..." -ForegroundColor Cyan
    @'
{ "name": "print-markdown", "private": true, "dependencies": { "marked": "^15.0.7", "highlight.js": "^11.11.0" } }
'@ | Set-Content -Path $pkgPath -Encoding ASCII
    Push-Location $tmpDir
    npm install --no-audit --no-fund --loglevel=error 2>&1 | Out-Null
    Pop-Location
}

# ---- Node.js render script using lexer/parser (matching vsc-print) ----
$renderScript = @'
const { marked } = require("marked");
const hljs = require("highlight.js");
const fs = require("fs");

function canHighlight(lang) {
  if (!lang) return false;
  try { return !!hljs.getLanguage(lang); } catch (e) { return false; }
}

const mdFile = process.argv[2];
const mdContent = fs.readFileSync(mdFile, "utf-8");

const tokens = marked.lexer(mdContent, { gfm: true });
const updatedTokens = [];

for (const token of tokens) {
  if (token.type === "code") {
    const LANG = token.lang ? token.lang.toUpperCase() : "";

    if (LANG === "MERMAID") {
      const mermaidHtml = "<div class=\"mermaid\">\n" + token.text + "\n</div>\n";
      updatedTokens.push({ type: "html", raw: token.raw, text: mermaidHtml, block: true });
    } else if (canHighlight(token.lang)) {
      try {
        const codeHtml = hljs.highlight(token.text, { language: token.lang }).value;
        const codeBlockHtml = "<pre class=\"code-box\">\n<code class=\"hljs\">\n" + codeHtml + "\n</code>\n</pre>\n";
        updatedTokens.push({ type: "html", raw: token.raw, text: codeBlockHtml, block: true });
      } catch (e) {
        updatedTokens.push(token);
      }
    } else {
      updatedTokens.push(token);
    }
  } else {
    updatedTokens.push(token);
  }
}

const html = marked.parser(updatedTokens);
process.stdout.write(html);
'@

$renderScriptPath = Join-Path $tmpDir "render.cjs"
Set-Content -Path $renderScriptPath -Value $renderScript -Encoding ASCII

Write-Host "Rendering Markdown..." -ForegroundColor Cyan
$renderedHtml = (& node $renderScriptPath $FilePath) -join "`n"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Node.js rendering failed. Try -InstallDeps to set up dependencies."
    exit 1
}

# ---- Build the complete HTML page matching vsc-print output ----
$fileName = Split-Path $FilePath -Leaf
$fileBaseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
$documentTitle = "Print - $fileName"

$defaultMarkdownCss = @'
html, body {
  margin: 0;
  padding: 0;
  background-color: white;
  font-family: serif;
  font-size: 14pt;
}
h1, h2, h3, h4, h5, h6 {
  font-family: sans-serif;
  page-break-after: avoid;
  page-break-inside: avoid;
}
table { width: 100%; border-collapse: collapse; }
td, th { border-bottom: thin solid silver; padding: 3px; text-align: left; }
code { text-wrap: wrap; }
.hljs { background-color: transparent; }
.code-box {
  background-color: #f8f8f8;
  border-radius: 0.5em;
  border: thin solid silver;
  white-space: pre-wrap;
}
pre.plaintext { hyphens: auto; padding-bottom: 3px; white-space: pre-wrap; }
div.mermaid { text-align: center; margin: 1em 0; }
div.mermaid svg { max-width: 100%; height: auto; }
@media print { .no-print { visibility: hidden; } }
@media screen { body { padding: 0.2em; } }
'@

$settingsCss = @'
html, body { tab-size: 4; }
.hljs { font-family: "Cascadia Code", "Fira Code", "Consolas", "Courier New", monospace; font-size: 10pt; }
.code-box, pre code.hljs { font-family: "Cascadia Code", "Fira Code", "Consolas", "Courier New", monospace; font-size: 10pt; line-height: 1.3em; }
'@

$highlightCssUrl = "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.0/styles/base16/atelier-dune-light.min.css"

$printOnLoad = if (-not $NoBrowser) { "true" } else { "false" }

$fileHeading = @"
<h3 class="filepath" style="font-family: sans-serif; color: #333; border-bottom: 1px solid #ccc; padding-bottom: 0.3em;">
  $FilePath
</h3>
"@

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
  <base href="file:///" />
  <title>$documentTitle</title>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <link rel="stylesheet" href="$highlightCssUrl" />
  <style>
    $defaultMarkdownCss
  </style>
  <style>
    $settingsCss
  </style>
  <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
  <script>try { mermaid.initialize({ startOnLoad: false, theme: "default" }); } catch(e) {}</script>
  <script type="application/javascript">
    function printAndClose(enabled) {
      if (!enabled) return;
      function doPrint() {
        window.addEventListener("afterprint", function () { window.close(); });
        window.print();
      }
      var nodes = document.querySelectorAll('.mermaid');
      if (nodes.length > 0) {
        if (typeof mermaid !== 'undefined' && typeof mermaid.run === 'function') {
          try {
            mermaid.initialize({ startOnLoad: false, theme: "default" });
            mermaid.run({ nodes: Array.from(nodes) }).then(doPrint).catch(function(e) { console.error(e); setTimeout(doPrint, 2000); });
          } catch(e) { console.error(e); setTimeout(doPrint, 2000); }
        } else {
          console.warn("Mermaid library not loaded");
          setTimeout(doPrint, 2000);
        }
      } else {
        setTimeout(doPrint, 1000);
      }
    }
    function fixAnchorLinks() {
      var pageUrl = window.location.href.split('#')[0];
      document.querySelectorAll('a[href]').forEach(function(a) {
        var href = a.href;
        var hashIndex = href.indexOf('#');
        if (hashIndex !== -1 && href.substring(0, hashIndex) === pageUrl) {
          a.setAttribute('href', href.substring(hashIndex));
        }
      });
    }
  </script>
</head>
<body onload="fixAnchorLinks();printAndClose($printOnLoad);">
  $fileHeading
  <div>
    $renderedHtml
  </div>
</body>
</html>
"@

# ---- Write temp .html file ----
$outDir = Join-Path $tmpBase "Print-Markdown-output"
$null = New-Item -ItemType Directory -Path $outDir -Force
$outFile = Join-Path $outDir "$fileBaseName.html"
Set-Content -Path $outFile -Value $htmlContent -Encoding UTF8

if (-not $NoBrowser) {
    Write-Host "Opening in default browser..." -ForegroundColor Cyan
    if ($script:isWin) {
        Start-Process "file:///$($outFile -replace '\\','/')"
    } elseif ($script:isMac) {
        & open $outFile
    } else {
        & xdg-open $outFile
    }
}

Write-Host "Print preview ready: $outFile" -ForegroundColor Green
