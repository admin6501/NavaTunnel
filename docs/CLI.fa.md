# مرجع دستورهای NavaTunnel

[English](CLI.md) · [صفحه اصلی](../README.fa.md) · [راه‌اندازی](USAGE.fa.md) · [نگهداری](OPERATIONS.fa.md) · [پرسش‌ها](FAQ.fa.md)

دستورهای مدیریت به root نیاز دارند. مقدارهای نمونه با حروف بزرگ را جایگزین کن؛ دستورهای یک کادر، نمونه‌اند و قرار نیست همه را پشت‌سرهم اجرا کنی. دستور `NavaTunnel --help` خلاصه را نمایش می‌دهد. برای نصب اول از منو استفاده کن؛ دستورهای قدیمی سطح پایین، بدون تعیین آدرس متفاوت از آدرس داخلی ثابت پیش‌فرض استفاده می‌کنند.

## نمایش و انتخاب

```bash
NavaTunnel
NavaTunnel menu
NavaTunnel peer-list
NavaTunnel foreign-list
NavaTunnel doctor check
NavaTunnel status
```

شناسه تونل ایران از `peer-list` و شناسه اتصال خارج از `foreign-list` می‌آید؛ این دو فهرست جدا هستند. شناسه شمارنده از `traffic list` و نام رابط از وضعیت تونل گرفته می‌شود. فرض نکن پسوند عددی همه یکی است.

## اتصال خارج

برای ایران جدید، کد کامل محرمانه تولیدشده روی ایران را استفاده کن:

```bash
NavaTunnel setup-foreign --bundle CODE --name Iran-B
```

برای به‌روزرسانی یک اتصال قبلی، از جمله جابه‌جایی IP ایران:

```bash
NavaTunnel setup-foreign --bundle NEW_CODE --foreign-id FOREIGN_ID --force
```

گزینه `--frp-transport tcp|kcp|quic|websocket|wss` پروتکل داخل کد را جایگزین می‌کند. گزینه `--loss-recovery on|off` جبران افت را مشخص می‌کند؛ تنظیم ایران و خارج را هماهنگ نگه دار و گزینه‌های متناقض نده. گزینه‌های پروکسی شامل `--frp-encryption on|off` و `--frp-compression on|off` هستند. با `--relay-ip IP` می‌توان مقصد برنامه را عوض کرد؛ `--proxy-protocol v1|v2` را فقط وقتی فعال کن که برنامه مقصد صریحاً آن را قبول می‌کند. پیش‌فرض مقصد برنامه `127.0.0.1` و proxy protocol خاموش است.

دستور `NavaTunnel bundle inspect CODE` کد را با توکن مخفی نمایش می‌دهد. گزینه `--show-token`، دستور `peer-token` و دستورهای نمایش توکن، اطلاعات محرمانه چاپ می‌کنند. فیلدهای کد را دستی دست‌کاری نکن؛ تنظیمات ایران را تغییر بده و کد تازه بگیر.

## مدیریت تونل ایران

```bash
NavaTunnel tunnel-power start --id IRAN_ID
NavaTunnel tunnel-power stop --id IRAN_ID
NavaTunnel edit-peer --id IRAN_ID --name New-name
NavaTunnel edit-peer --id IRAN_ID --ports "443,8443,9443"
NavaTunnel edit-peer --id IRAN_ID --remote-pub NEW_FOREIGN_IP
NavaTunnel edit-peer --id IRAN_ID --carrier fou:55555
NavaTunnel peer-control-port --id IRAN_ID --port auto
NavaTunnel peer-protocol --id IRAN_ID --protocol tcp
NavaTunnel loss-recovery --id IRAN_ID --mode off
NavaTunnel peer-addresses --id IRAN_ID --auto
NavaTunnel peer-token --id IRAN_ID
NavaTunnel connection-token --id IRAN_ID
NavaTunnel connection-token --id IRAN_ID --token NEW_TOKEN
NavaTunnel iran-ip --ip NEW_IRAN_IP
```

گزینه `--ports` کل فهرست پورت‌ها را جایگزین می‌کند. دستور `peer-control-port` عدد پورت مشخص را هم می‌پذیرد. دستور `peer-addresses`، گزینه‌های `--local-gre IRAN_GRE_IP --peer-gre FOREIGN_GRE_IP` را هم برای یک جفت آدرس خصوصی معتبر /30 قبول می‌کند؛ تغییر آن مسیر انتخاب‌شده را موقت قطع می‌کند. دستور `iran-ip` آدرس عمومی ذخیره‌شده همه تونل‌های ایران را عوض می‌کند، نه IP سیستم‌عامل را. تغییرات را با اتصال متناظر خارج هماهنگ کن؛ کد چاپ‌شده آنجا خودکار اجرا نمی‌شود. برای ری‌استارت انتخابی ایران، از **۱ ← ۳ ← انتخاب تونل ← ۳** استفاده کن.

