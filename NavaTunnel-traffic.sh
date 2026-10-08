#!/usr/bin/env bash
# Per-tunnel traffic accounting and quota enforcement for NavaTunnel.
set -euo pipefail
command -v python3 >/dev/null || { echo 'به python3 نیاز است.' >&2; exit 1; }
exec python3 - "$@" <<'PY'
import argparse, decimal, fcntl, hashlib, ipaddress, json, os, re, subprocess, sys
from pathlib import Path

STATE = Path('/etc/gre-panel/traffic.json')
BOOT = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
MODES = ('download', 'upload', 'both')

def run(args, check=True):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)

def ipt(*args, check=True):
    return run(['iptables', '-w', '5', '-t', 'mangle', *args], check)

def size(text):
    m = re.fullmatch(r'(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB|KIB|MIB|GIB|TIB)?', text.upper())
    if not m:
        raise ValueError('مقدار نامنفی مثل 100GB، 2.5GiB یا 0 برای نامحدود وارد کنید.')
    units = {'B':1, 'KB':1000, 'MB':1000**2, 'GB':1000**3, 'TB':1000**4,
             'KIB':1024, 'MIB':1024**2, 'GIB':1024**3, 'TIB':1024**4}
    return int(decimal.Decimal(m[1]) * units[m[2] or 'B'])

def argument_size(text):
    try:
        return size(text)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error

def chains(name):
    tag = hashlib.sha256(name.encode()).hexdigest()[:12]
    return ['NV'+tag+'D', 'NV'+tag+'U']

def rules(t, direction):
    if t.get('interface'):
        match = ['-i' if direction == 'download' else '-o', t['interface']]
    else:
        match = ['-s' if direction == 'download' else '-d', t['peer']]
    hooks = ['INPUT', 'FORWARD'] if direction == 'download' else ['OUTPUT', 'FORWARD']
    return [(hook, match) for hook in hooks]

def save(data):
    tmp = STATE.with_suffix('.tmp')
    with open(tmp, 'w') as f:
        os.chmod(tmp, 0o600)
        json.dump(data, f, indent=2)
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, STATE)

def ensure(name, t):
    for direction, chain in zip(('download', 'upload'), chains(name)):
        exists = ipt('-S', chain, check=False).returncode == 0
        if not exists:
            ipt('-N', chain)
            if t.get('blocked'):
                ipt('-A', chain, '-j', 'DROP')
            ipt('-A', chain, '-m', 'comment', '--comment', 'nava-count', '-j', 'RETURN')
            t['last_'+direction] = 0
        count_rule = ['-m', 'comment', '--comment', 'nava-count', '-j', 'RETURN']
        if ipt('-C', chain, *count_rule, check=False).returncode:
            ipt('-A', chain, *count_rule)
            t['last_'+direction] = 0
        for hook, match in rules(t, direction):
            rule = [*match, '-j', chain]
            if ipt('-C', hook, *rule, check=False).returncode:
                ipt('-I', hook, '1', *rule)
        # Reconcile after an interrupted command or manual firewall change.
        blocked = ipt('-C', chain, '-j', 'DROP', check=False).returncode == 0
        if bool(t.get('blocked')) != blocked:
            ipt('-I', chain, '1', '-j', 'DROP') if t.get('blocked') else ipt('-D', chain, '-j', 'DROP')

def sample(name, t):
    pending = dict(t)
    ensure(name, pending)
    for direction, chain in zip(('download', 'upload'), chains(name)):
        lines = ipt('-L', chain, '-v', '-x', '-n').stdout.splitlines()
        values = [int(line.split()[1]) for line in lines
                  if len(line.split()) >= 3 and line.split()[2] == 'RETURN' and 'nava-count' in line]
        if len(values) != 1:
            raise ValueError('شمارنده ترافیک پیدا نشد برای '+name)
        current = values[0]
        last = pending.get('last_'+direction, 0)
        delta = current-last if current >= last and pending.get('boot') == BOOT else current
        pending[direction] = pending.get(direction, 0) + delta
        pending['last_'+direction] = current
    pending['boot'] = BOOT
    t.update(pending)

def consumed(t):
    return sum(t.get(d, 0) for d in ('download', 'upload') if t['mode'] in (d, 'both'))

def enforce(name, t):
    blocked = bool(t['limit'] and consumed(t) >= t['limit'])
    # Persist the intended state first so a failed command can be reconciled.
    t['blocked'] = blocked
    for chain in chains(name):
        exists = ipt('-C', chain, '-j', 'DROP', check=False).returncode == 0
        if blocked and not exists:
            ipt('-I', chain, '1', '-j', 'DROP')
        elif not blocked and exists:
            ipt('-D', chain, '-j', 'DROP')

