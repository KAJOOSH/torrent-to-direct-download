<div dir="rtl">

# تبدیل تورنت به دانلود مستقیم

[English](README.md)

این پروژه یک سرور Ubuntu را به سرور ساده‌ی **دانلود تورنت و ارائه لینک مستقیم** تبدیل می‌کند.

لینک Magnet یا فایل Torrent را داخل qBittorrent وارد می‌کنید؛ سرور فایل را دانلود می‌کند و پس از کامل‌شدن، فایل از طریق HTTP و HTTPS معتبر در اختیار کاربران قرار می‌گیرد.

## سرویس‌های Docker

تمام سرویس‌های اصلی داخل Docker Compose اجرا می‌شوند:

- Image رسمی و پایدار qBittorrent-nox
- Image رسمی Nginx برای دانلود مستقیم
- Image رسمی Certbot برای SSL معتبر Let’s Encrypt روی IP عمومی
- تمدید خودکار گواهی SSL

اگر Docker و Docker Compose نصب نباشند، اسکریپت آن‌ها را از مخزن رسمی Docker نصب می‌کند.

## پیش‌نیازها

- Ubuntu نسخه 22.04، 24.04، 25.10 یا 26.04
- دسترسی root
- IPv4 عمومی
- بازبودن TCP پورت‌های `80`، `443` و `8080`
- بازبودن TCP و UDP پورت `49160` برای تورنت
- Port Forward در صورت قرارداشتن سرور پشت NAT

پورت‌ها باید در فایروال پنل VPS یا شرکت میزبان نیز باز باشند.

## نصب سریع

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/main/install.sh \
  -o /tmp/install.sh \
  && sudo bash /tmp/install.sh
```

نصب پیشنهادی همراه ایمیل Let’s Encrypt:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/main/install.sh \
  -o /tmp/install.sh \
  && sudo env \
    LETSENCRYPT_EMAIL=admin@example.com \
    bash /tmp/install.sh
```

برای سرور پشت NAT، IP عمومی را مشخص کنید:

```bash
sudo env \
  PUBLIC_IP=YOUR_PUBLIC_IP \
  LETSENCRYPT_EMAIL=admin@example.com \
  bash /tmp/install.sh
```

## آدرس‌ها پس از نصب

```text
پنل qBittorrent:
http://PUBLIC_IP:8080

دانلود مستقیم:
http://PUBLIC_IP/
https://PUBLIC_IP/
```

نام کاربری و رمز تولیدشده qBittorrent در این فایل ذخیره می‌شود:

```bash
sudo cat /root/qbittorrent-credentials.txt
```

## به‌روزرسانی

همان اسکریپت نصب را دوباره اجرا کنید. Imageهای رسمی جدید دریافت می‌شوند و فایل‌های دانلودشده، وضعیت تورنت‌ها و رمز فعلی حفظ خواهند شد.

## بازنشانی رمز qBittorrent

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/main/install.sh \
  -o /tmp/install.sh \
  && sudo env RESET_QBT_PASSWORD=1 bash /tmp/install.sh
```

## نکات مهم

- فایل‌های کامل‌شده روی پورت‌های `80` و `443` عمومی و بدون رمز هستند.
- برای تمدید SSL، پورت `80` باید از اینترنت در دسترس باقی بماند.
- پنل qBittorrent دارای رمز تصادفی قوی است، اما روی پورت `8080` با HTTP ارائه می‌شود.
- فقط محتوایی را دانلود یا منتشر کنید که اجازه قانونی استفاده و اشتراک‌گذاری آن را دارید.

## هدف پروژه

هدف پروژه ایجاد یک سرور کوچک و شخصی است که فایل را از شبکه BitTorrent دریافت کند و پس از تکمیل دانلود، همان فایل را به‌صورت لینک مستقیم معمولی در اختیار کاربران، مرورگرها، پخش‌کننده‌ها یا دانلود منیجرها قرار دهد.

</div>
