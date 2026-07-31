<div dir="rtl">

# سرور دانلود مستقیم با qBittorrent

[English](README.md)

یک نصب‌کننده ساده برای Ubuntu که فایل‌ها را با qBittorrent دانلود می‌کند و پس از کامل‌شدن، آن‌ها را به‌صورت لینک دانلود مستقیم HTTP و HTTPS در اختیار کاربران قرار می‌دهد.

## هدف پروژه

هدف این پروژه تبدیل یک سرور Ubuntu به یک سرور دانلود ساده است:

1. لینک Magnet یا فایل Torrent را داخل qBittorrent وارد می‌کنید.
2. سرور فایل را از شبکه تورنت دانلود می‌کند.
3. فایل کامل‌شده با لینک مستقیم در اختیار کاربران قرار می‌گیرد.

برای فعال‌سازی HTTPS نیازی به دامنه نیست و اسکریپت می‌تواند مستقیماً برای IPv4 عمومی، گواهی معتبر Let’s Encrypt دریافت کند.

## امکانات اصلی

- نصب و تنظیم qBittorrent-nox
- استفاده از سرویس فعلی `qbittorrent-root` در صورت وجود
- نصب و تنظیم Nginx
- ارائه فایل‌ها روی HTTP و HTTPS
- فعال‌کردن هم‌زمان پورت‌های `80` و `443`
- دریافت SSL معتبر برای IP عمومی
- تمدید خودکار گواهی SSL
- امکان اجرای مجدد اسکریپت بدون نصب دوباره غیرضروری

## پیش‌نیازها

- سرور Ubuntu
- دسترسی root یا sudo
- IPv4 عمومی
- دسترسی عمومی به TCP پورت‌های `80` و `443`
- Port Forward در صورت قرارداشتن سرور پشت NAT

## نصب سریع

عبارت `YOUR_GITHUB_USERNAME` را با نام کاربری GitHub خود جایگزین کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/qbittorrent-direct-download-server/main/install.sh   -o /tmp/install.sh   && sudo bash /tmp/install.sh
```

نصب با IP و ایمیل مشخص:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/qbittorrent-direct-download-server/main/install.sh   -o /tmp/install.sh   && sudo env     PUBLIC_IP=YOUR_PUBLIC_IP     LETSENCRYPT_EMAIL=admin@example.com     bash /tmp/install.sh
```

برای سرور پشت NAT:

```bash
sudo env   PUBLIC_IP=YOUR_PUBLIC_IP   BIND_ADDRESS=0.0.0.0   LETSENCRYPT_EMAIL=admin@example.com   bash /tmp/install.sh
```

## آدرس‌ها پس از نصب

```text
پنل qBittorrent:
http://PUBLIC_IP:8080

دانلود مستقیم:
http://PUBLIC_IP/
https://PUBLIC_IP/
```

## دستورهای کاربردی

مشاهده اطلاعات ورود qBittorrent:

```bash
sudo cat /root/qbittorrent-credentials.txt
```

مشاهده اطلاعات SSL:

```bash
sudo cat /root/qbittorrent-ip-ssl-info.txt
```

بررسی سرویس‌ها:

```bash
sudo systemctl status qbittorrent-root
sudo systemctl status nginx
```

## نکات مهم

- پورت TCP شماره `80` باید برای تمدید SSL از اینترنت قابل دسترسی بماند.
- IP عمومی باید روی سرور باقی بماند یا به آن Port Forward شده باشد.
- پوشه دانلود به‌صورت پیش‌فرض رمز ندارد و عمومی است.
- هر شخصی که به پورت `80` یا `443` دسترسی داشته باشد، می‌تواند فایل‌های کامل‌شده را ببیند و دانلود کند.
- فقط برای فایل‌هایی استفاده کنید که اجازه قانونی دانلود و اشتراک‌گذاری آن‌ها را دارید.

## توضیح پیشنهادی مخزن

```text
دانلود تورنت روی Ubuntu و ارائه فایل‌های کامل‌شده به کاربران به‌صورت لینک دانلود مستقیم HTTP و HTTPS.
```

## مجوز استفاده

استفاده و تغییر این پروژه با مسئولیت خود کاربر انجام می‌شود.

</div>
