# c6tools1_app

Flutter Windows masaüstü uygulaması. USB ile takılan ESP32 cihazlarını (seri port olarak) otomatik algılar ve kontrol edilmesini sağlar.

## Kurulum Adımları
1. Bu projeyi indirin.
2. Terminalde `flutter pub get` çalıştırarak bağımlılıkları yükleyin.
3. Uygulamayı derlemek veya çalıştırmak için:
   ```bash
   flutter run -d windows
   ```

## Kullanım
- Uygulama açıldığında sistemdeki mevcut seri portları otomatik olarak tarar (1 saniyede bir yeniler).
- Yeni bir port (USB ESP32 gibi) bağlandığında "**NEW**" etiketiyle ekranda belirir (ilk 5 saniye).
- Port bağlantısı fiziksel olarak koptuğunda kart "**DISCONNECTED**" durumuna geçer ve kapanır.
- **Open Port** butonuna basarak portu açabilir ve veri akışını izleyebilirsiniz.
- Cihazdan son 1000ms içinde veri gelirse durum **CONNECTED**, veri gelmezse **STALE** olarak görünür.
- Bağlı (açık) cihazlardan gelen son 200 satır ham seri log, ilgili panele yazılır.

## Bilinen Sınırlamalar
- Bir COM portu aynı anda hem bu uygulama hem de başka bir terminal/monitör (`idf.py monitor`, PuTTY vb.) tarafından açılamaz. Erişim hatası (port in use) alınır.
- Loglar şimdilik string olarak ham (raw) gösterilmekte olup satır bazlı komut ayrıştırması (parse) yoktur. 

## Phase 2 Planı
- **Wi-Fi Configure** sayfası (SSID, Password girme, kaydetme özelliği).
- **Send Config** butonu eklenecek. USB üzerinden JSON veya line protocol formatında konfigürasyon paketi gönderimi sağlanacak.
- ESP tarafından gönderilecek `@CFG`/`@ACK` bildirimleri gibi özel komutlar pars edilip cevaplarına göre UI (başarı/hata) güncellenecek.
