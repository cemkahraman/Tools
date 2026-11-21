# SQLite telemetrisi ve tarayicida cevrimdisi acilan HTML raporlari.
$TelemetriYolu = Join-Path $KlasorYolu 'telemetri.sqlite'
$RaporYolu = Join-Path $KlasorYolu 'report.html'
$HaftalikRaporYolu = Join-Path $KlasorYolu 'haftalik-rapor.html'

function Sqlite-Calistir([string]$sql) {
    if (-not ('RAMMap.Sqlite' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace RAMMap {
    public static class Sqlite {
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int RowCallback(IntPtr context, int count, IntPtr values, IntPtr columns);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_open16([MarshalAs(UnmanagedType.LPWStr)] string path, out IntPtr db);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_exec(IntPtr db, string sql, RowCallback callback, IntPtr context, IntPtr error);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_errmsg16(IntPtr db);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr db);

        // Sorgular ve sonuclar yalnizca ASCII SQL, sayilar ve ISO tarihler kullanir.
        public static List<string[]> Execute(string path, string sql) {
            var rows = new List<string[]>();
            RowCallback readRow = delegate(IntPtr context, int count, IntPtr values, IntPtr columns) {
                var row = new string[count];
                for (int i = 0; i < count; i++) {
                    row[i] = Marshal.PtrToStringAnsi(Marshal.ReadIntPtr(values, i * IntPtr.Size));
                }
                rows.Add(row);
                return 0;
            };
            IntPtr db;
            int status = sqlite3_open16(path, out db);
            try {
                if (status == 0) status = sqlite3_busy_timeout(db, 2000);
                if (status == 0) status = sqlite3_exec(db, sql, readRow, IntPtr.Zero, IntPtr.Zero);
                if (status != 0) {
                    string message = db == IntPtr.Zero ? "" : Marshal.PtrToStringUni(sqlite3_errmsg16(db));
                    throw new InvalidOperationException("SQLite (" + status + "): " + message);
                }
                return rows;
            } finally {
                if (db != IntPtr.Zero) sqlite3_close(db);
            }
        }
    }
}
'@
    }
    return ,([RAMMap.Sqlite]::Execute($TelemetriYolu, $sql))
}

