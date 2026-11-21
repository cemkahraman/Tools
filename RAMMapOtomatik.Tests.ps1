# RAMMapOtomatik.Tests.ps1  -  Pester 5 testleri
#
# CALISTIRMA (RAMMapOtomatik.ps1 ile ayni klasorde):
#   Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck     (bir kereye mahsus)
#   Invoke-Pester .\RAMMapOtomatik.Tests.ps1 -Output Detailed
#
# Testler gercek config.json, log.txt, gorevler ve RAMMap'e DOKUNMAZ:
# gecici bir klasor kullanilir, sistem cagrilari (Start-Process, gorev cmdlet'leri,
# WMI, Start-Sleep) mock'lanir. Yonetici yetkisi gerekmez.

BeforeAll {
    $script:TestKlasoru = Join-Path ([IO.Path]::GetTempPath()) ('rammap_test_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestKlasoru | Out-Null
    $env:RAMMAP_TEST_KLASOR = $script:TestKlasoru

    # Betigi sadece fonksiyonlari tanimlayacak sekilde yukle
    . (Join-Path $PSScriptRoot 'RAMMapOtomatik.ps1')

    # GUVENLIK: betik test klasorunu kullanmiyorsa (eski surum), gercek config/log dosyalarini
    # bozmamak icin testleri HEMEN durdur.
    if ($ConfigYolu -notlike "$($script:TestKlasoru)*") {
        throw 'RAMMapOtomatik.ps1 eski surum gorunuyor (test klasorunu kullanmiyor). Son surumu bu klasore kopyalayip tekrar dene. Testler gercek dosyalara dokunmamak icin durduruldu.'
    }

    # WMI'nin dondurdugu bellek nesnesini taklit eder
    function Yeni-Bellek([double]$standbyMB, [double]$modifiedMB = 0) {
        [pscustomobject]@{
            StandbyCacheNormalPriorityBytes = $standbyMB * 1MB
            StandbyCacheReserveBytes        = 0
            StandbyCacheCoreBytes           = 0
            ModifiedPageListBytes           = $modifiedMB * 1MB
        }
    }
}

AfterAll {
    Remove-Item Env:\RAMMAP_TEST_KLASOR -ErrorAction SilentlyContinue
    $testTamYol = [IO.Path]::GetFullPath($script:TestKlasoru)
    $geciciKok = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($testTamYol.StartsWith($geciciKok, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $testTamYol) -match '^rammap_test_[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $testTamYol -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'RAMMapOtomatik' {

BeforeEach {
    # Her testten once temiz klasor, beklemeler anlik
    if ([IO.Path]::GetFullPath($script:TestKlasoru) -ne [IO.Path]::GetFullPath($KlasorYolu) -or
        (Split-Path -Leaf $script:TestKlasoru) -notmatch '^rammap_test_[a-f0-9]{32}$') {
        throw 'Guvenli test klasoru dogrulanamadi.'
    }
    Get-ChildItem -Path $script:TestKlasoru -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Mock Start-Sleep {}
}

# ---------------------------------------------------------------------------
Describe 'Temizlik-Gerekli (esik karari)' {
    It 'esik asildi ve bekleme doldu -> <beklenen>' -TestCases @(
        @{ boyut = 13000; esik = 12288; gecen = 45; bekleme = 30; beklenen = $true  }   # ikisi de tamam
        @{ boyut = 8000;  esik = 12288; gecen = 45; bekleme = 30; beklenen = $false }   # esigin altinda
        @{ boyut = 13000; esik = 12288; gecen = 5;  bekleme = 30; beklenen = $false }   # bekleme dolmadi
        @{ boyut = 12288; esik = 12288; gecen = 30; bekleme = 30; beklenen = $true  }   # sinirda: >= kabul
        @{ boyut = 12287; esik = 12288; gecen = 30; bekleme = 30; beklenen = $false }   # esigin 1 MB altinda
    ) {
        Temizlik-Gerekli $boyut $esik $gecen $bekleme | Should -Be $beklenen
    }

    It 'hic temizlik yapilmamissa (cok buyuk gecen sure) bekleme engel olmaz' {
        $gecen = ((Get-Date) - [datetime]::MinValue).TotalMinutes
        Temizlik-Gerekli 20000 12288 $gecen 30 | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
Describe 'Ayar-Yukle' {
    It 'config yoksa varsayilanlarla olusturur' {
        $cfg = Ayar-Yukle
        Test-Path (Join-Path $script:TestKlasoru 'config.json') | Should -BeTrue
        $cfg.OtomatikCalisma | Should -BeTrue
        $cfg.EsikMB          | Should -Be 12288
        $cfg.BeklemeDakika   | Should -Be 30
        $cfg.Parametreler    | Should -Be '-Em -Et'
    }

    It 'eksik anahtarlari varsayilanla tamamlar, mevcutlari korur' {
        Set-Content -Path (Join-Path $script:TestKlasoru 'config.json') -Value '{ "EsikMB": 5000 }'
        $cfg = Ayar-Yukle
        $cfg.EsikMB        | Should -Be 5000
        $cfg.KontrolSaniye | Should -Be 60
        $cfg.BeklemeDakika | Should -Be 30
    }

    It "eski '-Es' degerini '-Et' yapar ve dosyaya yazar" {
        Set-Content -Path (Join-Path $script:TestKlasoru 'config.json') -Value '{ "Parametreler": "-Es" }'
        (Ayar-Yukle).Parametreler | Should -Be '-Et'
        $dosya = Get-Content (Join-Path $script:TestKlasoru 'config.json') -Raw | ConvertFrom-Json
        $dosya.Parametreler | Should -Be '-Et'
    }

    It 'bozuk JSON hata firlatmaz, varsayilana doner ve kopyasini saklar' {
        Set-Content -Path (Join-Path $script:TestKlasoru 'config.json') -Value '{ bozuk json,,, '
        { $script:sonuc = Ayar-Yukle } | Should -Not -Throw
        $script:sonuc.EsikMB | Should -Be 12288
        Test-Path (Join-Path $script:TestKlasoru 'config.bozuk.json') | Should -BeTrue
    }

    It 'bos config dosyasi hata firlatmaz' {
        Set-Content -Path (Join-Path $script:TestKlasoru 'config.json') -Value ''
        { $script:sonuc = Ayar-Yukle } | Should -Not -Throw
        $script:sonuc.OtomatikCalisma | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
Describe 'Ayar-Kaydet' {
    It 'kaydedilen degeri tekrar okuyabilir' {
        $cfg = Ayar-Yukle
        $cfg.EsikMB = 7777
        Ayar-Kaydet $cfg
        (Ayar-Yukle).EsikMB | Should -Be 7777
    }

    It 'geride gecici (.tmp) dosya birakmaz' {
        Ayar-Kaydet (Ayar-Yukle)
        Test-Path (Join-Path $script:TestKlasoru 'config.json.tmp') | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
Describe 'RamMap-Bul' {
    BeforeEach {
        $script:cfgBos = [pscustomobject]@{ RamMapYolu = '' }
    }

    It 'dosya yolu verilirse onu dondurur' {
        $exe = Join-Path $script:TestKlasoru 'ozel.exe'
        New-Item -ItemType File -Path $exe | Out-Null
        RamMap-Bul ([pscustomobject]@{ RamMapYolu = $exe }) | Should -Be (Resolve-Path $exe).Path
    }

    It 'klasor yolu verilirse icindeki RAMMap64.exe bulunur' {
        $alt = Join-Path $script:TestKlasoru 'alt'
        New-Item -ItemType Directory -Path $alt | Out-Null
        $exe = Join-Path $alt 'RAMMap64.exe'
        New-Item -ItemType File -Path $exe | Out-Null
        RamMap-Bul ([pscustomobject]@{ RamMapYolu = $alt }) | Should -Be (Resolve-Path $exe).Path
    }

    It 'klasorde ikisi de varsa RAMMap64.exe tercih edilir' {
        $alt = Join-Path $script:TestKlasoru 'alt'
        New-Item -ItemType Directory -Path $alt | Out-Null
        New-Item -ItemType File -Path (Join-Path $alt 'RAMMap.exe')   | Out-Null
        New-Item -ItemType File -Path (Join-Path $alt 'RAMMap64.exe') | Out-Null
        RamMap-Bul ([pscustomobject]@{ RamMapYolu = $alt }) | Should -BeLike '*RAMMap64.exe'
    }

    It 'yol bos ise betigin klasorune bakar' {
        $exe = Join-Path $script:TestKlasoru 'RAMMap64.exe'
        New-Item -ItemType File -Path $exe | Out-Null
        RamMap-Bul $script:cfgBos | Should -Be (Resolve-Path $exe).Path
    }

    It 'goreli dosya yolunu calisma dizininden bagimsiz cozer' {
        $alt = Join-Path $script:TestKlasoru 'alt'
        New-Item -ItemType Directory -Path $alt | Out-Null
        $exe = Join-Path $alt 'RAMMap.exe'
        New-Item -ItemType File -Path $exe | Out-Null
        Push-Location $env:SystemRoot
        try {
            RamMap-Bul ([pscustomobject]@{ RamMapYolu = 'alt\RAMMap.exe' }) | Should -Be $exe
            RamMap-Bul ([pscustomobject]@{ RamMapYolu = 'alt' }) | Should -Be $exe
        } finally { Pop-Location }
    }

    It 'yanlis yol verilse bile betigin klasorune geri duser' {
        $exe = Join-Path $script:TestKlasoru 'RAMMap64.exe'
        New-Item -ItemType File -Path $exe | Out-Null
        RamMap-Bul ([pscustomobject]@{ RamMapYolu = 'C:\yok\boyle\bir\yol' }) | Should -Be (Resolve-Path $exe).Path
    }

    It 'hicbir yerde yoksa anlamli hata verir' {
        { RamMap-Bul $script:cfgBos } | Should -Throw '*RAMMap bulunamadi*'
    }
}

# ---------------------------------------------------------------------------
Describe 'Bellek olcumu' {
    It 'Standby-MB sadece standby listesini sayar' {
        Mock Get-CimInstance { Yeni-Bellek 1000 500 }
        Standby-MB | Should -Be 1000
    }

    It 'Onbellek-MB standby + modified toplamidir' {
        Mock Get-CimInstance { Yeni-Bellek 1000 500 }
        Onbellek-MB | Should -Be 1500
    }
}

# ---------------------------------------------------------------------------
Describe 'Temizle' {
    BeforeEach {
        # Sahte RAMMap sureci: WaitForExit sonucu ve Kill cagrisi izlenebilir
        $script:beklemeSonucu = $true
        $script:oldurulen     = $false
        $script:sahteSurec    = [pscustomobject]@{ ExitCode = 0 }
        Add-Member -InputObject $script:sahteSurec -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) return $script:beklemeSonucu }
        Add-Member -InputObject $script:sahteSurec -MemberType ScriptMethod -Name Kill        -Value { $script:oldurulen = $true }

        # Ilk olcum 6000 MB (5000 standby + 1000 modified), sonrakiler 400 MB
        $script:cimSayac = 0
        Mock Get-CimInstance {
            $script:cimSayac++
            if ($script:cimSayac -eq 1) { Yeni-Bellek 5000 1000 } else { Yeni-Bellek 400 }
        }
        Mock Start-Process { return $script:sahteSurec }
        Mock Set-ItemProperty {}
        Mock New-Item {} -ParameterFilter { $Path -like 'HKCU:*' }
        Mock Test-Path { $true } -ParameterFilter { $Path -like 'HKCU:*' }
        Mock Bildirim-Gonder {}

        New-Item -ItemType File -Path (Join-Path $script:TestKlasoru 'RAMMap64.exe') | Out-Null
    }

    It 'config deki her anahtari AYRI ayri calistirir (-Em sonra -Et)' {
        $cfg = Ayar-Yukle
        Temizle $cfg | Out-Null
        Should -Invoke Start-Process -Times 2 -Exactly
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '-Em' -and $ArgumentList.Count -eq 1 }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '-Et' -and $ArgumentList.Count -eq 1 }
    }

    It 'tek anahtar verilirse tek kez calistirir' {
        $cfg = Ayar-Yukle
        $cfg.Parametreler = '-Et'
        Temizle $cfg | Out-Null
        Should -Invoke Start-Process -Times 1 -Exactly
    }

    It 'gecersiz parametrelerde hicbir yan etki baslatmaz: <deger>' -TestCases @(
        @{ deger = '-Em -Et; calc.exe' }
        @{ deger = '-Em -Unknown' }
        @{ deger = '' }
        @{ deger = $null }
        @{ deger = @('-Em', '-Et') }
    ) {
        $cfg = Ayar-Yukle
        $cfg.Parametreler = $deger
        { Temizle $cfg } | Should -Throw
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
        Should -Invoke Get-CimInstance -Times 0 -Exactly
    }

    It 'bildirim varsayilan olarak kapalidir' {
        Temizle (Ayar-Yukle) | Out-Null
        Should -Invoke Bildirim-Gonder -Times 0 -Exactly
    }

    It 'basarili temizlikten sonra istege bagli bildirim gonderir' {
        $cfg = Ayar-Yukle
        $cfg.BildirimAktif = $true
        Temizle $cfg | Out-Null
        Should -Invoke Bildirim-Gonder -Times 1 -Exactly -ParameterFilter { $once -eq 6000 -and $sonra -eq 400 }
    }

    It 'bildirim hatasi temizlik sonucunu bozmaz' {
        Mock Bildirim-Gonder { throw 'Bildirim kapali' }
        $cfg = Ayar-Yukle
        $cfg.BildirimAktif = $true
        $r = Temizle $cfg
        $r.Count | Should -Be 2
        $r[1] | Should -Be 400
        Get-Content $LogYolu -Raw | Should -Match 'Bildirim gonderilemedi'
    }

    It 'basarisiz temizlikte bildirim gondermez' {
        $cfg = Ayar-Yukle
        $cfg.BildirimAktif = $true
        $script:sahteSurec.ExitCode = 5
        { Temizle $cfg } | Should -Throw
        Should -Invoke Bildirim-Gonder -Times 0 -Exactly
    }

    It 'onceki ve sonraki boyutlari dondurur' {
        $cfg = Ayar-Yukle
        $r = Temizle $cfg
        $r[0] | Should -Be 6000
        $r[1] | Should -Be 400
    }

    It 'sonucu log a yazar' {
        $cfg = Ayar-Yukle
        Temizle $cfg | Out-Null
        Get-Content (Join-Path $script:TestKlasoru 'log.txt') -Raw | Should -Match 'Temizlendi\. Onbellek: 6000 MB -> 400 MB'
    }

    It 'RAMMap 60 sn icinde kapanmazsa zorla kapatir' {
        $script:beklemeSonucu = $false
        $cfg = Ayar-Yukle
        { Temizle $cfg } | Should -Throw '*60 saniye icinde tamamlanmadi*'
        $script:oldurulen | Should -BeTrue
    }

    It 'RAMMap kapaninca zorla kapatma yapilmaz' {
        $cfg = Ayar-Yukle
        Temizle $cfg | Out-Null
        $script:oldurulen | Should -BeFalse
    }

    It 'RAMMap sifir disi cikis kodunda basarisiz sayilir ve sonraki anahtara gecmez' {
        $script:sahteSurec.ExitCode = 5
        $cfg = Ayar-Yukle
        { Temizle $cfg } | Should -Throw '*cikis kodu: 5*'
        Should -Invoke Start-Process -Times 1 -Exactly
    }

    It 'RAMMap bulunamazsa hata verir ve hicbir sey calistirmaz' {
        Remove-Item (Join-Path $script:TestKlasoru 'RAMMap64.exe')
        $cfg = Ayar-Yukle
        { Temizle $cfg } | Should -Throw '*RAMMap bulunamadi*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}

# ---------------------------------------------------------------------------
Describe 'Ac-Kapat' {
    BeforeEach {
        Mock Get-ScheduledTask  { [pscustomobject]@{ TaskName = 'sahte' } }
        Mock Start-ScheduledTask {}
        Mock Stop-ScheduledTask  {}
    }

    It 'ac: config i true yapar ve gorevi baslatir' {
        $cfg = Ayar-Yukle; $cfg.OtomatikCalisma = $false; Ayar-Kaydet $cfg
        Ac-Kapat $true | Should -BeTrue
        (Ayar-Yukle).OtomatikCalisma | Should -BeTrue
        Should -Invoke Start-ScheduledTask -Times 1 -Exactly
        Should -Invoke Stop-ScheduledTask  -Times 0 -Exactly
    }

    It 'kapat: config i false yapar ve gorevi durdurur' {
        Ac-Kapat $false | Should -BeTrue
        (Ayar-Yukle).OtomatikCalisma | Should -BeFalse
        Should -Invoke Stop-ScheduledTask  -Times 1 -Exactly
        Should -Invoke Start-ScheduledTask -Times 0 -Exactly
    }

    It 'gorev kurulu degilse sadece config i degistirir, hata vermez' {
        Mock Get-ScheduledTask { $null }
        Ac-Kapat $false | Should -BeTrue
        (Ayar-Yukle).OtomatikCalisma | Should -BeFalse
        Should -Invoke Start-ScheduledTask -Times 0 -Exactly
        Should -Invoke Stop-ScheduledTask  -Times 0 -Exactly
    }

    It 'gorev baslatilamazsa $false doner (yonetici yedegi devreye girsin diye)' {
        Mock Start-ScheduledTask { throw 'Erisim engellendi' }
        Ac-Kapat $true | Should -BeFalse
    }

    It 'gorev durdurulamazsa $false doner' {
        Mock Stop-ScheduledTask { throw 'Erisim engellendi' }
        Ac-Kapat $false | Should -BeFalse
    }

    It 'ikinci deneme de basarisizsa basari mesaji yerine hata verir' {
        Mock Ac-Kapat { return $false }
        Mock Yonetici-Iste {}
        { Ac-Kapat-Veya-Hata $true } | Should -Throw '*acilamadi*'
        Should -Invoke Yonetici-Iste -Times 1 -Exactly
    }

    It 'yonetici denemesinden sonra basariliysa hata vermez' {
        $script:deneme = 0
        Mock Ac-Kapat {
            $script:deneme++
            return ($script:deneme -eq 2)
        }
        Mock Yonetici-Iste {}
        { Ac-Kapat-Veya-Hata $false } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Baslangic-Temizligi' {
    It 'basarili temizlikte son temizlik zamanini dondurur' {
        Mock Temizle { return @(6000, 400) }
        (Baslangic-Temizligi ([pscustomobject]@{})) | Should -BeGreaterThan ([datetime]::MinValue)
    }

    It 'basarisiz temizlikte bekleme suresini baslatmaz' {
        Mock Temizle { throw 'RAMMap hata verdi' }
        (Baslangic-Temizligi ([pscustomobject]@{})) | Should -Be ([datetime]::MinValue)
        Get-Content (Join-Path $script:TestKlasoru 'log.txt') -Raw | Should -Match 'Baslangic temizligi basarisiz'
    }
}

# ---------------------------------------------------------------------------
Describe 'Log' {
    It '1 MB boyutunda dosyayi tek arsive dondurur' {
        $yol = Join-Path $script:TestKlasoru 'log.txt'
        [IO.File]::WriteAllText($yol, ('x' * 1MB))
        Log 'ilk yeni'
        Test-Path "$yol.1" | Should -BeTrue
        (Get-Item "$yol.1").Length | Should -BeGreaterOrEqual 1MB
        Get-Content $yol -Raw | Should -Match 'ilk yeni'
        [IO.File]::WriteAllText($yol, ('y' * 1MB))
        Log 'ikinci yeni'
        (Get-Content "$yol.1" -Raw).StartsWith('y') | Should -BeTrue
        Get-Content $yol -Raw | Should -Match 'ikinci yeni'
        Test-Path "$yol.2" | Should -BeFalse
    }

    It 'baska yazici kilidi tutarken dosyaya dokunmaz' {
        $kilit = [IO.File]::Open("$LogYolu.lock", 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            { Log 'cakisan kayit' } | Should -Not -Throw
            Test-Path $LogYolu | Should -BeFalse
        } finally { $kilit.Dispose() }
        Log 'kilit serbest'
        Get-Content $LogYolu -Raw | Should -Match 'kilit serbest'
    }
    It 'satiri tarih damgasiyla log dosyasina ekler' {
        Log 'merhaba dunya'
        Get-Content (Join-Path $script:TestKlasoru 'log.txt') -Raw | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s+merhaba dunya'
    }

    It '500 satiri gecince son 300 satira kisaltir' {
        $yol = Join-Path $script:TestKlasoru 'log.txt'
        1..600 | ForEach-Object { "eski satir $_" } | Set-Content -Path $yol
        Log 'yeni'
        (Get-Content $yol).Count | Should -BeLessOrEqual 301
        Get-Content $yol -Raw | Should -Match 'yeni'
    }

    It 'log dosyasi kilitliyse hata firlatmaz' {
        $yol = Join-Path $script:TestKlasoru 'log.txt'
        $fs = [IO.File]::Open($yol, 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            { Log 'kilitli dosya' } | Should -Not -Throw
        } finally {
            $fs.Close()
        }
    }
}

Describe 'Pano-Goster' {
    It 'gorev yokken de durumu gosterir ve temizlik baslatmaz' {
        Mock Get-ScheduledTask { $null }
        Mock Write-Host {}
        Mock Temizle {}
        Pano-Goster (Ayar-Yukle) 1234
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like '*1234 MB*' }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like '*Kurulu degil*' }
        Should -Invoke Temizle -Times 0 -Exactly
    }
}

Describe 'Bildirim-Kimligi' {
    It 'kayitli PowerShell kimligini secer' {
        Mock Get-StartApps {
            [pscustomobject]@{ AppID = 'ilgisiz.uygulama' }
            [pscustomobject]@{ AppID = '{sistem}\WindowsPowerShell\v1.0\powershell.exe' }
        }
        Bildirim-Kimligi | Should -Be '{sistem}\WindowsPowerShell\v1.0\powershell.exe'
    }

    It 'kayit yoksa anlasilir hata verir' {
        Mock Get-StartApps { @() }
        { Bildirim-Kimligi } | Should -Throw '*kimligi bulunamadi*'
    }
}

}   # dis Describe 'RAMMapOtomatik' sonu
