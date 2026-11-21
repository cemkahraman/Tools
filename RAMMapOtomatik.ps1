# RAMMapOtomatik.ps1
# RAMMap ile onbellege alinmis dosyalari (Standby + Modified listeleri) otomatik temizler.
#
# KURULUM (bir kereye mahsus):
#   1) Bu dosyayi RAMMap64.exe ile ayni klasore koy (ornegin C:\Tools).
#   2) Bu klasorde PowerShell ac ve "kur" komutunu calistir (yonetici izni 1 kez sorar).
#
# KOMUTLAR:
#   powershell -ExecutionPolicy Bypass -File .\RAMMapOtomatik.ps1 <komut>
#
#   kur      Gorevleri kaydeder ve baslatir (her oturum acilisinda otomatik calisir)
#   ac       Otomatik ozelligi ACAR   (yonetici izni gerektirmez)
#   kapat    Otomatik ozelligi KAPATIR (yonetici izni gerektirmez)
#   simdi    Hemen bir kez temizler    (kurulumdan sonra izin istemez)
#   durum    Ayarlari, anlik onbellek boyutunu ve log'un son satirlarini gosterir
#   pano     Iki saniyede bir yenilenen durumu gosterir (temizlik yapmaz)
#   yardim   Komutlari ve ayarlari aciklar
#   rapor    SQLite olcumlerinden haftalik HTML raporunu olusturur
#   kaldir   Gorevleri tamamen siler
#
# AYARLAR: Ayni klasordeki config.json (ilk calismada olusur). Degisiklikler
# yeniden baslatma gerektirmeden gecerli olur. Islem kaydi: log.txt

param(
    [Parameter(Position = 0)]
    [ValidateSet('kur', 'kaldir', 'ac', 'kapat', 'durum', 'pano', 'simdi', 'calistir', 'tek', 'yardim', 'rapor')]
    [string]$Komut = 'durum',

    [switch]$Bekle   # yonetici penceresi sonuc gorulmeden kapanmasin diye (otomatik eklenir)
)

$ErrorActionPreference = 'Stop'

$GorevAdi      = 'RAMMapOtomatikTemizlik'        # oturum acilisinda baslayan izleme gorevi
$SimdiGorevAdi = 'RAMMapOtomatikTemizlikSimdi'   # 'simdi' komutunun izinsiz tetikledigi gorev
# RAMMAP_TEST_KLASOR sadece Pester testleri icindir: dosyalarin yazilacagi klasoru degistirir.
$KlasorYolu    = if ($env:RAMMAP_TEST_KLASOR) { $env:RAMMAP_TEST_KLASOR } else { Split-Path -Parent $PSCommandPath }
$ConfigYolu    = Join-Path $KlasorYolu 'config.json'
$LogYolu       = Join-Path $KlasorYolu 'log.txt'
$SonucYolu     = Join-Path $KlasorYolu 'son_sonuc.txt'

# ================================================================ YARDIMCILAR

function Log($mesaj) {
    $satir = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $mesaj
    # Yazma ve rotasyon ayni kilit altinda: izleme ve tek seferlik gorev cakismasin.
    for ($i = 0; $i -lt 5; $i++) {
        $kilit = $null
        try {
            $kilit = [IO.File]::Open("$LogYolu.lock", 'OpenOrCreate', 'ReadWrite', 'None')
            $bayt = [Text.Encoding]::UTF8.GetByteCount($satir + [Environment]::NewLine)
            if ((Test-Path -LiteralPath $LogYolu) -and
                ((Get-Item -LiteralPath $LogYolu).Length + $bayt -ge 1MB)) {
                Move-Item -LiteralPath $LogYolu -Destination "$LogYolu.1" -Force
            }
            Add-Content -LiteralPath $LogYolu -Value $satir -Encoding UTF8 -ErrorAction Stop
            # Boyut sinirina ek olarak mevcut satir sinirini koru.
            $tum = @(Get-Content -LiteralPath $LogYolu -Encoding UTF8)
            if ($tum.Count -gt 500) {
                $tum | Select-Object -Last 300 | Set-Content -LiteralPath $LogYolu -Encoding UTF8
            }
            return
        }
        catch { Start-Sleep -Milliseconds (100 + (Get-Random -Maximum 150)) }
        finally { if ($null -ne $kilit) { $kilit.Dispose() } }
    }
}

# ---- Ayarlar ---------------------------------------------------------------

# Once gecici dosyaya yazip sonra yerine tasir: okuyan taraf hicbir zaman yarim yazilmis dosya gormez.
function Dosya-Atomik-Yaz([string]$yol, [string]$icerik, [switch]$YalnizcaYeni) {
    $gecici = "$yol.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($gecici, $icerik, [Text.UTF8Encoding]::new($true))
        for ($i = 0; $i -lt 5; $i++) {
            try {
                if ([IO.File]::Exists($yol)) {
                    if ($YalnizcaYeni) { return }
                    # PowerShell 5.1, $null dizge argumanini bos dizgeye donusturur.
                    [IO.File]::Replace($gecici, $yol, [NullString]::Value)
                } else {
                    [IO.File]::Move($gecici, $yol)
                }
                return
            } catch {
                if ($i -eq 4) { throw }
                Start-Sleep -Milliseconds (50 * [math]::Pow(2, $i))
            }
        }
    } finally {
        [IO.File]::Delete($gecici)
    }
}

