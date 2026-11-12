"""更新先・署名欠落・バージョン逆行を、配布前に拒否することを確認する。"""
import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("sparkle", ROOT / "scripts/sparkle.py")
sparkle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sparkle)

# 固定のテスト用 seed（32 byte の 0x01）で "test archive" に署名した値。
TEST_PUBLIC_KEY = 'iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w='
TEST_SIGNATURE = ('p0ZBblpSO7Ip/eVMjMbU9hBcm87yzobSEI327DYj3knI'
                  'Xakiu+j46jkb2Pv16ddHWiP2k6WHAUUeRKWmU0szDw==')


class SparklePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / 'DevSwitcher-0.1.2-3-release.dmg'
        self.archive.write_bytes(b'test archive')
        self.feed = self.root / 'appcast.xml'
        self.tree = ET.Element('rss', version='2.0')
        channel = ET.SubElement(self.tree, 'channel')
        self.item = ET.SubElement(channel, 'item')
        ET.SubElement(self.item, sparkle.SPARKLE + 'version').text = '3'
        ET.SubElement(self.item, sparkle.SPARKLE + 'shortVersionString').text = '0.1.2'
        ET.SubElement(self.item, sparkle.SPARKLE + 'minimumSystemVersion').text = '15.0'
        self.enclosure = ET.SubElement(self.item, 'enclosure', {
            'url': sparkle.REPOSITORY_URL + '/releases/download/v0.1.2/' + self.archive.name,
            'length': str(self.archive.stat().st_size),
            sparkle.SPARKLE + 'edSignature': TEST_SIGNATURE
        })

    def validate(self, previous=None):
        ET.ElementTree(self.tree).write(self.feed)
        sparkle.validate_feed(self.feed, self.archive, '0.1.2', '3', previous)

    def test_valid_feed(self):
        self.validate()

    def test_appcast_script_without_previous_release(self):
        # macOS 標準の Bash でも、前回 appcast がない初回配布を生成できる。
        # 外部の署名ツールだけを差し替え、検証・コピー・ハッシュ生成は実処理を通す。
        self.validate()
        repository = self.root / 'repository'
        scripts = repository / 'scripts'
        scripts.mkdir(parents=True)
        for name in ['generate-appcast.sh', 'sparkle.py', 'verify-sparkle-update.swift']:
            shutil.copy2(ROOT / 'scripts' / name, scripts / name)
        distribution = repository / 'dist/0.1.2-3-release'
        distribution.mkdir(parents=True)
        shutil.copy2(self.archive, distribution / self.archive.name)
        shutil.copy2(self.archive, distribution / 'DevSwitcher.dmg')
        build_root = self.root / 'build'
        tool = build_root / 'arm64/artifacts/sparkle/Sparkle/bin/generate_appcast'
        tool.parent.mkdir(parents=True)
        tool.write_text('''#!/usr/bin/env python3
import os, shutil, sys
sys.stdin.read()
shutil.copyfile(os.environ['MOCK_APPCAST'], sys.argv[sys.argv.index('-o') + 1])
''')
        tool.chmod(0o755)
        env = dict(os.environ, APP_VERSION='0.1.2', APP_BUILD='3',
                   APP_BUILD_ROOT=str(build_root), MOCK_APPCAST=str(self.feed),
                   SPARKLE_ED_PRIVATE_KEY='fixture-only',
                   SPARKLE_PUBLIC_ED_KEY=TEST_PUBLIC_KEY)
        env.pop('SPARKLE_KEY_ACCOUNT', None)
        env.pop('PREVIOUS_APPCAST', None)
        result = subprocess.run(['/bin/bash', str(scripts / 'generate-appcast.sh')],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((distribution / 'appcast.xml').read_bytes(), self.feed.read_bytes())
        result = subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS.txt'],
                                cwd=distribution, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rejects_unsigned_update(self):
        del self.enclosure.attrib[sparkle.SPARKLE + 'edSignature']
        with self.assertRaisesRegex(ValueError, 'signature'):
            self.validate()

    def test_rejects_mutable_download(self):
        self.enclosure.set('url', sparkle.REPOSITORY_URL + '/releases/latest/download/DevSwitcher.dmg')
        with self.assertRaisesRegex(ValueError, 'immutable'):
            self.validate()

    def test_rejects_changed_archive(self):
        self.archive.write_bytes(b'changed after signing')
        with self.assertRaisesRegex(ValueError, 'size'):
            self.validate()

    def test_signature_matches_configured_public_key(self):
        self.validate()
        sparkle.validate_feed(self.feed, self.archive, '0.1.2', '3',
                              public_key=TEST_PUBLIC_KEY)

        self.archive.write_bytes(b'test archivf')  # 同じサイズでも署名が違う。
        with self.assertRaisesRegex(ValueError, 'signature'):
            sparkle.validate_feed(self.feed, self.archive, '0.1.2', '3',
                                  public_key=TEST_PUBLIC_KEY)

        self.archive.write_bytes(b'test archive')
        with self.assertRaisesRegex(ValueError, 'signature'):
            sparkle.validate_feed(self.feed, self.archive, '0.1.2', '3',
                                  public_key=base64.b64encode(bytes(32)).decode())

    def test_rejects_wrong_version_or_build(self):
        for tag in ['version', 'shortVersionString']:
            with self.subTest(tag=tag):
                element = self.item.find(sparkle.SPARKLE + tag)
                original = element.text
                element.text = '99'
                with self.assertRaises(ValueError):
                    self.validate()
                element.text = original

    def test_rejects_equal_or_older_build(self):
        for build in ['3', '4']:
            with self.subTest(build=build):
                previous = self.root / 'previous.xml'
                self.item.find(sparkle.SPARKLE + 'version').text = build
                ET.ElementTree(self.tree).write(previous)
                self.item.find(sparkle.SPARKLE + 'version').text = '3'
                with self.assertRaisesRegex(ValueError, 'greater'):
                    self.validate(previous)

    def test_accepts_newer_build(self):
        previous = self.root / 'previous.xml'
        self.item.find(sparkle.SPARKLE + 'version').text = '2'
        ET.ElementTree(self.tree).write(previous)
        self.item.find(sparkle.SPARKLE + 'version').text = '3'
        self.validate(previous)

    def test_release_requires_public_key(self):
        path = self.root / 'Info.plist'
        original = (ROOT / 'packaging/Info.plist').read_bytes()
        path.write_bytes(original)
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'SPARKLE_PUBLIC_ED_KEY'):
                sparkle.configure(path, release=True)
        self.assertEqual(path.read_bytes(), original)

    def test_release_enables_checks_and_local_build_disables_updates(self):
        path = self.root / 'Info.plist'
        path.write_bytes((ROOT / 'packaging/Info.plist').read_bytes())
        key = base64.b64encode(bytes(32)).decode()
        with patch.dict(os.environ, {'SPARKLE_PUBLIC_ED_KEY': key}):
            sparkle.configure(path, release=True)
        info = plistlib.loads(path.read_bytes())
        self.assertTrue(info['DevSwitcherUpdatesEnabled'])
        self.assertEqual(info['SUPublicEDKey'], key)
        self.assertTrue(info['SUEnableAutomaticChecks'])
        self.assertFalse(info['SUAllowsAutomaticUpdates'])
        self.assertFalse(info['SUAutomaticallyUpdate'])
        self.assertFalse(info['SUSendProfileInfo'])
        sparkle.configure(path, release=False)
        info = plistlib.loads(path.read_bytes())
        self.assertFalse(info['DevSwitcherUpdatesEnabled'])
        self.assertNotIn('SUPublicEDKey', info)


if __name__ == '__main__':
    unittest.main()
