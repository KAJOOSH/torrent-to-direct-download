<div dir="rtl">

# تبدیل تورنت به دانلود مستقیم — نسخه 3.0.2

این نسخه بازطراحی اسکریپت 2.2.1 برای **qBittorrent + Nginx** است و علاوه بر اصلاح Reset Password، SSL و مشکل فضای دیسک، در نسخه 3.0.2 تنظیمات دانلود مستقیم Nginx نیز برای سرعت و تعداد اتصال بالا بهینه شده است.

داده‌های موجود در `/srv/qbittorrent` هنگام نصب/آپدیت حذف نمی‌شوند.

## مهم‌ترین اصلاحات نسخه 3

- Reset Password دیگر کل سیستم را دوباره نصب نمی‌کند.
- SSL اختیاری است و در ابتدای نصب از شما سؤال می‌شود.
- تست کند `certbot renew --dry-run` به‌صورت پیش‌فرض اجرا نمی‌شود.
- حذف فایل qBittorrent روی حذف دائمی تنظیم شده تا فایل‌ها در `.Trash-*` باقی نمانند.
- Nginx همان پوشه واقعی دانلود را به‌صورت read-only می‌بیند و فایل را دوباره کپی نمی‌کند.
- complete و incomplete زیر یک mount اصلی قرار گرفته‌اند تا هنگام تکمیل دانلود copy اضافی بین mountها رخ ندهد.
- در نسخه **3.0.2** محدودیت مصنوعی سرعت/تعداد connection برای دانلود مستقیم Nginx وجود ندارد و سقف‌های پیش‌فرض کوچک Nginx نیز افزایش یافته‌اند.

## نصب / آپدیت

> **دستورهای این README مستقیماً از Raw رسمی شاخه `main` اجرا می‌شوند**؛ بنابراین لازم نیست ابتدا فایل `install.sh` را دانلود یا Repository را Clone کنید. آدرس مورد استفاده در همه فرمان‌های مدیریتی:
>
> `https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh`


```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash
```

در اولین نصب، قبل از عملیات سنگین از شما پرسیده می‌شود که **SSL/HTTPS لازم است یا خیر**.

انتخاب مستقیم:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --disable-ssl
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --enable-ssl
```

برای آپدیت نیز همین نسخه جدید `install.sh` را دوباره اجرا کنید. دانلودها و اطلاعات resume qBittorrent حفظ می‌شوند.

## دانلود مستقیم Nginx با بالاترین ظرفیت — جدید در 3.0.2

در تنظیم تولیدشده Nginx هیچ‌کدام از محدودکننده‌های زیر اعمال نشده‌اند:

- محدودیت سرعت پاسخ برای هر دانلود
- محدودیت connection بر اساس IP
- محدودیت تعداد request بر اساس IP

تنظیمات Performance پیش‌فرض:

```text
worker_processes auto
worker_connections 65535 برای هر Worker
worker_rlimit_nofile 262144
Docker nofile soft/hard = 262144
net.core.somaxconn = 65535
listen reuseport backlog=65535
limit_rate 0
sendfile on
tcp_nopush on
tcp_nodelay on
multi_accept on
access_log off
```

بنابراین Nginx **هیچ Rate Limit مصنوعی** روی فایل‌های دانلودی قرار نمی‌دهد. دانلود منیجرهایی مانند IDM و aria2 نیز می‌توانند از درخواست‌های Range و چند connection هم‌زمان استفاده کنند.

خاموش‌بودن `access_log` نیز برای این است که در دانلودهای سنگین و تعداد درخواست بالا، نوشتن مداوم لاگ تبدیل به I/O اضافی روی دیسک نشود. Error log همچنان فعال است.

توجه: این اعداد سقف ظرفیت هستند؛ سرعت واقعی همچنان به سرعت پورت شبکه سرور، مسیر اینترنت، دیسک، CPU/TLS، شبکه Docker و اینترنت کاربر بستگی دارد. افزایش connection باعث نمی‌شود یک سرور ضعیف به‌صورت جادویی هزاران انتقال سنگین را تحمل کند، اما محدودیت کوچک پیش‌فرض Nginx دیگر مانع شما نخواهد بود.

برای دیدن تنظیم واقعی Nginx:

```bash
sudo docker exec ttdd-nginx nginx -T
```

برای بررسی سریع محدودیت‌های مهم:

```bash
sudo docker exec ttdd-nginx sh -c 'ulimit -n; nginx -T 2>&1 | grep -E "worker_connections|worker_rlimit_nofile|limit_rate|reuseport|sendfile|multi_accept"'
```

## ریست رمز بدون نصب مجدد

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --reset-password
```