def detach(name, t):
    for direction, chain in zip(('download', 'upload'), chains(name)):
        for hook, match in rules(t, direction):
            while ipt('-C', hook, *match, '-j', chain, check=False).returncode == 0:
                ipt('-D', hook, *match, '-j', chain)
        if ipt('-S', chain, check=False).returncode == 0:
            ipt('-F', chain); ipt('-X', chain)

def add(data, name, interface=None, peer=None, limit=0, mode='both'):
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', name):
        raise ValueError('شناسه شمارنده باید 1 تا 64 نویسه از حروف لاتین، عدد، نقطه، زیرخط یا خط‌تیره باشد.')
    if name in data:
        raise ValueError('شمارنده از قبل ثبت شده است؛ از limit، mode یا reset استفاده کنید.')
    if interface:
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,15}', interface):
            raise ValueError('نام اینترفیس نامعتبر است.')
        if not Path('/sys/class/net', interface).exists():
            raise ValueError('اینترفیس موجود نیست: '+interface)
    elif peer:
        try:
            peer = str(ipaddress.IPv4Address(peer))
        except ipaddress.AddressValueError:
            raise ValueError('IP مقابل باید یک آدرس IPv4 معتبر باشد.')
    else:
        raise ValueError('برای اینترفیس GRE/TUN از --interface و برای IP اختصاصی مقابل از --peer استفاده کنید.')
    for existing in data.values():
        if (interface and existing.get('interface') == interface) or (peer and existing.get('peer') == peer):
            raise ValueError('این اینترفیس یا IP مقابل از قبل ثبت شده است.')
        # Encapsulation on an interface and its outer endpoint must not be charged twice.
        iface = existing.get('interface') if peer else interface
        endpoint = peer if peer else existing.get('peer')
        if iface and endpoint:
            links = json.loads(run(['ip', '-j', '-d', 'link', 'show', 'dev', iface]).stdout)
            remote = links[0].get('linkinfo', {}).get('info_data', {}).get('remote')
            if not remote or remote == endpoint:
                raise ValueError('شمارش IP مقابل و اینترفیس هم‌پوشان یا نامشخص است؛ مقصدهای مستقل انتخاب کنید.')
    t = dict(interface=interface, peer=peer, mode=mode, limit=limit,
             download=0, upload=0, blocked=False, boot=BOOT)
    data[name] = t
    save(data)
    ensure(name, t)
    # Start the cycle at registration, rather than charging historical traffic.
    sample(name, t)
    t['download'] = t['upload'] = 0
    enforce(name, t)
    save(data)

def discover(data):
    # GRE/TUN counters count inner traffic; remote-IP counters count wire بایت.
    registry = Path('/etc/gre-panel/peers.json')
    peers = json.loads(registry.read_text()).get('peers', []) if registry.exists() else []
    for p in peers:
        if p.get('engine', 'frp') != 'frp':
            continue
        name = 'peer-'+str(p['id'])
        if name in data:
            continue
        iface = p.get('gre_if')
        if iface and Path('/sys/class/net', iface).exists():
            if any(t.get('interface') == iface for t in data.values()):
                continue
            add(data, name, interface=iface)
    known = {t.get('interface') for t in data.values()}
    for path in Path('/sys/class/net').iterdir():
        if re.fullmatch(r'gre-tunnel|gre-t\d+', path.name) and path.name not in known:
            add(data, path.name, interface=path.name)

def show(data):
    print('دانلود دریافت و آپلود ارسال همین سرور است؛ حجم‌ها بر حسب GiB نمایش داده می‌شوند.')
    if not data:
        print('شمارنده‌ای ثبت نشده است؛ ابتدا تونل‌ها را شناسایی یا یک شمارنده ثبت کنید.')
    labels={}
    try:
        registry=json.loads(Path('/etc/gre-panel/peers.json').read_text())
        labels={t.get('gre_if'):t.get('name','') for t in registry.get('peers',[])}
    except (OSError,ValueError):
        pass
    units=lambda value:'%.3f GiB'%(value/2**30)
    for name,t in data.items():
        label=labels.get(t.get('interface')) or name
        print('\nتونل: '+label+' | شمارنده: '+name+' | مقصد: '+str(t.get('interface') or t.get('peer')))
        print('  دانلود: '+units(t['download']))
        print('  آپلود: '+units(t['upload']))
        print('  مجموع: '+units(t['download']+t['upload']))
        print('  نحوه محاسبه: '+dict(download='دانلود',upload='آپلود',both='هر دو')[t['mode']])
        print('  مصرف برای سقف: '+units(consumed(t)))
        print('  سقف: '+(units(t['limit']) if t['limit'] else 'نامحدود'))
        print('  وضعیت: '+('مسدود' if t.get('blocked') else 'باز'))