## مدیریت اتصال انتخابی خارج

```bash
NavaTunnel foreign --foreign-id FOREIGN_ID status
NavaTunnel foreign --foreign-id FOREIGN_ID start
NavaTunnel foreign --foreign-id FOREIGN_ID stop
NavaTunnel foreign --foreign-id FOREIGN_ID restart
NavaTunnel foreign --foreign-id FOREIGN_ID logs
NavaTunnel foreign --foreign-id FOREIGN_ID token
NavaTunnel foreign --foreign-id FOREIGN_ID token --token NEW_TOKEN
NavaTunnel foreign --foreign-id FOREIGN_ID iran-ip --ip NEW_IRAN_IP
NavaTunnel foreign --foreign-id FOREIGN_ID carrier fou:55555
```

روش انتقال `direct` هم پذیرفته می‌شود. توکن و روش انتقال ایران مقابل را هماهنگ نگه دار. میانبرهای قدیمی `tunnel-power ... --foreign` و `connection-token --foreign` و `foreign-iran-ip --ip IP` به کلاینت اول اشاره می‌کنند؛ با چند کلاینت از دستورهای دارای شناسه استفاده کن. حذف در بخش آخر آمده است.

## MTU و ترافیک

```bash
NavaTunnel mtu --interface GRE_INTERFACE --value 1380
NavaTunnel traffic list
NavaTunnel traffic status COUNTER_ID
NavaTunnel traffic limit COUNTER_ID 100GB --mode download
NavaTunnel traffic mode COUNTER_ID both
NavaTunnel traffic reset COUNTER_ID
NavaTunnel traffic limit COUNTER_ID 0
NavaTunnel traffic repair
```

