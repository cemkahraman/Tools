# RAMMapOtomatik proje rehberi

Son gözden geçirme: 22.11.2026. Bu belge yeni oturumlarda gerektiğinde okunacak ayrıntılı bağlamdır. Kısa ve otomatik başlangıç kuralları [AGENTS.md](AGENTS.md) içindedir. Tarihli notlar çalışma anındaki kanıttır; güncel kod, test ve sistem durumunun yerini almaz.

## Amaç ve dosyalar

Windows'ta RAMMap ile Standby ve Modified bellek listelerini seçilen kurallara göre temizleyen PowerShell yardımcı aracı. Oturum açılışında ve düzenli aralıklarla çalışabilen zamanlanmış görevler kurabilir. `config.json` ayarları betikle aynı dizinden yüklenir; günlük, sonuç, telemetri ve HTML rapor dosyaları çalışma sırasında oluşur. RAMMap komutları sistem genelini etkileyebilir.

| Dosya | Görev |
| --- | --- |
| `RAMMapOtomatik.ps1` | Komutlar, ayarlar, RAMMap çağrısı, bellek ölçümü, zamanlanmış görevler ve temizlik akışı |
| `RAMMapRapor.ps1` | İsteğe bağlı SQLite telemetrisi ve çevrimdışı HTML rapor üretimi |
| `RAMMapOtomatik.Tests.ps1` | Pester 5 testleri; geçici dizin ve sistem çağrısı mock'ları kullanır |
| `config.json` | Kullanıcının çalışma ayarları; betik varsayımları `Ayar-Yukle` içindedir |
| `Komutlar.txt` | Kullanıcı komutları ve kullanım notları |
| `AnalizRaporu.md` | Önceki analiz; güncel yapılacaklar listesi sayılmamalı |
| `RAMMap.exe` / `RAMMap64.exe` | RAMMap ikili dosyası; kullanılacak dosya `RamMap-Bul` tarafından bulunur |

Çalışma verileri: `log.txt`, `son_sonuc.txt`, kilit dosyaları, varsa SQLite veritabanı ve üretilen HTML raporları. Bunları kaynak kodla karıştırma. `RAMMap` alt klasöründe ürünün kendi belgeleri bulunabilir.

## Komut ve ayar özeti

Çalıştırma biçimi: `powershell -ExecutionPolicy Bypass -File .\RAMMapOtomatik.ps1 <komut>`.

| Komut | Etki |
| --- | --- |
| `yardim` | Kullanımı gösterir |
| `durum` | Ayar, bellek ve günlük durumunu gösterir; dosya yan etkilerini koddan doğrula |
| `pano` | Yaklaşık iki saniyede yenilenen izleme ekranı; temizlik çağırmaz |
| `simdi` | Tek seferlik gerçek temizlik başlatır |
| `kur` | Zamanlanmış görevleri kaydeder ve başlatır; yönetici yetkisi gerekebilir |
| `ac` / `kapat` | Otomatik çalışmayı açar / kapatır |
| `kaldir` | Zamanlanmış görevleri siler |
| `rapor` | SQLite ölçümlerinden haftalık HTML raporu oluşturur; veri varsa anlamlıdır |

`calistir` ve `tek` zamanlanmış görevler için iç komutlardır. Betikte açıkça izin verilen komutlar `ValidateSet` ve sondaki `switch` içinde görülür.

22.11.2026 tarihinde `config.json` içinde otomatik çalışma, açılış temizliği ve eşik kontrolü açık; eşik 12288 MB, kontrol aralığı 60 saniye, bekleme 30 dakika, RAMMap yolu boş, parametreler `-Em -Et`. Bildirim, dinamik eşik, öngörülü temizlik ve telemetri kapalı; HTML raporu açık. Bu değerler kullanıcı tarafından değiştirilebilir: bir işe başlamadan önce gerekliyse dosyayı yeniden oku. Parametre, öncelik, dışlama ve telemetri davranışının ayrıntısı için kodu incele.