برای رمز دلخواه:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo env QBT_PASSWORD='your-strong-password' bash -s -- --reset-password
```

این عملیات apt، Docker، Nginx، SSL و فایل‌های دانلودی را دست‌کاری نمی‌کند.

روش قدیمی نیز برای سازگاری پشتیبانی می‌شود:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo env RESET_QBT_PASSWORD=1 bash
```

## مشکل فضای دیسک بعد از حذف فایل

برای بررسی فضای مصرف‌شده:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --disk-check
```

اگر `.Trash-*` قدیمی پیدا شد و مطمئن هستید همان فایل‌هایی هستند که قبلاً قصد حذف‌شان را داشته‌اید:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --purge-trash
```

قبل از حذف دائمی تأیید گرفته می‌شود.

برای حذف‌های جدید نیز qBittorrent روی این حالت تنظیم می‌شود:

```text
Session\TorrentContentRemoveOption=Delete
```

یعنی وقتی گزینه حذف فایل‌های تورنت را انتخاب می‌کنید، محتوا به Trash مخفی منتقل نمی‌شود.

## چرا Nginx فضا را دو برابر نمی‌کند؟

مسیر `/srv/qbittorrent/downloads` به‌صورت **read-only bind mount** داخل Nginx قرار می‌گیرد. Bind mount فقط همان فایل میزبان را داخل کانتینر نمایش می‌دهد؛ کپی دوم ایجاد نمی‌کند.

مسیر دانلودهای جدید در qBittorrent:

```text
/data/downloads
/data/incomplete
```

مسیرهای قدیمی `/downloads` و `/incomplete` فقط برای سازگاری تورنت‌های قبلی باقی مانده‌اند و به همان داده میزبان اشاره می‌کنند.

## SSL سریع‌تر و اختیاری

`certbot renew --dry-run` دیگر هنگام هر نصب اجرا نمی‌شود. در صورت نیاز:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo env RUN_RENEWAL_DRY_RUN=1 bash -s -- --enable-ssl
```

اگر Certificate موجود هنوز معتبر باشد دوباره استفاده می‌شود. در حالت SSL خاموش نیز سرویس‌های Certbot و پورت 443 ایجاد نمی‌شوند.

## مسیرهای اصلی

```text
/srv/qbittorrent                         داده‌های اصلی
/srv/qbittorrent/config                  تنظیمات qBittorrent
/srv/qbittorrent/downloads               دانلودهای کامل
/srv/qbittorrent/incomplete              دانلودهای ناقص
/opt/torrent-to-direct-download          فایل‌های Stack
/opt/torrent-to-direct-download/nginx/nginx.conf
/opt/torrent-to-direct-download/nginx/conf.d/default.conf
/root/qbittorrent-credentials.txt        اطلاعات ورود
/root/torrent-to-direct-download-error.log گزارش خطا
```

## وضعیت و عیب‌یابی

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --status
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh | sudo bash -s -- --disk-check
```

## اجرای تست‌ها

```bash
sudo bash tests/static-tests.sh
```

تست‌ها syntax اسکریپت، Compose حالت HTTP و HTTPS، تنظیم Performance جدید Nginx، `nofile` و backlog بالا، نبودن `limit_conn`/`limit_req`، حذف دائمی qBittorrent، مستقل‌بودن Reset Password و بارگذاری `.env` را بررسی می‌کنند.

تست واقعی سرعت اینترنت و صدور واقعی Certificate داخل تست استاتیک انجام نمی‌شود.

جزئیات کامل در `CHANGELOG.md`، `REVIEW.md` و `TEST-RESULTS.md` قرار دارد.

</div>
