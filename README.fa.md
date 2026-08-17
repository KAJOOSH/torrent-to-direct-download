<div dir="rtl">

# تبدیل تورنت به دانلود مستقیم

راه‌اندازی qBittorrent در کنار Nginx برای دریافت تورنت و دانلود مستقیم فایل‌های تکمیل‌شده از طریق HTTP یا HTTPS.

[English](README.md)

## امکانات

- پنل qBittorrent WebUI
- دانلود مستقیم فایل‌ها از طریق Nginx
- HTTPS اختیاری با Let's Encrypt
- تنظیمات Nginx مناسب دانلودهای حجیم و اتصال‌های هم‌زمان
- نگهداری دائمی تنظیمات و Resume تورنت‌ها
- حذف دائمی فایل‌ها و جلوگیری از باقی‌ماندن آن‌ها در `.Trash-*`
- تغییر رمز qBittorrent بدون نصب مجدد سیستم
- دستورهای داخلی برای وضعیت سرویس، بررسی دیسک، پاک‌سازی Trash و به‌روزرسانی

## نصب سریع

این دستور را فقط برای نصب اولیه اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/torrent-to-direct-download/refs/heads/main/install.sh -o /tmp/ttdd && sudo install -m 0755 /tmp/ttdd /usr/local/bin/ttdd && rm -f /tmp/ttdd && sudo ttdd
```

اسکریپت مدیریت در این مسیر ذخیره می‌شود:

```text
/usr/local/bin/ttdd
```

بعد از نصب اولیه دیگر نیازی به دانلود مجدد `install.sh` نیست و تمام عملیات با دستور محلی `ttdd` انجام می‌شود.

در اولین اجرا از شما پرسیده می‌شود که HTTPS لازم است یا خیر. اگر HTTP را انتخاب کنید، مراحل دریافت Certificate و راه‌اندازی Certbot انجام نمی‌شود.

## دستورهای کاربردی

```bash
# نمایش وضعیت سرویس‌ها و فضای مصرفی
sudo ttdd --status

# فقط تغییر رمز qBittorrent بدون نصب مجدد
sudo ttdd --reset-password

# بررسی فضای دیسک، Trash مخفی و فایل‌های حذف‌شده‌ای که هنوز باز هستند
sudo ttdd --disk-check

# حذف دائمی .Trash-* های قدیمی پس از تأیید
sudo ttdd --purge-trash

# فعال‌کردن HTTPS
sudo ttdd --enable-ssl

# غیرفعال‌کردن HTTPS
sudo ttdd --disable-ssl

# بررسی و نصب نسخه جدید
sudo ttdd --update
```

برای تعیین رمز دلخواه هنگام Reset:

```bash
sudo env QBT_PASSWORD='your-strong-password' ttdd --reset-password
```

## به‌روزرسانی

برای به‌روزرسانی فقط این دستور کافی است:

```bash
sudo ttdd --update
```

Updater آخرین `install.sh` شاخه `main` را ابتدا در یک فایل موقت دریافت می‌کند، Syntax و شماره نسخه آن را بررسی می‌کند و فقط در صورت معتبر بودن فایل، نسخه محلی `/usr/local/bin/ttdd` را جایگزین می‌کند.

اگر نسخه جدید موجود باشد:

- از نسخه فعلی در `/usr/local/bin/ttdd.bak` نسخه پشتیبان گرفته می‌شود؛
- فایل جدید به‌صورت امن جایگزین نسخه فعلی می‌شود؛
- اگر نسخه موجود در GitHub قدیمی‌تر باشد Downgrade انجام نمی‌شود؛
- در صورت وجود نصب قبلی، نسخه جدید بلافاصله روی Stack اعمال می‌شود؛
- دانلودها، تنظیمات qBittorrent و Resume تورنت‌ها حفظ می‌شوند.

اگر همین نسخه از قبل نصب باشد، Stack بی‌دلیل دوباره نصب نمی‌شود.

## سرعت دانلود مستقیم

Nginx برای دانلود فایل‌های حجیم و استفاده از چند Connection توسط Download Managerها تنظیم شده است.

تنظیمات اصلی شامل موارد زیر است:

- `worker_processes auto`
- `worker_connections 65535`
- `worker_rlimit_nofile 262144`
- Docker `nofile` برابر `262144`
- `net.core.somaxconn=65535`
- `reuseport` و backlog بالا
- `sendfile on`
- `tcp_nopush on`
- `tcp_nodelay on`
- `multi_accept on`
- `limit_rate 0`
- بدون `limit_conn`
- بدون `limit_req`
- غیرفعال بودن Access Log برای جلوگیری از نوشتن غیرضروری روی دیسک هنگام دانلودهای سنگین

Range Request فعال است و برنامه‌هایی مانند IDM و aria2 می‌توانند یک فایل را با چند Connection دریافت کنند.

سرعت نهایی همچنان به سرعت دیسک سرور، کارت شبکه، مسیر اینترنت، CPU و TLS، شبکه میزبان و سمت کاربر بستگی دارد.

برای مشاهده تنظیم واقعی Nginx:

```bash
sudo docker exec ttdd-nginx nginx -T
```

## مسیرهای ذخیره‌سازی

```text
/srv/qbittorrent/config       تنظیمات و اطلاعات qBittorrent
/srv/qbittorrent/downloads    فایل‌های کامل‌شده
/srv/qbittorrent/incomplete   دانلودهای ناقص
/opt/torrent-to-direct-download
                              فایل‌های Compose و Nginx
```

Nginx پوشه دانلودهای کامل را به‌صورت Read-only Bind Mount مشاهده می‌کند. فایل دوم یا کپی جداگانه‌ای برای Nginx ساخته نمی‌شود.

مسیرهای داخل کانتینر qBittorrent:

```text
/data/downloads
/data/incomplete
```

مسیرهای قدیمی `/downloads` و `/incomplete` برای سازگاری Resume تورنت‌های قبلی باقی می‌مانند و به همان پوشه‌های میزبان اشاره می‌کنند.

## آزاد نشدن فضا بعد از حذف فایل

برای حذف‌های جدید qBittorrent این حالت را استفاده می‌کند:

```text
Session\TorrentContentRemoveOption=Delete
```

بنابراین فایل‌هایی که همراه تورنت حذف می‌شوند به Trash مخفی منتقل نمی‌شوند.

برای بررسی فضای فعلی:

```bash
sudo ttdd --disk-check
```

اگر `.Trash-*` قدیمی وجود داشت و قصد حذف آن را داشتید:

```bash
sudo ttdd --purge-trash
```

قبل از حذف دائمی از شما تأیید گرفته می‌شود.

## HTTPS

فعال‌کردن HTTPS:

```bash
sudo ttdd --enable-ssl
```

بازگشت به HTTP:

```bash
sudo ttdd --disable-ssl
```

اگر Certificate معتبر قبلی وجود داشته باشد دوباره استفاده می‌شود. Certbot renewal dry-run در هر نصب اجرا نمی‌شود.

در صورت نیاز به اجرای دستی Dry Run:

```bash
sudo env RUN_RENEWAL_DRY_RUN=1 ttdd --enable-ssl
```

## فایل‌های مهم

```text
/usr/local/bin/ttdd                         دستور مدیریت محلی
/root/qbittorrent-credentials.txt          اطلاعات ورود qBittorrent
/root/qbittorrent-download-info.txt        اطلاعات دانلود مستقیم
/root/qbittorrent-ip-ssl-info.txt          اطلاعات Certificate
/root/torrent-to-direct-download-error.log آخرین گزارش خطای Installer
```

## راهنما

```bash
sudo ttdd --help
```

</div>