function Ayar-Kaydet($cfg) {
    Dosya-Atomik-Yaz $ConfigYolu ($cfg | ConvertTo-Json -Depth 10)
}

. (Join-Path $PSScriptRoot 'RAMMapRapor.ps1')

function Ayar-Yukle {
    $varsayilan = [ordered]@{
        OtomatikCalisma = $true       # ANA ANAHTAR: false olursa hicbir otomatik islem yapilmaz
        AcilistaTemizle = $true       # oturum acilinca bir kez temizle
        EsikKontrolu    = $true       # onbellek esigi asilinca otomatik temizle
        EsikMB          = 12288       # Standby + Modified toplami bu boyutu (MB) gecerse temizle
        KontrolSaniye   = 60          # kac saniyede bir boyut kontrol edilsin
        BeklemeDakika   = 30          # iki temizlik arasinda en az kac dakika gecsin
        RamMapYolu      = ''          # bos: betikle ayni klasorde RAMMap64.exe / RAMMap.exe aranir
        BildirimAktif   = $false      # true: basarili temizlikten sonra Windows bildirimi
        Parametreler    = '-Em -Et'   # sirayla, ayri ayri calisir:
                                      #   -Em modified listesi, -Et standby listesi,
                                      #   -Ew working set, -Es system working set, -E0 priority 0 standby
        DinamikEsikAktif    = $false
        EsikYuzde          = 35
        YuksekCpuEsikArtisi = 10
        OngoruluTemizlik   = $false
        ExclusionList      = @()
        Priority           = 'Yapilandirilmis'
        HtmlRaporAktif     = $true
        TelemetriAktif     = $false
    }
    if (-not (Test-Path $ConfigYolu)) {
        Dosya-Atomik-Yaz $ConfigYolu ($varsayilan | ConvertTo-Json) -YalnizcaYeni
    }
    # Okuma hatasinda (baska islem yaziyor olabilir) birkac kez tekrar dene
    $cfg = $null
    for ($i = 0; $i -lt 3 -and $null -eq $cfg; $i++) {
        try {
            $cfg = Get-Content $ConfigYolu -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $cfg = $null
            Start-Sleep -Milliseconds 300
        }
    }
    if ($null -eq $cfg) {
        # Dosya bozuk/bos: kopyasini sakla ve varsayilan ayarlarla devam et (gorev olmesin)
        if (-not $script:BozukUyarildi) {
            Log 'UYARI: config.json okunamadi veya bozuk. Kopyasi config.bozuk.json olarak saklandi, varsayilan ayarlar kullaniliyor.'
            $script:BozukUyarildi = $true
        }
        try { Copy-Item -Path $ConfigYolu -Destination (Join-Path $KlasorYolu 'config.bozuk.json') -Force } catch {}
        $cfg = [pscustomobject]$varsayilan
    } else {
        $script:BozukUyarildi = $false
    }
    foreach ($anahtar in $varsayilan.Keys) {
        if ($null -eq $cfg.PSObject.Properties[$anahtar]) {
            $cfg | Add-Member -NotePropertyName $anahtar -NotePropertyValue $varsayilan[$anahtar]
        }
    }
    # Eski surumde yanlis yazilmis olan '-Es' degerini otomatik duzelt
    if ($cfg.Parametreler -eq '-Es') {
        $cfg.Parametreler = '-Et'
        Ayar-Kaydet $cfg
    }
    return $cfg
}

# ---- Yetki -----------------------------------------------------------------

function Yonetici-Mi {
    $kimlik = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$kimlik).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Yonetici-Iste([switch]$Sessiz) {
    if (-not (Yonetici-Mi)) {
        $arg = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Komut)
        if ($Sessiz) {
            # Sonuc ana konsolda gosterilir; gizli pencerenin cikis kodunu kontrol et.
            $surec = Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList $arg
            try {
                if ($surec.ExitCode -ne 0) { throw "Yonetici islemi basarisiz oldu (cikis kodu: $($surec.ExitCode))." }
                return $true
            } finally {
                $surec.Dispose()
            }
        } else {
            Write-Host 'Yonetici izni isteniyor...'
            Start-Process powershell -Verb RunAs -Wait -ArgumentList ($arg + '-Bekle')
        }
        exit
    }
}

