# Convert PDF and DOCX to TXT for BCETD chatbot ingestion
# Cu forțare UTF-8 pentru diacritice românești

param(
    [string]$SourceDir = "C:\Documente_ULBS",
    [string]$DestDir = "C:\Users\csiml\Desktop\chatbot-bcetd\data\documents"
)

# Forțează PowerShell să folosească UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "===== BCETD Document Converter =====" -ForegroundColor Cyan
Write-Host "Sursa:      $SourceDir"
Write-Host "Destinatie: $DestDir"
Write-Host "------------------------------------"

if (-not (Test-Path $SourceDir)) {
    Write-Host "EROARE: Folderul sursa nu exista: $SourceDir" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir | Out-Null
}

$hasPDFTotext = Get-Command pdftotext -ErrorAction SilentlyContinue
$hasPandoc = Get-Command pandoc -ErrorAction SilentlyContinue

if (-not $hasPDFTotext) {
    Write-Host "AVERTISMENT: pdftotext nu este instalat" -ForegroundColor Yellow
}
if (-not $hasPandoc) {
    Write-Host "AVERTISMENT: pandoc nu este instalat" -ForegroundColor Yellow
}

$totalConverted = 0

# Functie pentru a reconverti fisiere la UTF-8 fara BOM
function Convert-ToUTF8NoBOM {
    param([string]$filePath)
    
    if (-not (Test-Path $filePath)) { return }
    
    # Citeste continutul ca byte stream si detecteaza encoding-ul
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    
    # Detecteaza si elimina BOM daca exista
    $hasUTF8BOM = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    
    $text = ""
    if ($hasUTF8BOM) {
        # Skip BOM bytes
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    } else {
        # Incearca UTF-8 mai intai
        try {
            $utf8 = New-Object System.Text.UTF8Encoding($false, $true)  # throw on invalid
            $text = $utf8.GetString($bytes)
        } catch {
            # Daca nu e UTF-8 valid, e probabil Windows-1252 (Romana)
            $text = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
        }
    }
    
    # Scrie ca UTF-8 fara BOM
    $utf8NoBOM = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($filePath, $text, $utf8NoBOM)
}

# ===== PDF =====
if ($hasPDFTotext) {
    $pdfs = Get-ChildItem -Path $SourceDir -Filter "*.pdf" -Recurse
    Write-Host ""
    Write-Host "Procesez $($pdfs.Count) PDF-uri..." -ForegroundColor Green
    
    foreach ($pdf in $pdfs) {
        $destFile = Join-Path $DestDir ($pdf.BaseName + ".txt")
        Write-Host "  -> $($pdf.Name)"
        
        try {
            & pdftotext -enc UTF-8 -layout $pdf.FullName $destFile 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0 -and (Test-Path $destFile)) {
                # Forteaza UTF-8 fara BOM
                Convert-ToUTF8NoBOM -filePath $destFile
                $totalConverted++
                Write-Host "     OK" -ForegroundColor Green
            } else {
                Write-Host "     EROARE" -ForegroundColor Red
            }
        } catch {
            Write-Host "     EROARE: $_" -ForegroundColor Red
        }
    }
}

# ===== DOCX =====
if ($hasPandoc) {
    $docxs = Get-ChildItem -Path $SourceDir -Filter "*.docx" -Recurse
    Write-Host ""
    Write-Host "Procesez $($docxs.Count) DOCX-uri..." -ForegroundColor Green
    
    foreach ($docx in $docxs) {
        $destFile = Join-Path $DestDir ($docx.BaseName + ".txt")
        Write-Host "  -> $($docx.Name)"
        
        try {
            & pandoc $docx.FullName -t plain -o $destFile 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0 -and (Test-Path $destFile)) {
                Convert-ToUTF8NoBOM -filePath $destFile
                $totalConverted++
                Write-Host "     OK" -ForegroundColor Green
            } else {
                Write-Host "     EROARE" -ForegroundColor Red
            }
        } catch {
            Write-Host "     EROARE: $_" -ForegroundColor Red
        }
    }
}

# ===== TXT (copy + reconvert encoding) =====
$txts = Get-ChildItem -Path $SourceDir -Filter "*.txt" -Recurse
if ($txts.Count -gt 0) {
    Write-Host ""
    Write-Host "Copiez $($txts.Count) TXT-uri..." -ForegroundColor Green
    
    foreach ($txt in $txts) {
        $destFile = Join-Path $DestDir $txt.Name
        Write-Host "  -> $($txt.Name)"
        Copy-Item $txt.FullName $destFile -Force
        Convert-ToUTF8NoBOM -filePath $destFile
        $totalConverted++
    }
}

Write-Host ""
Write-Host "===== Sumar =====" -ForegroundColor Cyan
Write-Host "Convertite cu succes: $totalConverted" -ForegroundColor Green

Write-Host ""
Write-Host "Documente in destinatie:" -ForegroundColor Cyan
Get-ChildItem $DestDir -Filter "*.txt" | Sort-Object Name | ForEach-Object {
    $sizeKB = [math]::Round($_.Length / 1024, 1)
    Write-Host ("  {0,-50} {1,8} KB" -f $_.Name, $sizeKB)
}

Write-Host ""
Write-Host "Verifica primele 3 linii din primul fisier:" -ForegroundColor Yellow
$firstFile = Get-ChildItem $DestDir -Filter "*.txt" | Select-Object -First 1
if ($firstFile) {
    Get-Content $firstFile.FullName -Encoding UTF8 | Select-Object -First 3
}