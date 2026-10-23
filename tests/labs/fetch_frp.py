#!/usr/bin/env python3
"""Fetch pinned official FRP lab binaries and verify their release SHA256 manifest."""
import hashlib
import json
from pathlib import Path
import sys
import tarfile
import urllib.request

VERSION='0.71.0'
folder=Path(sys.argv[1]);folder.mkdir(parents=True,exist_ok=True)
with urllib.request.urlopen('https://api.github.com/repos/fatedier/frp/releases/tags/v'+VERSION,timeout=30) as response:release=json.load(response)
assets={a['name']:a['browser_download_url'] for a in release['assets']}
name='frp_'+VERSION+'_linux_amd64.tar.gz'
with urllib.request.urlopen(assets['frp_sha256_checksums.txt'],timeout=30) as response:manifest=response.read().decode()
expected=next(line.split()[0] for line in manifest.splitlines() if line.split()[-1].lstrip('*')==name)
with urllib.request.urlopen(assets[name],timeout=90) as response:data=response.read()
if hashlib.sha256(data).hexdigest()!=expected:raise SystemExit('FRP archive checksum does not match the official release manifest.')
archive=folder/name;archive.write_bytes(data)
with tarfile.open(archive) as tar:
    for executable in ('frps','frpc'):
        member=next(m for m in tar.getmembers() if m.name.endswith('/'+executable) and m.isfile())
        target=folder/executable;target.write_bytes(tar.extractfile(member).read());target.chmod(0o755)
print('Verified FRP '+VERSION+' lab binaries in '+str(folder))