# Otomatik ozelligi acar/kapatir. Yonetici GEREKTIRMEZ; basarisiz olursa $false doner.
function Ac-Kapat([bool]$acik) {
    try {
        $cfg = Ayar-Yukle
        $cfg.OtomatikCalisma = $acik
        Ayar-Kaydet $cfg
        if (Get-ScheduledTask -TaskName $GorevAdi -ErrorAction SilentlyContinue) {
            if ($acik) { Start-ScheduledTask -TaskName $GorevAdi -ErrorAction Stop | Out-Null }
            else       { Stop-ScheduledTask  -TaskName $GorevAdi -ErrorAction Stop | Out-Null }
        }
        return $true
    } catch {
        return $false
    }
}

# Once normal yetkiyle, gerekirse yonetici yetkisiyle dener; ikinci deneme de
# basarisizsa basariliymis gibi devam etmez.
function Ac-Kapat-Veya-Hata([bool]$acik) {
    if (Ac-Kapat $acik) { return }

    if (Yonetici-Iste -Sessiz) { return }
    if (-not (Ac-Kapat $acik)) {
        $islem = if ($acik) { 'acilamadi' } else { 'kapatilamadi' }
        throw "Otomatik ozellik $islem. Zamanlanmis gorev yetkisini ve log kaydini kontrol edin."
    }
}

# ---- RAMMap ve bellek olcumu -----------------------------------------------

function RamMap-Bul($cfg) {
    $adaylar = @()
    if ($cfg.RamMapYolu) {
        $yol = [string]$cfg.RamMapYolu
        if (-not [IO.Path]::IsPathRooted($yol)) { $yol = Join-Path $KlasorYolu $yol }
        $adaylar += $yol
    }
    $adaylar += $KlasorYolu
    foreach ($a in $adaylar) {
        # Yol bir DOSYA ise dogrudan kullan
        if (Test-Path -LiteralPath $a -PathType Leaf) { return (Resolve-Path -LiteralPath $a).Path }
        # Yol bir KLASOR ise icinde RAMMap64.exe / RAMMap.exe ara
        if (Test-Path -LiteralPath $a -PathType Container) {
            foreach ($ad in @('RAMMap64.exe', 'RAMMap.exe')) {
                $tam = Join-Path $a $ad
                if (Test-Path -LiteralPath $tam -PathType Leaf) { return (Resolve-Path -LiteralPath $tam).Path }
            }
        }
    }
    throw "RAMMap bulunamadi. RAMMap64.exe dosyasini betikle ayni klasore koy veya config.json icindeki RamMapYolu'na exe dosyasinin tam yolunu yaz."
}