_argument_messages = {
    'usage: ': 'روش استفاده: ', 'options': 'گزینه‌ها', 'positional arguments': 'فرمان‌ها و ورودی‌ها',
    'show this help message and exit': 'نمایش راهنما و خروج',
    'the following arguments are required: %s': 'این گزینه‌ها ضروری‌اند: %s',
    'unrecognized arguments: %s': 'گزینه‌های ناشناخته: %s',
    'argument %s: %s': 'گزینه %s: %s',
    'expected one argument': 'یک مقدار لازم است',
    'invalid choice: %(value)r (choose from %(choices)s)': 'مقدار نامعتبر: %(value)r (گزینه‌ها: %(choices)s)',
    'not allowed with argument %s': 'با گزینه %s سازگار نیست',
    'one of the arguments %s is required': 'یکی از گزینه‌های %s ضروری است',
    '%(prog)s: error: %(message)s\n': '%(prog)s: خطا: %(message)s\n',
}
argparse._ = lambda text: _argument_messages.get(text,text)

def main():
    parser = argparse.ArgumentParser(description='شمارنده و سقف دائمی ترافیک هر تونل؛ دانلود دریافت و آپلود ارسال همین سرور است.')
    sub = parser.add_subparsers(dest='cmd', required=True)
    for cmd in ('list', 'discover', 'tick', 'clear'):
        sub.add_parser(cmd)
    p = sub.add_parser('add'); p.add_argument('id')
    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument('--interface'); target.add_argument('--peer')
    p.add_argument('--limit', type=argument_size, default=0); p.add_argument('--mode', choices=MODES, default='both')
    for cmd in ('status', 'reset', 'remove'):
        p=sub.add_parser(cmd); p.add_argument('id')
    p=sub.add_parser('limit'); p.add_argument('id'); p.add_argument('size', type=argument_size)
    p.add_argument('--mode', choices=MODES)
    p=sub.add_parser('mode'); p.add_argument('id'); p.add_argument('mode', choices=MODES)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('با دسترسی روت اجرا کنید.')
    STATE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE.with_suffix('.lock'), 'a') as lock:
        os.chmod(lock.name, 0o600); fcntl.flock(lock, fcntl.LOCK_EX)
        data = json.loads(STATE.read_text()) if STATE.exists() else {}
        if getattr(args, 'id', None) and args.cmd != 'add' and args.id not in data:
            raise ValueError('شناسه شمارنده ناشناخته است؛ traffic discover، traffic list یا traffic add را اجرا کنید.')
        if args.cmd == 'add':
            add(data, args.id, args.interface, args.peer, args.limit, args.mode)
        elif args.cmd == 'discover':
            discover(data)
        elif args.cmd in ('remove', 'clear'):
            for name in [args.id] if args.cmd == 'remove' else list(data):
                detach(name, data[name]); del data[name]; save(data)
        else:
            selected = [args.id] if getattr(args, 'id', None) else list(data)
            failures = []
            for name in selected:
                t = data[name]
                try:
                    sample(name, t)
                    if args.cmd == 'reset':
                        t['download'] = t['upload'] = 0
                    elif args.cmd == 'limit':
                        t['limit'] = args.size
                        if args.mode: t['mode'] = args.mode
                    elif args.cmd == 'mode':
                        t['mode'] = args.mode
                    # Save counters and desired quota state before modifying rules.
                    t['blocked'] = bool(t['limit'] and consumed(t) >= t['limit'])
                    save(data); enforce(name, t); save(data)
                except (ValueError, subprocess.CalledProcessError) as e:
                    failures.append(name+': '+str(e))
            if failures:
                raise ValueError('; '.join(failures))
        save(data)
        if args.cmd != 'tick':
            show({args.id:data[args.id]} if getattr(args,'id',None) and args.id in data else data)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as e:
        print('خطای شمارش ترافیک: '+str(e), file=sys.stderr)
        if isinstance(e, subprocess.CalledProcessError): print(e.stderr, file=sys.stderr)
        sys.exit(1)
PY
