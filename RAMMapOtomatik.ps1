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
#   kaldir   Gorevleri tamamen siler
#
# AYARLAR: Ayni klasordeki config.json (ilk calismada olusur). Degisiklikler
# yeniden baslatma gerektirmeden gecerli olur. Islem kaydi: log.txt

param(
    [Parameter(Position = 0)]
    [ValidateSet('kur', 'kaldir', 'ac', 'kapat', 'durum', 'pano', 'simdi', 'calistir', 'tek')]
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
function Ayar-Kaydet($cfg) {
    $gecici = "$ConfigYolu.tmp"
    $cfg | ConvertTo-Json | Set-Content -Path $gecici -Encoding UTF8
    for ($i = 0; $i -lt 5; $i++) {
        try { Move-Item -Path $gecici -Destination $ConfigYolu -Force -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 200 }   # dosya o an okunuyor olabilir
    }
    throw 'config.json yazilamadi (dosya baska bir islem tarafindan kullaniliyor).'
}

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
    }
    if (-not (Test-Path $ConfigYolu)) {
        ([pscustomobject]$varsayilan) | ConvertTo-Json | Set-Content -Path $ConfigYolu -Encoding UTF8
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
            # Gizli pencere, "Enter'a bas" beklemesi yok
            Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList $arg
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

    Yonetici-Iste -Sessiz
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

# Standby listesi boyutu (MB). WMI sinif/ozellik adlari Turkce Windows'ta da Ingilizcedir.
function Standby-MB {
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $bayt = [double]$m.StandbyCacheNormalPriorityBytes + [double]$m.StandbyCacheReserveBytes + [double]$m.StandbyCacheCoreBytes
    return [math]::Round($bayt / 1MB)
}

# Gorev Yoneticisi'ndeki "Onbellege alinmis" degeri: Standby + Modified (MB)
function Onbellek-MB {
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $bayt = [double]$m.StandbyCacheNormalPriorityBytes + [double]$m.StandbyCacheReserveBytes + [double]$m.StandbyCacheCoreBytes + [double]$m.ModifiedPageListBytes
    return [math]::Round($bayt / 1MB)
}

# Esik karari: onbellek esigi asildi VE son temizlikten yeterli sure gecti mi?
function Temizlik-Gerekli([double]$boyutMB, [double]$esikMB, [double]$gecenDakika, [double]$beklemeDakika) {
    return ($boyutMB -ge $esikMB) -and ($gecenDakika -ge $beklemeDakika)
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

function Pano-Goster($cfg, [double]$boyutMB) {
    Write-Host '--- RAMMap Durum Panosu (Ctrl+C ile cikis) ---'
    Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Write-Host ("Otomatik: {0} | Esik kontrolu: {1}" -f $cfg.OtomatikCalisma, $cfg.EsikKontrolu)
    Write-Host ("Onbellek: {0} MB | Esik: {1} MB | Bekleme: {2} dk" -f $boyutMB, $cfg.EsikMB, $cfg.BeklemeDakika)
    $gorev = Get-ScheduledTask -TaskName $GorevAdi -ErrorAction SilentlyContinue
    $durum = if ($gorev) { $gorev.State } else { 'Kurulu degil' }
    Write-Host ("Gorev: {0} | Pano yenileme: 2 sn (yalnizca izleme)" -f $durum)
    if (Test-Path -LiteralPath $LogYolu) {
        Get-Content -LiteralPath $LogYolu -Encoding UTF8 -Tail 8 | Write-Host
    }
}

# RAMMap'i config'deki anahtarlarla (her biri ayri ayri) calistirip onbellegi temizler.
# Donus: @(oncekiMB, sonrakiMB)
function Temizle($cfg) {
    $argumanlar = @(Parametreleri-Dogrula $cfg.Parametreler)
    $exe  = RamMap-Bul $cfg
    $once = Onbellek-MB

    # RAMMap lisansini komut satirinda degil, kayit defterinde kabul et
    $reg = 'HKCU:\Software\Sysinternals\RAMMap'
    if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
    Set-ItemProperty -Path $reg -Name 'EulaAccepted' -Value 1 -Type DWord

    foreach ($arg in $argumanlar) {
        Log "Calistiriliyor: $exe $arg"
        $p = Start-Process -FilePath $exe -ArgumentList @($arg) -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit(60000)) {          # 60 sn icinde kapanmazsa zorla kapat
            Log 'RAMMap 60 sn icinde kapanmadi, zorla kapatiliyor.'
            try { $p.Kill() } catch {}
            throw 'RAMMap 60 saniye icinde tamamlanmadi; surec sonlandirildi.'
        } else {
            Log "RAMMap cikis kodu: $($p.ExitCode)"
            if ($p.ExitCode -ne 0) {
                throw "RAMMap basarisiz oldu (cikis kodu: $($p.ExitCode))."
            }
        }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Seconds 2
    $sonra = Onbellek-MB
    Log "Temizlendi. Onbellek: $once MB -> $sonra MB"
    if ($cfg.BildirimAktif -eq $true) {
        # Bildirim altyapisi kapali/erisim disi olsa bile temizlik basarili kalir.
        try { Bildirim-Gonder $once $sonra }
        catch { Log "UYARI: Bildirim gonderilemedi: $($_.Exception.Message)" }
    }
    return @($once, $sonra)
}

# Baslangictaki temizlik basarisizsa bekleme suresini baslatma; esik kontrolu
# ilk turda yeniden deneyebilsin.
function Baslangic-Temizligi([object]$cfg) {
    try {
        [void](Temizle $cfg)
        return Get-Date
    } catch {
        Log "HATA: Baslangic temizligi basarisiz: $($_.Exception.Message)"
        return [datetime]::MinValue
    }
}

# Test icin: dosya ". .\RAMMapOtomatik.ps1" ile yuklenirse sadece fonksiyonlar tanimlanir, komut calistirilmaz.
if ($MyInvocation.InvocationName -eq '.') { return }

# ================================================================ KOMUTLAR

switch ($Komut) {

    'pano' {
        while ($true) {
            Clear-Host
            try { Pano-Goster (Ayar-Yukle) (Onbellek-MB) }
            catch { Write-Host "Pano okunamadi: $($_.Exception.Message)" }
            Start-Sleep -Seconds 2
        }
    }

    # Zamanlanmis gorev (oturum acilisinda) bunu calistirir ve surekli izler
    'calistir' {
        $cfg = Ayar-Yukle
        if (-not $cfg.OtomatikCalisma) { Log 'Otomatik calisma kapali, cikiliyor.'; exit }

        Start-Sleep -Seconds 30   # sistem otursun
        $sonTemizlik = [datetime]::MinValue

        if ($cfg.AcilistaTemizle) {
            $sonTemizlik = Baslangic-Temizligi $cfg
        }

        Log "Izleme basladi. Esik: $($cfg.EsikMB) MB, kontrol: $($cfg.KontrolSaniye) sn"
        $bekleSn = [math]::Max(10, [int]$cfg.KontrolSaniye)
        while ($true) {
            Start-Sleep -Seconds $bekleSn
            # Dongunun tamami korumali: beklenmedik bir hata gorevi oldurmez, sadece loglanir
            try {
                $cfg = Ayar-Yukle                   # her turda ayari tekrar oku
                $bekleSn = [math]::Max(10, [int]$cfg.KontrolSaniye)
                if (-not $cfg.OtomatikCalisma) { Log 'Otomatik calisma kapatildi, cikiliyor.'; break }
                if (-not $cfg.EsikKontrolu) { continue }

                $boyut   = Onbellek-MB
                $bekleme = ((Get-Date) - $sonTemizlik).TotalMinutes
                if (Temizlik-Gerekli $boyut ([int]$cfg.EsikMB) $bekleme ([int]$cfg.BeklemeDakika)) {
                    Log "Esik asildi ($boyut MB >= $($cfg.EsikMB) MB), temizleniyor."
                    [void](Temizle $cfg)
                    $sonTemizlik = Get-Date
                }
            } catch {
                Log "HATA: $($_.Exception.Message)"
                $sonTemizlik = Get-Date   # hata olsa da bekleme suresine uy, her dakika denemesin
            }
        }
    }

    # 'simdi' komutunun tetikledigi yonetici yetkili gorev: bir kez temizler, sonucu dosyaya yazar
    'tek' {
        try {
            $cfg = Ayar-Yukle
            $r = Temizle $cfg
            "Temizlendi. Onbellek: $($r[0]) MB -> $($r[1]) MB" | Set-Content -Path $SonucYolu
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
        Write-Host 'Kuruldu. Her oturum acilisinda otomatik calisacak ve su an da baslatildi.'
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
        Write-Host 'Gorevler silindi.'
    }

    'kapat' {
        Ac-Kapat-Veya-Hata $false
        Write-Host 'Otomatik ozellik KAPATILDI. (Tekrar acmak icin: ac)'
    }

    'ac' {
        if (-not (Get-ScheduledTask -TaskName $GorevAdi -ErrorAction SilentlyContinue)) {
            Write-Host "Gorev kurulu degil. Once 'kur' komutunu calistir."
        } else {
            Ac-Kapat-Veya-Hata $true
            Write-Host 'Otomatik ozellik ACILDI ve baslatildi.'
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
            $bitis = (Get-Date).AddSeconds(120)
            while (-not (Test-Path $SonucYolu) -and (Get-Date) -lt $bitis) { Start-Sleep -Milliseconds 500 }
            if (Test-Path $SonucYolu) {
                Start-Sleep -Milliseconds 300
                Get-Content $SonucYolu | Write-Host
                Remove-Item $SonucYolu -ErrorAction SilentlyContinue   # okunduktan sonra sil
            } else {
                Write-Host 'Sonuc 120 sn icinde gelmedi. Ayrinti icin log.txt dosyasina bak.'
            }
        } else {
            # Hizli temizlik gorevi henuz kurulu degil: yonetici izni isteyen yedek yontem
            Write-Host "Not: Izin sormamasi icin bir kereye mahsus 'kur' komutunu calistir."
            Yonetici-Iste
            $cfg = Ayar-Yukle
            $r = Temizle $cfg
            Write-Host "Temizlendi. Onbellek: $($r[0]) MB -> $($r[1]) MB"
        }
    }

    'durum' {
        $cfg = Ayar-Yukle
        Write-Host '--- Ayarlar ---'
        $cfg | Format-List | Out-String | Write-Host
        $gorev = Get-ScheduledTask -TaskName $GorevAdi -ErrorAction SilentlyContinue
        Write-Host ("Gorev kurulu mu : {0}" -f [bool]$gorev)
        if ($gorev) { Write-Host ("Gorev durumu    : {0}" -f $gorev.State) }
        $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
        $mod = [math]::Round([double]$m.ModifiedPageListBytes / 1MB)
        Write-Host ("Onbellek toplami: {0} MB   <- esikle karsilastirilan deger (Standby + Modified)" -f (Onbellek-MB))
        Write-Host ("Anlik Standby   : {0} MB" -f (Standby-MB))
        Write-Host ("Anlik Modified  : {0} MB" -f $mod)
        Write-Host ("Esik            : {0} MB, bekleme: {1} dk, kontrol: {2} sn" -f $cfg.EsikMB, $cfg.BeklemeDakika, $cfg.KontrolSaniye)
        if (Test-Path $LogYolu) {
            Write-Host '--- log.txt son 8 satir ---'
            Get-Content $LogYolu | Select-Object -Last 8 | Write-Host
        }
    }
}

if ($Bekle) { Read-Host 'Kapatmak icin Enter tusuna bas' | Out-Null }
