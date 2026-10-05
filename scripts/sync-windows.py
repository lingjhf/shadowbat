#!/usr/bin/env python3
"""Overlay project source on the authorized Windows checkout; preserve remote builds."""
import base64
import pathlib
import subprocess
import tarfile
import tempfile
import uuid
import sys
ROOT = pathlib.Path(__file__).resolve().parent.parent
EXCLUDE = {'.git', '.dart_tool', 'build', '.idea', '.DS_Store', 'ephemeral', '.swiftpm', '__pycache__'}
with tempfile.TemporaryDirectory(prefix='shadowbat-sync-') as temporary:
    name = 'shadowbat-sync-' + uuid.uuid4().hex + '.tar.gz'
    archive = pathlib.Path(temporary) / name
    with tarfile.open(archive, 'w:gz') as tar:
        for file in ROOT.rglob('*'):
            relative = file.relative_to(ROOT)
            if any(part in EXCLUDE for part in relative.parts) or file.is_symlink() or not file.is_file():
                continue
            if '--source-only' in sys.argv and (file.suffix.lower() in {'.exe', '.dll'} or relative.as_posix() == 'macos/Tools/sslocal'):
                continue
            tar.add(file, arcname=relative.as_posix(), recursive=False)
    subprocess.run(['scp', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3', str(archive), 'windows:D:/workspace/' + name], check=True)
    script = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; New-Item -ItemType Directory -Force D:\\workspace\\shadowbat | Out-Null; tar -xzf 'D:\\workspace\\" + name + "' -C D:\\workspace\\shadowbat; if ($LASTEXITCODE -ne 0) { throw 'Archive extraction failed' }; Remove-Item 'D:\\workspace\\" + name + "'; Write-Output 'Synced D:\\workspace\\shadowbat'"
    encoded = base64.b64encode(script.encode('utf-16le')).decode()
    subprocess.run(['ssh', '-o', 'ConnectTimeout=10', 'windows', 'powershell -NoProfile -EncodedCommand ' + encoded], check=True)
