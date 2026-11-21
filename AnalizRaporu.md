# RAMMapOtomatik Proje Analiz Raporu

## 1. Genel Proje Özeti
Sistem, `RAMMap` aracını kullanarak Windows üzerindeki "Standby" ve "Modified" bellek listelerini otomatik olarak temizlemek için tasarlanmış, PowerShell tabanlı profesyonel bir otomasyondur. Proje; konfigürasyon yönetimi, gelişmiş hata yönetimi ve kapsamlı bir test katmanı içerir.

## 2. Teknik Analiz
### Konfigürasyon (`config.json`)
- **Yapı:** Standart JSON formatında, temiz ve okunabilir.
- **Parametreler:** Eşik değerleri (`EsikMB`), kontrol aralıkları (`KontrolSaniye`) ve özel RAMMap parametreleri (`-Em -Et`) başarıyla yönetiliyor.

### Mantık ve Hata Yönetimi (`RAMMapOtomatik.ps1`)
- **Dayanıklılık:** Dosya I/O işlemleri (log kilitlenmeleri) ve JSON ayrıştırma işlemleri için mükemmel hata yakalama mekanizmaları mevcut.
- **Güvenlik:** `RAMMap` sürecinin asılı kalmasını önlemek için 60 saniyelik bir zaman aşımı (timeout) mekanizması eklenmiş.
- **Yetki Yönetimi:** Yönetici hakları gereksinimini fark eden ve gerektiğinde yükseltme işlemi yapan `Yonetici-Iste` fonksiyonu başarılı çalışıyor.

### Test Stratejisi (`RAMMapOtomatik.Tests.ps1`)
- **İzolasyon:** Pester 5 kullanılarak, gerçek sistem dosyalarına zarar vermeyecek şekilde geçici klasörler ve `Mock` nesneler kullanılarak testler izole edilmiş.
- **Kapsam:** Hata durumları, JSON bozulmaları ve bellek değerleri çok kapsamlı bir şekilde test ediliyor.

## 3. Kritik Bulgular ve Riskler
- **Taşınabilirlik:** `config.json` içindeki sabit yol (`C:/Tools/RAMMap.exe`), aracın farklı dizinlerde çalışmasını zorlaştırıyor.
- **Güvenlik:** Konfigürasyon dosyası düz metin olduğu için, dosyaya erişimi olan bir kullanıcı `Parametreler` kısmına zararlı komutlar enjekte edebilir.

## 4. İyileştirme Önerileri
1.  **Görece Yollar (Relative Paths):** `RamMapYolu` varsayılan olarak betiğin çalıştığı klasörü baz alacak şekilde güncellenmeli.
2.  **Bildirim Sistemi:** Temizlik başarıyla tamamlandığında kullanıcıya Windows bildirimleri (Toast Notifications) ile bilgi verilmeli.
3.  **Log Rotasyonu:** Sadece satır sayısı değil, dosya boyutu (örn. 1MB) bazlı bir log döndürme mekanizması eklenmeli.
4.  **Dashboard:** Bekleme süresince konsol üzerinde anlık güncellenen bir "Durum Panosu" (Status Dashboard) görselleştirilebilir.