MTU دو طرف همان تونل را تنظیم کن. محدوده پذیرفته‌شده ۵۷۶ تا ۱۴۷۶ است؛ پیاده‌سازی فعلی KCP حداقل ۱۳۷۸ می‌خواهد، پس پیش از پایین‌آوردن از این مقدار، پروتکل FRP را عوض کن. این محدوده اعتبارسنجی است و تضمین نمی‌کند هر عددی در مسیر تو جا شود. واحد مصرف GB ده‌دهی است؛ ریست مصرف را صفر می‌کند، نه سقف را. [جزئیات ترافیک](OPERATIONS.fa.md#ترافیک-و-سقف)

شمارنده معمولاً خودکار ثبت می‌شود. برای ثبت دستی پیشرفته، `traffic add COUNTER_ID --interface GRE_INTERFACE` یا `--peer PEER_PUBLIC_IP` قابل‌استفاده است؛ شمارنده هم‌پوشان نساز. دستور `traffic discover` رابط‌های GRE فعال مدیریت‌شده را پیدا و شمارنده‌های ثبت‌نشده را اضافه می‌کند؛ شمارنده‌های موجود را حفظ می‌کند. دستور `traffic remove COUNTER_ID` شمارنده و اعمال محدودیتش را حذف می‌کند، نه خود تونل را.

## تنظیمات و پایش کل سرور

```bash
NavaTunnel perf status
NavaTunnel perf enc on
NavaTunnel perf comp off
NavaTunnel perf tls on
NavaTunnel perf apply
NavaTunnel tune-status
NavaTunnel carrier status
NavaTunnel watchdog status
NavaTunnel watchdog check
NavaTunnel watchdog on
NavaTunnel watchdog off
```

دستور `perf apply` تنظیمات ذخیره‌شده FRP همین سرور را اعمال و سرویس‌های مربوط را ری‌استارت می‌کند؛ انتخاب تونل در منو دامنه آن را محدود نمی‌کند. دستور `optimize` بهینه‌سازی شبکه سیستم را اعمال می‌کند؛ `restore` تنظیمات **شبکه** را برمی‌گرداند، نه بکاپ رمزگذاری‌شده را. دستور `free-ram` تنظیم swap و لاگ را هم تغییر می‌دهد. پیش از اجرا توضیح منو را بخوان. دستورهای کلی `carrier mode direct` و `carrier mode fou:PORT` ممکن است روش همه رابط‌های فعال GRE را عوض کنند؛ روی خارج چنداتصاله، مدیریت انتخابی را ترجیح بده. دستور `carrier next` گزینه‌های روش انتقال را نوبتی عوض می‌کند و بهترین ایران برای کاربران را انتخاب نمی‌کند. [تنظیم پوشش، SYN و واچ‌داگ](OPERATIONS.fa.md#تنظیمات-شبکه-و-امنیت)

تلگرام اختیاری است؛ از **۲ ← ۵** اطلاعات و در صورت نیاز مسیر واقعی SOCKS5 را تنظیم کن. دستور `watchdog test` هشدار آزمایشی و `tgsend "MESSAGE"` پیام دستی می‌فرستد. هر اینباند Xray الزاماً پروکسی SOCKS نیست. ری‌استارت خودکار در تنظیم اولیه واچ‌داگ خاموش است؛ فعال‌کردن پایش به‌تنهایی آن را فعال نمی‌کند.

## بکاپ، ریستور و انتقال

```bash
NavaTunnel backup now --keep 7
NavaTunnel backup status
NavaTunnel backup schedule --every 6
NavaTunnel backup schedule --daily 03:00
NavaTunnel backup schedule --off
NavaTunnel backup restore /path/BACKUP.enc --dry-run
NavaTunnel backup restore /path/BACKUP.enc --local-ip DESTINATION_PUBLIC_IP
NavaTunnel migrate --host SSH_DESTINATION_IP --local-ip DESTINATION_PUBLIC_IP
```

یکی از زمان‌بندی‌ها را انتخاب و فعال‌بودن تایمر نگهداری را بررسی کن. ریستور به کلید اصلی همان آرشیو در `/etc/gre-panel/backup.key` نیاز دارد. گزینه `--local-ip` در ایران و خارج یعنی IP عمومی **خود مقصد**. انتقال، `--port PORT` و `--user USER` و `--identity KEY_FILE` و `--backup BACKUP_FILE` را هم می‌پذیرد. بدون `--backup`، بکاپ رمزگذاری‌شده تازه ساخته می‌شود. [مراحل انتقال ایران/خارج و انتقال دستی](OPERATIONS.fa.md#انتقال-با-ssh)

## عیب‌یابی، آپدیت و حذف

دستور `doctor check` اتصال‌های ثبت‌شده را بررسی می‌کند. دستور قدیمی `doctor diag` با نام دیگر `speed`، رابط اول را تشخیص می‌دهد، پینگ و MTU و سرعت را آزمایش می‌کند و ممکن است پیشنهاد بهینه‌سازی بدهد؛ روی سرور چندتونله، آدرس مقابل را صریح برای تست انتخاب کن. دستور `doctor server`، iperf3 را روی پورت ۵۲۰۱ شروع و `doctor stop-server` پردازش‌های سرور آن را متوقف می‌کند؛ مدیریت مستقل هر اتصال نیست. هنگام تست دسترسی را محدود کن. دستور `stress-test HOST PORT COUNT` اتصال آزمایشی می‌سازد و نشست واقعی برنامه را تأیید نمی‌کند.

```bash
NavaTunnel logs
NavaTunnel update-all
NavaTunnel download-cores
```

دستور `logs` لاگ زنده FRP محلی را دنبال می‌کند؛ Ctrl+C خارج می‌شود. دستورهای `update` و `update-all` اسکریپت‌های مدیریت را به‌روز می‌کنند؛ `download-cores` فایل اجرایی FRP را نصب یا تعمیر می‌کند. آپدیت اسکریپت مبدا، سرور مقابل را از راه دور به‌روز نمی‌کند.

برای حذف یک اتصال، از منوی خودش یا دستورهای زیر استفاده کن؛ `--force` تأیید را رد می‌کند:

```bash
NavaTunnel remove-peer --id IRAN_ID --force
NavaTunnel foreign --foreign-id FOREIGN_ID remove --force
```

دستور کلی `restart` سرویس‌های تونل محلی را ری‌استارت می‌کند؛ اگر نمی‌خواهی اتصال دیگری دست بخورد، گزینه انتخابی را استفاده کن. دستور `remove-tunnel` **همه** اجزای تونل محلی را حذف می‌کند. دستور `uninstall`، اسکریپت‌ها و اطلاعات مدیریت شامل کلید بکاپ را هم حذف می‌کند. قبل از حذف، بکاپ و کلید را خارج از سرور نگه دار. هیچ‌کدام سرور مقابل یا دیتابیس برنامه را حذف نمی‌کنند.