## Zaman çizgisi ve yol haritası

### Öncesi — doğrulanmış geçmiş bağlam

- Önceki geliştirmelerde betik dizinine göre yol çözme, RAMMap argümanlarını izin listesiyle doğrulama, log döndürme/kilitleme, isteğe bağlı Windows bildirimi ve salt okunur `pano` eklendi. Bugünkü kod bu özellikler için asıl kaynaktır.
- 20.11.2026 tarihli `AnalizRaporu.md` bazı özellikleri öneri olarak anlatır. Bu önerilerin bir bölümü sonraki kodda uygulanmış olduğundan rapordaki maddeleri otomatik olarak açık iş sayma.
- Önceki bir Pester çalıştırmasında 56 testin geçtiği raporlanmıştı; bu, 22.11.2026 kodu için test sonucu değildir. O çalıştırmada canlı bildirim ve temizlik doğrulanmamıştı.

### Şimdi — 22.11.2026 dosya incelemesi

- `RAMMapOtomatik.ps1` zamanlanmış görev, eşik/soğuma kararı, RAMMap seçimi, argüman doğrulama, tek temizlik kilidi, durum/pano ve bildirim akışlarını içeriyor.
- `RAMMapRapor.ps1` ve testlerde SQLite telemetrisi ile HTML rapor işlevleri bulunuyor. Mevcut yapılandırmada telemetri kapalı; raporun canlı veriyle çalıştığı bu belge hazırlanırken doğrulanmadı.
- Pester test dosyası mevcut; bu belge için uygulama davranışı değiştirilmedi. Mevcut sistem görevlerinin etkinliği, canlı temizliğin sonucu ve Windows bildiriminin görünürlüğü bu belgeyle doğrulanmış sayılmaz.

### Sonrası — önerilen işler, onaylanmış taahhüt değil

1. Değişiklik talebinde önce ilgili kodu ve testleri hedefli incele; o işin kabul ölçütlerini belirle. Doküman ile kod çelişirse dokümanı düzelt.
2. Rapor/telemetri üzerinde çalışılırsa veri yok, bozuk veritabanı ve rapor açma yollarını anlamlı testlerle doğrula. Canlı verinin ayrıca doğrulanması gerektiğini belirt.
3. Zamanlanmış görev, temizlik veya bildirim davranışı değiştirilirse Pester sonucuna ek olarak uygun güvenli Windows ortamında sınırlı canlı kontrol yap; `log.txt` içinden yalnızca ilgili kanıtı incele.
4. Yapılandırma anahtarları veya komutlar değişince `Komutlar.txt`, `AGENTS.md` ve bu rehberin yalnızca etkilenen bölümlerini güncelle. Tamamlanma tarihini ve test türünü kaydet.

## Az token kullanan oturum akışı

1. Önce `AGENTS.md` ve kullanıcının isteğini izle; bu rehberi yalnızca ilgili başlık için aç.
2. `rg -n` ile işlev/anahtar adını ara, küçük kod aralığı oku. `log.txt`, tüm test dosyası veya bütün betiği gerekmedikçe görüntüleme.
3. Değişiklik kapsamına uygun tek test turu ve ayrıştırıcı kontrolü yap; başarısızlık olursa ilgili alanı araştır. Test sonucu ile canlı sistem sonucunu karıştırma.
4. Oturum sonunda kısa bir değişiklik ve doğrulama özeti ver. Kalıcı, gerçekten yeni proje bilgisini bu rehbere işle; geçici günlükleri veya uzun konuşma dökümlerini buraya kopyalama.

Bu düzen tekrarlı keşif ve uzun dosya okumalarını azaltabilir. Ancak `AGENTS.md` her yeni oturumun bağlamına eklendiği için kendi token maliyeti vardır; toplam kullanım veya fatura için sabit bir tasarruf garantisi yoktur.