function Bellek-Olc([switch]$Sistem, [switch]$Cpu) {
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $standby = [double]$m.StandbyCacheNormalPriorityBytes + [double]$m.StandbyCacheReserveBytes + [double]$m.StandbyCacheCoreBytes
    $modified = [double]$m.ModifiedPageListBytes
    $olcum = [pscustomobject]@{
        Zaman         = [datetime]::UtcNow
        StandbyMB     = [math]::Round($standby / 1MB)
        ModifiedMB    = [math]::Round($modified / 1MB)
        OnbellekMB    = [math]::Round(($standby + $modified) / 1MB)
        ToplamMB      = $null
        KullanimYuzde = $null
        CpuYuzde      = $null
    }
    if ($Sistem) {
        if (-not $script:ToplamBellekMB) {
            $script:ToplamBellekMB = [double](Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1KB
        }
        if ($script:ToplamBellekMB -le 0 -or $null -eq $m.AvailableBytes) {
            throw 'Fiziksel bellek olcumu alinamadi.'
        }
        $olcum.ToplamMB = $script:ToplamBellekMB
        $bosYuzde = 100 * ([double]$m.AvailableBytes / 1MB) / $olcum.ToplamMB
        $olcum.KullanimYuzde = [math]::Max(0.0, 100 - $bosYuzde)
    }
    if ($Cpu) {
        $islemci = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
        if ($null -eq $islemci.PercentProcessorTime) { throw 'CPU kullanimi olculemedi.' }
        $olcum.CpuYuzde = [double]$islemci.PercentProcessorTime
    }
    return $olcum
}

# Gorev Yoneticisi'ndeki "Onbellege alinmis" degeri: Standby + Modified (MB)
function Onbellek-MB { (Bellek-Olc).OnbellekMB }
function Standby-MB { (Bellek-Olc).StandbyMB }

# Esik karari: onbellek esigi asildi VE son temizlikten yeterli sure gecti mi?
function Temizlik-Gerekli([double]$boyutMB, [double]$esikMB, [double]$gecenDakika, [double]$beklemeDakika) {
    return ($boyutMB -ge $esikMB) -and ($gecenDakika -ge $beklemeDakika)
}

function Esik-Hesapla($cfg, $olcum) {
    if ($cfg.DinamikEsikAktif -ne $true) { return [int]$cfg.EsikMB }

    $yuzde = [double]$cfg.EsikYuzde
    $artis = [double]$cfg.YuksekCpuEsikArtisi
    if (-not ($yuzde -ge 1 -and $yuzde -le 100 -and $artis -ge 0 -and $artis -le 100)) {
        throw 'EsikYuzde 1-100, YuksekCpuEsikArtisi 0-100 araliginda olmalidir.'
    }
    if ($olcum.CpuYuzde -gt 80) { $yuzde = [math]::Min(100.0, $yuzde + $artis) }
    return [math]::Ceiling($olcum.ToplamMB * $yuzde / 100)
}

function Bellek-Hizi($onceki, $olcum, [double]$azamiSaniye) {
    if ($null -eq $onceki) { return }
    $saniye = ($olcum.Zaman - $onceki.Zaman).TotalSeconds
    if ($saniye -gt 0 -and $saniye -le $azamiSaniye) {
        return ($olcum.OnbellekMB - $onceki.OnbellekMB) / $saniye
    }
}

function Temizlik-Nedeni($cfg, $olcum, $oncekiHiz, $hiz, [double]$gecenDakika) {
    $esik = Esik-Hesapla $cfg $olcum
    if (Temizlik-Gerekli $olcum.OnbellekMB $esik $gecenDakika $cfg.BeklemeDakika) {
        return "Esik asildi ($($olcum.OnbellekMB) MB >= $esik MB)"
    }
    if ($cfg.OngoruluTemizlik -eq $true -and $oncekiHiz -gt 0 -and $hiz -gt 0) {
        # Iki ardisik artis arasinda dusuk hizi sec; tek ornek sicrama yaratmasin.
        $tahmin = $olcum.OnbellekMB + 600 * [math]::Min($oncekiHiz, $hiz)
        if (Temizlik-Gerekli $tahmin $esik $gecenDakika $cfg.BeklemeDakika) {
            return ('Onbellek 10 dk icinde {0} MB esigine ulasabilir (olculen hiz: {1:N2} MB/sn)' -f $esik, $hiz)
        }
    }
}

# RAMMap komutlari sistem genelinde calisir. Korunan surec varsa tum temizligi ertele.
function Temizlige-Izin-Ver($cfg) {
    $adlar = foreach ($ad in $cfg.ExclusionList) {
        if ($ad -isnot [string] -or [string]::IsNullOrWhiteSpace($ad) -or $ad -match '[\\/:*?"<>|]') {
            throw 'ExclusionList yalnizca uygulama adlari icermelidir (ornek: oyun.exe).'
        }
        $ad.Trim() -replace '\.exe$', ''
    }
    if ($adlar) {
        $eslesen = Get-Process | Where-Object { $_.ProcessName -in $adlar } | Select-Object -First 1
        if ($eslesen) {
            throw [OperationCanceledException]::new("Temizlik ertelendi: $($eslesen.ProcessName) calisiyor.")
        }
    }
}

function Otomatik-Temizlik-Parametreleri($cfg, $argumanlar, $olcum) {
    switch ($cfg.Priority) {
        'Yapilandirilmis' { return $argumanlar }
        'Dusuk' { return '-E0' }
        'Uyarlanabilir' {
            # %60 kullanimda agirlik 10, %90 kullanimda 90. Ara degerler dogrusal.
            $agirlik = [math]::Max(0.0, [math]::Min(100.0, 10 + ($olcum.KullanimYuzde - 60) * 80 / 30))
            if ($agirlik -lt 50) { return '-E0' }
            return $argumanlar
        }
        default { throw 'Priority Yapilandirilmis, Dusuk veya Uyarlanabilir olmalidir.' }
    }
}

# Tum anahtarlari ilk islemden ONCE dogrula; gecersiz listede kismi temizlik yapma.
function Parametreleri-Dogrula($parametreler) {
    if ($parametreler -isnot [string] -or [string]::IsNullOrWhiteSpace($parametreler)) {
        throw 'Parametreler bos olamaz ve metin olmalidir.'
    }
    $argumanlar = @($parametreler -split '\s+' | Where-Object { $_ })
    foreach ($arg in $argumanlar) {
        if ($arg -cnotin @('-Em', '-Et', '-Ew', '-Es', '-E0')) {
            throw "Gecersiz RAMMap parametresi: $arg. Izin verilenler: -Em -Et -Ew -Es -E0."
        }
    }
    return $argumanlar
}

function Bildirim-Kimligi {
    $uygulama = Get-StartApps | Where-Object {
        $_.AppID -eq 'Microsoft.Windows.PowerShell' -or
        $_.AppID -like '*\WindowsPowerShell\v1.0\powershell.exe'
    } | Select-Object -First 1
    if (-not $uygulama) { throw 'Windows PowerShell Baslat menusu bildirimi kimligi bulunamadi.' }
    return $uygulama.AppID
}

function Bildirim-Gonder([double]$once, [double]$sonra) {
    # Mevcut Windows PowerShell Baslat menusu kimligini kullanir; ek modul gerekmez.
    $kimlik = Bildirim-Kimligi
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>RAMMap temizligi tamamlandi</text><text>Onbellek: $once MB -&gt; $sonra MB</text></binding></visual></toast>")
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($kimlik).Show($toast)
}

function Pano-Goster($cfg, [double]$boyutMB, [double]$esikMB = $cfg.EsikMB) {
    Write-Host '--- RAMMap Durum Panosu (Ctrl+C ile cikis) ---'
    Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Write-Host ("Otomatik: {0} | Esik kontrolu: {1}" -f $cfg.OtomatikCalisma, $cfg.EsikKontrolu)
    Write-Host ("Onbellek: {0} MB | Esik: {1} MB | Bekleme: {2} dk" -f $boyutMB, $esikMB, $cfg.BeklemeDakika)
    $gorev = Get-ScheduledTask -TaskName $GorevAdi -ErrorAction SilentlyContinue
    $durum = if ($gorev) { $gorev.State } else { 'Kurulu degil' }
    Write-Host ("Gorev: {0} | Pano yenileme: 2 sn (yalnizca izleme)" -f $durum)
    if (Test-Path -LiteralPath $LogYolu) {
        Get-Content -LiteralPath $LogYolu -Encoding UTF8 -Tail 8 | Write-Host
    }
}

function RamMap-Calistir([string]$exe, [string]$arguman) {
    Log "Calistiriliyor: $exe $arguman"
    $surec = Start-Process -FilePath $exe -ArgumentList @($arguman) -WindowStyle Hidden -PassThru
    try {
        if (-not $surec.WaitForExit(60000)) {
            Log "RAMMap $arguman 60 sn icinde kapanmadi, surec sonlandiriliyor."
            if (-not $surec.HasExited) {
                # RAMMap.exe, 64 bit sistemlerde gomulu RAMMap64 surecini baslatabilir.
                $taskkill = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
                $durduran = Start-Process -FilePath $taskkill -ArgumentList @('/PID', $surec.Id, '/T', '/F') -WindowStyle Hidden -PassThru
                try {
                    if (-not $durduran.WaitForExit(5000)) {
                        try { $durduran.Kill() } catch {}
                        throw 'RAMMap 60 saniye icinde tamamlanmadi; surec agacinin kapandigi dogrulanamadi.'
                    }
                    if ($durduran.ExitCode -ne 0) {
                        throw "RAMMap 60 saniye icinde tamamlanmadi; surec agaci sonlandirilamadi (taskkill: $($durduran.ExitCode))."
                    }
                } finally {
                    if ($durduran -is [IDisposable]) { $durduran.Dispose() }
                }
            }
            if (-not $surec.WaitForExit(5000)) {
                throw 'RAMMap 60 saniye icinde tamamlanmadi; surecin kapandigi dogrulanamadi.'
            }
            throw 'RAMMap 60 saniye icinde tamamlanmadi; surec durdu.'
        }
        Log "RAMMap cikis kodu: $($surec.ExitCode)"
        if ($surec.ExitCode -ne 0) {
            throw "RAMMap basarisiz oldu (cikis kodu: $($surec.ExitCode))."
        }
    } finally {
        if ($surec -is [IDisposable]) { $surec.Dispose() }
    }
}

# RAMMap'i secilen anahtarlarla (her biri ayri ayri) calistirir.
# Donus: @(oncekiMB, sonrakiMB)
function Temizle($cfg, [switch]$Otomatik) {
    $argumanlar = @(Parametreleri-Dogrula $cfg.Parametreler)
    try { $kilit = [IO.File]::Open((Join-Path $KlasorYolu 'temizlik.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] {
        $hata = $_.Exception.GetBaseException()
        if (($hata.HResult -band 0xFFFF) -in 32, 33) {
            throw [OperationCanceledException]::new('Temizlik ertelendi: baska bir temizlik devam ediyor.')
        }
        throw
    }
    try {
        Temizlige-Izin-Ver $cfg
        $exe = RamMap-Bul $cfg
        $uyarlanabilir = $Otomatik -and $cfg.Priority -eq 'Uyarlanabilir'
        $once = Bellek-Olc -Sistem:$uyarlanabilir
        if ($Otomatik) { $argumanlar = @(Otomatik-Temizlik-Parametreleri $cfg $argumanlar $once) }

        # RAMMap lisansini komut satirinda degil, kayit defterinde kabul et
        $reg = 'HKCU:\Software\Sysinternals\RAMMap'
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
        Set-ItemProperty -Path $reg -Name 'EulaAccepted' -Value 1 -Type DWord

        foreach ($arg in $argumanlar) {
            RamMap-Calistir $exe $arg
            Start-Sleep -Seconds 2
        }
        Start-Sleep -Seconds 2
        $sonra = Bellek-Olc
        Log "Temizlendi. Onbellek: $($once.OnbellekMB) MB -> $($sonra.OnbellekMB) MB"
        if ($cfg.HtmlRaporAktif -eq $true) {
            try { Temizlik-Raporu-Yaz $once $sonra $argumanlar }
            catch { Log "UYARI: HTML raporu yazilamadi: $($_.Exception.Message)" }
        }
        if ($cfg.BildirimAktif -eq $true) {
            # Bildirim altyapisi kapali/erisim disi olsa bile temizlik basarili kalir.
            try { Bildirim-Gonder $once.OnbellekMB $sonra.OnbellekMB }
            catch { Log "UYARI: Bildirim gonderilemedi: $($_.Exception.Message)" }
        }
        return @($once.OnbellekMB, $sonra.OnbellekMB)
    } finally {
        $kilit.Dispose()
    }
}

# Baslangictaki temizlik basarisizsa bekleme suresini baslatma; esik kontrolu
# ilk turda yeniden deneyebilsin.
function Baslangic-Temizligi([object]$cfg) {
    try {
        [void](Temizle $cfg -Otomatik)
        return Get-Date
    } catch [OperationCanceledException] {
        Log $_.Exception.Message
        return [datetime]::MinValue
    } catch {
        Log "HATA: Baslangic temizligi basarisiz: $($_.Exception.Message)"
        return [datetime]::MinValue
    }
}

function Yardim-Goster {
    Write-Host @'
Kullanim   powershell -ExecutionPolicy Bypass -File .\RAMMapOtomatik.ps1 <komut>

  durum    Ayarlari, kullanilan esigi ve son kayitlari gosterir.
  pano     Durumu iki saniyede bir yeniler. Ctrl+C ile kapanir.
  simdi    Yapilandirilmis RAMMap komutlariyla bir kez temizler.
  ac       Kurulu otomatik izlemeyi baslatir.
  kapat    Otomatik izlemeyi durdurur.
  kur      Zamanlanmis gorevleri kurar ve izlemeyi baslatir.
  kaldir   Zamanlanmis gorevleri siler.
  rapor    SQLite olcumlerinden haftalik-rapor.html olusturur.
  yardim   Komutlari ve ayarlari listeler.

config.json
  OtomatikCalisma      Otomatik izleme ve temizligin ana anahtari.
  AcilistaTemizle      Izleme baslarken bir kez temizlik dener.
  EsikKontrolu         Izleme sirasinda esik ve tahmin ile temizligi etkinlestirir.
  EsikMB              Sabit Standby + Modified esigi (MB).
  KontrolSaniye       Olcum araligi (en az 10 saniye).
  BeklemeDakika       Esik veya tahminle tetiklenen iki temizlik arasindaki bekleme.
  RamMapYolu          RAMMap yolu. Bos ise betigin klasorunde aranir.
  Parametreler        Boslukla ayrilan komutlar, verilen sirada calisir.
                      -Em Modified, -Et Standby, -E0 en dusuk Standby onceligi,
                      -Ew surec calisma kumeleri, -Es sistem calisma kumesi.
  BildirimAktif       Basarili temizlikten sonra Windows bildirimi gosterir.
  DinamikEsikAktif    EsikMB yerine toplam fiziksel RAM yuzdesini kullanir.
  EsikYuzde           Dinamik esigin RAM yuzdesi (1-100).
  YuksekCpuEsikArtisi CPU %80'i asinca esige eklenecek yuzde puan (0-100).
  OngoruluTemizlik    Iki ardisik artisa gore 10 dk icinde esik asimini tahmin eder.
  ExclusionList       Acikken temizligi erteleyecek surec adlari. Ornek ["oyun.exe"].
  Priority            Otomatik temizlik modu. Yapilandirilmis, Dusuk (-E0)
                      veya Uyarlanabilir (%75'in altinda -E0, %75 ve ustunde Parametreler).
  HtmlRaporAktif      Basarili temizlik sonrasi report.html dosyasini yeniler.
  TelemetriAktif      Izleme olcumlerini yerel telemetri.sqlite dosyasina kaydeder.
'@
}

# Test icin: dosya ". .\RAMMapOtomatik.ps1" ile yuklenirse sadece fonksiyonlar tanimlanir, komut calistirilmaz.
if ($MyInvocation.InvocationName -eq '.') { return }

# ================================================================ KOMUTLAR

switch ($Komut) {

    'yardim' { Yardim-Goster }

    'rapor' {
        Haftalik-Rapor-Yaz
        Write-Host "Haftalik rapor hazir: $HaftalikRaporYolu" -ForegroundColor Green
    }

    'pano' {
        while ($true) {
            Clear-Host
            try {
                $cfg = Ayar-Yukle
                $dinamik = $cfg.DinamikEsikAktif -eq $true
                $olcum = Bellek-Olc -Sistem:$dinamik -Cpu:$dinamik
                Pano-Goster $cfg $olcum.OnbellekMB (Esik-Hesapla $cfg $olcum)
            }
            catch { Write-Host "Pano okunamadi: $($_.Exception.Message)" }
            Start-Sleep -Seconds 2
        }
    }

    # Zamanlanmis gorev (oturum acilisinda) bunu calistirir ve surekli izler
    'calistir' {
        $cfg = Ayar-Yukle
        if (-not $cfg.OtomatikCalisma) { Log 'Otomatik calisma kapali, cikiliyor.'; exit }

        Start-Sleep -Seconds 30   # sistem otursun
        $cfg = Ayar-Yukle
        if (-not $cfg.OtomatikCalisma) { Log 'Otomatik calisma kapatildi, cikiliyor.'; exit }
        $sonTemizlik = [datetime]::MinValue

        if ($cfg.AcilistaTemizle) {
            $sonTemizlik = Baslangic-Temizligi $cfg
        }

        Log "Izleme basladi. Kontrol araligi: $($cfg.KontrolSaniye) sn"
        $bekleSn = [math]::Max(10, [int]$cfg.KontrolSaniye)
        $oncekiOlcum = $null
        $oncekiHiz = $null
        while ($true) {
            $aralik = $bekleSn
            Start-Sleep -Seconds $aralik
            # Dongunun tamami korumali: beklenmedik bir hata gorevi oldurmez, sadece loglanir
            try {
                $cfg = Ayar-Yukle                   # her turda ayari tekrar oku
                $bekleSn = [math]::Max(10, [int]$cfg.KontrolSaniye)
                if (-not $cfg.OtomatikCalisma) { Log 'Otomatik calisma kapatildi, cikiliyor.'; break }
                $telemetri = $cfg.TelemetriAktif -eq $true
                if (-not ($cfg.EsikKontrolu -or $telemetri)) {
                    $oncekiOlcum = $null
                    $oncekiHiz = $null
                    continue
                }
                $dinamik = $cfg.EsikKontrolu -and $cfg.DinamikEsikAktif -eq $true
                $sistemOlcum = $dinamik -or $telemetri
                try { $olcum = Bellek-Olc -Sistem:$sistemOlcum -Cpu:$sistemOlcum }
                catch {
                    if ($dinamik -or -not $telemetri) { throw }
                    Log "UYARI: Telemetri olcumu alinamadi: $($_.Exception.Message)"
                    $telemetri = $false
                    $olcum = Bellek-Olc
                }
                $hiz = Bellek-Hizi $oncekiOlcum $olcum (2 * $aralik)
                $oncekiOlcum = $olcum
                if ($telemetri) {
                    try { Telemetri-Kaydet $olcum $hiz }
                    catch { Log "UYARI: Telemetri yazilamadi: $($_.Exception.Message)" }
                }
                $bekleme = ((Get-Date) - $sonTemizlik).TotalMinutes
                $neden = if ($cfg.EsikKontrolu) { Temizlik-Nedeni $cfg $olcum $oncekiHiz $hiz $bekleme }
                $oncekiHiz = $hiz
                if ($neden) {
                    Log "$neden, temizlik deneniyor."
                    [void](Temizle $cfg -Otomatik)
                    $sonTemizlik = Get-Date
                    $oncekiOlcum = $null
                    $oncekiHiz = $null
                }
            } catch [OperationCanceledException] {
                Log $_.Exception.Message
            } catch {
                Log "HATA: $($_.Exception.Message)"
                $sonTemizlik = Get-Date   # hata olsa da bekleme suresine uy, her dakika denemesin
                $oncekiOlcum = $null
                $oncekiHiz = $null
            }
        }
    }

    # 'simdi' komutunun tetikledigi yonetici yetkili gorev: bir kez temizler, sonucu dosyaya yazar
    'tek' {
        try {
            $cfg = Ayar-Yukle
            $r = Temizle $cfg
            "Temizlendi. Onbellek: $($r[0]) MB -> $($r[1]) MB" | Set-Content -Path $SonucYolu
        } catch [OperationCanceledException] {
            Log $_.Exception.Message
            $_.Exception.Message | Set-Content -Path $SonucYolu
        } catch {
            Log "HATA: $($_.Exception.Message)"
            "HATA: $($_.Exception.Message)" | Set-Content -Path $SonucYolu
        }
    }

    'kur' {
        Yonetici-Iste
        $cfg = Ayar-Yukle
        [void](RamMap-Bul $cfg)   # RAMMap yoksa burada uyar
        $cfg.OtomatikCalisma = $true
        Ayar-Kaydet $cfg

        $yetki = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

        # 1) Oturum acilisinda baslayan izleme gorevi
        $eylem = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" calistir"
        $tetik = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $ayarlar = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
        Stop-ScheduledTask -TaskName $GorevAdi -ErrorAction SilentlyContinue   # eski surum calisiyorsa durdur
        Register-ScheduledTask -TaskName $GorevAdi -Action $eylem -Trigger $tetik -Settings $ayarlar -Principal $yetki -Force | Out-Null

        # 2) 'simdi' icin gorev: tetikleyicisi yok, sadece elle (izinsiz) baslatilir
        $eylem2 = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" tek"
        $ayarlar2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $SimdiGorevAdi -Action $eylem2 -Settings $ayarlar2 -Principal $yetki -Force | Out-Null

        Start-ScheduledTask -TaskName $GorevAdi
        Write-Host 'BAŞARILI | Görevler kuruldu ve izleme başlatıldı.' -ForegroundColor Green
        Write-Host "Ayarlar: $ConfigYolu"
    }

    'kaldir' {
        Yonetici-Iste
        if (Get-ScheduledTask -TaskName $GorevAdi -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $GorevAdi -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $GorevAdi -Confirm:$false
        }
        if (Get-ScheduledTask -TaskName $SimdiGorevAdi -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $SimdiGorevAdi -Confirm:$false
        }
        Write-Host 'BAŞARILI | Görevler kaldırıldı.' -ForegroundColor Green
    }

    'kapat' {
        Ac-Kapat-Veya-Hata $false
        Write-Host 'BAŞARILI | Otomatik temizlik kapatıldı.' -ForegroundColor Green
    }

    'ac' {
        if (-not (Get-ScheduledTask -TaskName $GorevAdi -ErrorAction SilentlyContinue)) {
            Write-Host "Gorev kurulu degil. Once 'kur' komutunu calistir."
            exit 1
        } else {
            Ac-Kapat-Veya-Hata $true
            Write-Host 'BAŞARILI | Otomatik temizlik açıldı ve izleme başlatıldı.' -ForegroundColor Green
        }
    }

    'simdi' {
        if (Get-ScheduledTask -TaskName $SimdiGorevAdi -ErrorAction SilentlyContinue) {
            Remove-Item $SonucYolu -ErrorAction SilentlyContinue
            try {
                Start-ScheduledTask -TaskName $SimdiGorevAdi -ErrorAction Stop | Out-Null
            } catch {
                Write-Host "Gorev baslatilamadi: $($_.Exception.Message)"
                exit
            }
            Write-Host 'Temizleniyor...'
            $bitis = (Get-Date).AddSeconds(300)
            while (-not (Test-Path $SonucYolu) -and (Get-Date) -lt $bitis) { Start-Sleep -Milliseconds 500 }
            if (Test-Path $SonucYolu) {
                Start-Sleep -Milliseconds 300
                $sonuc = Get-Content -LiteralPath $SonucYolu -Raw
                if ($sonuc -like 'Temizlendi.*') {
                    Write-Host "BAŞARILI | $($sonuc.TrimEnd())" -ForegroundColor Green
                } else {
                    Write-Host $sonuc.TrimEnd() -ForegroundColor Yellow
                }
                Remove-Item $SonucYolu -ErrorAction SilentlyContinue   # okunduktan sonra sil
            } else {
                Write-Host 'Sonuc 300 sn icinde gelmedi. Ayrinti icin log.txt dosyasina bak.'
            }
        } else {
            # Hizli temizlik gorevi henuz kurulu degil: yonetici izni isteyen yedek yontem
            Write-Host "Not: Izin sormamasi icin bir kereye mahsus 'kur' komutunu calistir."
            Yonetici-Iste
            $cfg = Ayar-Yukle
            try {
                $r = Temizle $cfg
                Write-Host "BAŞARILI | Önbellek $($r[0]) MB → $($r[1]) MB" -ForegroundColor Green
            } catch [OperationCanceledException] {
                Write-Host $_.Exception.Message -ForegroundColor Yellow
            }
        }
    }

    'durum' {
        $cfg = Ayar-Yukle
        Write-Host '--- Ayarlar ---'
        $cfg | Format-List | Out-String | Write-Host
        $gorev = Get-ScheduledTask -TaskName $GorevAdi -ErrorAction SilentlyContinue
        Write-Host ("Gorev kurulu mu : {0}" -f [bool]$gorev)
        if ($gorev) { Write-Host ("Gorev durumu    : {0}" -f $gorev.State) }
        $dinamik = $cfg.DinamikEsikAktif -eq $true
        $olcum = Bellek-Olc -Sistem:$dinamik -Cpu:$dinamik
        Write-Host ("Onbellek toplami: {0} MB   <- esikle karsilastirilan deger (Standby + Modified)" -f $olcum.OnbellekMB)
        Write-Host ("Anlik Standby   : {0} MB" -f $olcum.StandbyMB)
        Write-Host ("Anlik Modified  : {0} MB" -f $olcum.ModifiedMB)
        Write-Host ("Esik            : {0} MB, bekleme: {1} dk, kontrol: {2} sn" -f (Esik-Hesapla $cfg $olcum), $cfg.BeklemeDakika, $cfg.KontrolSaniye)
        if (Test-Path $LogYolu) {
            Write-Host '--- log.txt son 8 satir ---'
            Get-Content $LogYolu | Select-Object -Last 8 | Write-Host
        }
    }
}

if ($Bekle) { Read-Host 'Kapatmak icin Enter tusuna bas' | Out-Null }
