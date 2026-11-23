# RAMMapOtomatik — oturum kuralları

Bu dosya `C:\Tools` projesinde yeni Codex oturumları için kısa başlangıç bağlamıdır. Ayrıntılı mimari, mevcut durum ve yol haritası için yalnızca ilgili olduğunda [PROJE_REHBERI.md](PROJE_REHBERI.md) dosyasını aç. Gerçek davranış için güncel kod ve yapılandırma esastır; tarihli durum notlarını yeniden doğrula.

## İşe başlamadan önce

- Kullanıcının isteğini ve değişen dosyaları belirle. İlgili kodu hedefli `rg` aramasıyla oku; tüm betiği veya günlükleri her oturumda baştan sona dökme.
- `config.json` kullanıcı ayarıdır; `log.txt`, `son_sonuc.txt`, kilit dosyaları, SQLite verisi ve HTML raporlar çalışma verisidir. İstenmedikçe bunları değiştirme veya paylaşma.
- `durum` dahil bazı komutlar ayar/durum dosyası oluşturabilir. Yalnızca inceleme gerekiyorsa önce dosya ve kod oku. `simdi`, `kur`, `ac`, `kapat`, `kaldir` komutlarını yalnızca görev gerektiriyorsa çalıştır; sistem ve zamanlanmış görev etkisini değerlendir.
- `AnalizRaporu.md` 20.11.2026 tarihli bir anlık görüntüdür; eski önerileri güncel eksik sanma.

## Uygulama ve doğrulama

- PowerShell, dört boşluk girinti, mevcut Türkçe adlandırma ve uygun yerlerde `Verb-Noun` işlev biçimini kullan. Dosya yollarını betik dizinine göre çöz. Görev planlama, yeniden deneme, atomik ayar yazımı ve kilitleme açıklamalarını koru.
- `Ayar-Yukle` varsayımları ile `config.json` anahtarlarını uyumlu tut; JSON geçerli ve UTF-8 olsun. Makineye özgü yolu kodun varsayılanına yerleştirme.
- Davranış değişikliğinde ilgili Pester testlerini güncelle ve `Invoke-Pester .\RAMMapOtomatik.Tests.ps1 -Output Detailed` çalıştır. Sonra değişen PowerShell dosyalarını `[System.Management.Automation.Language.Parser]::ParseFile(...)` ile denetle. Canlı RAMMap temizliği ve zamanlanmış görev denemesi yalnızca gerçekten gerektiğinde yapılır; otomatik test ile canlı doğrulamayı ayrı bildir.
- Değişiklikten sonra ilgili ise `Komutlar.txt`, bu dosya ve `PROJE_REHBERI.md` içindeki durum/yol haritasını güncelle. Yalnızca doğrulanmış işleri “tamamlandı” olarak işaretle; tarih ve kalan doğrulama ihtiyacını yaz.
- Sonuçta değişen dosyaları, nedenini, kontrolleri ve kalan somut riski kısaca belirt. Git geçmişi doğrulanmadıkça commit geleneği varsayma; PR için kısa emir kipinde başlık, davranış ve test özeti kullan.

## Kapsam

Ana komutlar: `kur`, `kaldir`, `ac`, `kapat`, `durum`, `pano`, `simdi`, `yardim`, `rapor`. `calistir` ve `tek` iç görev yollarıdır. Komutların kaynağı betikteki `ValidateSet` ve `switch` bloklarıdır. Ayrı derleme veya paket yöneticisi yoktur.