function Telemetri-Kaydet($olcum, $hiz) {
    $kultur = [Globalization.CultureInfo]::InvariantCulture
    $zaman = ([datetimeoffset]$olcum.Zaman).ToUnixTimeSeconds()
    $onbellek = $olcum.OnbellekMB.ToString('0', $kultur)
    $kullanim = $olcum.KullanimYuzde.ToString('0.00', $kultur)
    $cpu = $olcum.CpuYuzde.ToString('0.00', $kultur)
    $hizSql = if ($null -eq $hiz) { 'NULL' } else { $hiz.ToString('0.0000', $kultur) }
    [void](Sqlite-Calistir @"
CREATE TABLE IF NOT EXISTS olcum (
    zaman INTEGER PRIMARY KEY, onbellek_mb INTEGER NOT NULL,
    kullanim_yuzde REAL NOT NULL, cpu_yuzde REAL NOT NULL, hiz_mb_sn REAL
);
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO olcum VALUES ($zaman, $onbellek, $kullanim, $cpu, $hizSql);
DELETE FROM olcum WHERE zaman < $zaman - 8 * 86400;
COMMIT;
"@)
}

function Rapor-Belgesi([string]$baslik, [string]$govde) {
    return @"
<!doctype html>
<html lang="tr">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$baslik | RAMMap</title>
<style>
    * { box-sizing: border-box; }
    body { color: #102733; background: #ecf3f4; font: 1rem/1.55 system-ui, sans-serif; margin: 0; }
    main { width: min(100% - 2rem, 52rem); margin: clamp(1rem, 6vw, 4rem) auto; }
    header, section { padding: clamp(1.25rem, 4vw, 2.25rem); border-radius: 1rem; margin-bottom: 1rem; }
    header { color: #fff; background: #123a46; }
    section { background: #fff; border: 1px solid #ccdbe0; }
    h1, h2, p { margin: 0 0 .6rem; }
    h1 { font-size: clamp(1.6rem, 5vw, 2.5rem); line-height: 1.15; }
    .summary { font-size: 1.6rem; font-weight: 700; color: #005f58; }
    .row { display: grid; grid-template-columns: 5rem minmax(0, 1fr) 6rem; align-items: center; gap: .6rem; margin: .6rem 0; }
    .row strong { text-align: end; font-variant-numeric: tabular-nums; }
    meter { display: block; width: 100%; height: 1.1rem; }
    meter::-webkit-meter-bar { background: #e5edf0; border: 0; border-radius: 1rem; }
    meter::-webkit-meter-optimum-value { background: #087e76; border-radius: 1rem; }
    meter::-moz-meter-bar { background: #087e76; border-radius: 1rem; }
    small { color: #47616b; }
    code { overflow-wrap: anywhere; }
</style>
<main>
<header><h1>$baslik</h1><p>RAMMap &middot; $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')</p></header>
$govde
</main>
</html>
"@
}

function Rapor-Cubugu([string]$etiket, [double]$deger, [double]$tavan, [string]$birim) {
    $kultur = [Globalization.CultureInfo]::InvariantCulture
    $sayi = $deger.ToString('0.##', $kultur)
    $olcek = $tavan.ToString('0.##', $kultur)
    return "<div class='row'><span>$etiket</span><meter aria-label='$etiket' value='$sayi' max='$olcek'></meter><strong>$deger $birim</strong></div>"
}

function Temizlik-Raporu-Yaz($once, $sonra, $argumanlar) {
    $tavan = [math]::Max(1, [math]::Max($once.OnbellekMB, $sonra.OnbellekMB))
    $fark = $once.OnbellekMB - $sonra.OnbellekMB
    $ozet = if ($fark -ge 0) { "$fark MB azalma" } else { "$(-$fark) MB art&#305;&#351;" }
    $govde = @"
<section>
    <h2>&Ouml;nbellek &ouml;l&ccedil;&uuml;m&uuml;</h2>
    <p class="summary">$ozet</p>
    $(Rapor-Cubugu '&Ouml;nce' $once.OnbellekMB $tavan 'MB')
    $(Rapor-Cubugu 'Sonra' $sonra.OnbellekMB $tavan 'MB')
    <p><small>Standby ve Modified listelerinin toplam&#305; &ouml;l&ccedil;&uuml;ld&uuml;.</small></p>
    <p>RAMMap se&ccedil;enekleri <code>$($argumanlar -join ' ')</code></p>
</section>
<section>
    <h2>Standby &middot; Modified</h2>
    <p>&Ouml;nce</p>
    $(Rapor-Cubugu 'Standby' $once.StandbyMB $tavan 'MB')
    $(Rapor-Cubugu 'Modified' $once.ModifiedMB $tavan 'MB')
    <p>Sonra</p>
    $(Rapor-Cubugu 'Standby' $sonra.StandbyMB $tavan 'MB')
    $(Rapor-Cubugu 'Modified' $sonra.ModifiedMB $tavan 'MB')
</section>
"@
    Dosya-Atomik-Yaz $RaporYolu (Rapor-Belgesi 'Son temizlik' $govde)
}

function Haftalik-Rapor-Yaz {
    if (-not (Test-Path -LiteralPath $TelemetriYolu -PathType Leaf)) {
        throw 'Henuz SQLite olcumu yok. TelemetriAktif ayarini true yapip izlemeyi baslatin.'
    }
    $simdi = [datetimeoffset]::Now
    $baslangic = $simdi.AddDays(-7).ToUnixTimeSeconds()
    $araliklar = foreach ($fark in 7..0) {
        # Yerel gun baslangiclarini ayri donustur; saat degisimi olan haftalari da kapsa.
        $gun = $simdi.LocalDateTime.Date.AddDays(-$fark)
        $ilk = [math]::Max($baslangic, ([datetimeoffset]$gun).ToUnixTimeSeconds())
        $son = [math]::Min($simdi.ToUnixTimeSeconds() + 1, ([datetimeoffset]$gun.AddDays(1)).ToUnixTimeSeconds())
        "('$($gun.ToString('dd.MM', [Globalization.CultureInfo]::InvariantCulture))', $ilk, $son)"
    }
    $satirlar = Sqlite-Calistir @"
WITH gunler(gun, ilk, son) AS (VALUES $($araliklar -join ', '))
SELECT gun, round(avg(kullanim_yuzde), 1), max(kullanim_yuzde), count(*)
FROM gunler JOIN olcum ON zaman >= ilk AND zaman < son
GROUP BY ilk, gun ORDER BY ilk;
"@
    $cubuklar = foreach ($satir in $satirlar) {
        $ortalama = [double]::Parse($satir[1], [Globalization.CultureInfo]::InvariantCulture)
        $enYuksek = [double]::Parse($satir[2], [Globalization.CultureInfo]::InvariantCulture)
        "$(Rapor-Cubugu $satir[0] $ortalama 100 '%')<small>En y&uuml;ksek %$enYuksek &middot; $($satir[3]) &ouml;l&ccedil;&uuml;m</small>"
    }
    if (-not $cubuklar) { $cubuklar = 'Son 7 g&uuml;n i&ccedil;in &ouml;l&ccedil;&uuml;m yok.' }
    $govde = "<section><h2>G&uuml;nl&uuml;k ortalama fiziksel bellek kullan&#305;m&#305;</h2>$($cubuklar -join [Environment]::NewLine)</section>"
    Dosya-Atomik-Yaz $HaftalikRaporYolu (Rapor-Belgesi 'Son 7 g&uuml;n' $govde)
}
