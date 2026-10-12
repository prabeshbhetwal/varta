#!/usr/bin/env python3
"""Bounded synthetic fixtures for optional native framework preparation."""

import os
import hashlib
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "Native" / "prepare-whisper.py"


def macho(cpu=0x0100000C, filetype=6, endian="<"):
    return struct.pack(endian + "8I", 0xFEEDFACF, cpu, 0, filetype, 0, 0, 0, 0)


def fat(slices, endian=">", wide=False):
    record_size = 32 if wide else 20
    offset = 8 + record_size * len(slices)
    records = []
    payload = b""
    for cpu, binary in slices:
        if wide:
            records.append(struct.pack(endian + "IIQQII", cpu, 0, offset, len(binary), 0, 0))
        else:
            records.append(struct.pack(endian + "IIIII", cpu, 0, offset, len(binary), 0))
        offset += len(binary)
        payload += binary
    return struct.pack(endian + "II", 0xCAFEBABF if wide else 0xCAFEBABE, len(slices)) + b"".join(records) + payload


class NativeFrameworkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="varta-native-framework-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.artifact = self.root / "Native files" / "whisper-cpp.xcframework"
        self.config = self.root / "Generated files" / "whisper.xcconfig"
        self.embed = self.root / "App.app" / "Contents" / "Frameworks"

    def run_cli(self, artifact=None, config=None, embed=True):
        command = [sys.executable, str(SCRIPT), "--xcframework", str(artifact or self.artifact),
                   "--config-output", str(config or self.config)]
        if embed:
            command += ["--embed-directory", str(self.embed)]
        return subprocess.run(command, capture_output=True, text=True, timeout=10)

    def library(self, identifier="macos-arm64_x86_64", platform="macos", architectures=None, variant=None):
        entry = {"LibraryIdentifier": identifier, "LibraryPath": "whisper.framework",
                 "SupportedPlatform": platform, "SupportedArchitectures": architectures or ["arm64", "x86_64"]}
        if variant is not None:
            entry["SupportedPlatformVariant"] = variant
        return entry

    def write_plist(self, libraries):
        self.artifact.mkdir(parents=True, exist_ok=True)
        with (self.artifact / "Info.plist").open("wb") as stream:
            plistlib.dump({"AvailableLibraries": libraries, "CFBundlePackageType": "XFWK",
                          "XCFrameworkFormatVersion": "1.0"}, stream)

    def framework(self, binary=None, entry=None):
        entry = entry or self.library()
        self.write_plist([entry])
        framework = self.artifact / entry["LibraryIdentifier"] / "whisper.framework"
        version = framework / "Versions" / "A"
        (version / "Headers").mkdir(parents=True)
        (version / "Modules").mkdir()
        (version / "Headers" / "whisper.h").write_text("void whisper_free(void *ctx);\n")
        (version / "Modules" / "module.modulemap").write_text('framework module whisper { header "whisper.h" export * }\n')
        (version / "whisper").write_bytes(binary if binary is not None else macho())
        (framework / "Versions" / "Current").symlink_to("A")
        for name in ["Headers", "Modules", "whisper"]:
            (framework / name).symlink_to("Versions/Current/" + name)
        return framework

    def assert_failure(self, result):
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("error:", result.stderr)

    def test_absent_artifact_disables_link_and_embed(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        content = self.config.read_text()
        self.assertIn("FRAMEWORK_SEARCH_PATHS = $(inherited)\n", content)
        self.assertIn("OTHER_LDFLAGS = $(inherited)\n", content)
        self.assertNotIn("-framework whisper", content)
        self.assertFalse(self.embed.exists())

    def test_empty_library_placeholder_disables_native_link(self):
        self.write_plist([])
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("-framework whisper", self.config.read_text())

    def test_selects_macos_arm64_not_catalyst_and_quotes_spaces(self):
        framework = self.framework()
        self.write_plist([self.library("ios-catalyst", "ios", variant="maccatalyst"), self.library()])
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        content = self.config.read_text()
        self.assertIn('FRAMEWORK_SEARCH_PATHS = $(inherited) "' + str(framework.parent) + '"\n', content)
        self.assertIn("OTHER_LDFLAGS = $(inherited) -framework whisper\n", content)
        self.assertEqual(os.readlink(self.embed / "whisper.framework" / "whisper"), "Versions/Current/whisper")
        self.assertEqual((self.embed / "whisper.framework" / "whisper").read_bytes(), macho())

    def test_static_archive_links_without_embedding(self):
        self.framework(b"!<arch>\n")
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("static", result.stdout)
        self.assertIn("-framework whisper", self.config.read_text())
        self.assertFalse(self.embed.exists())

    def test_thin_macho_object_is_static(self):
        self.framework(macho(filetype=1))
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.embed.exists())

    def test_fat_macho_and_archive_slices_classify_consistently(self):
        for wide, endian, expected, arm, intel in [
            (False, ">", "dynamic", macho(), macho(0x01000007)),
            (True, "<", "dynamic", macho(), macho(0x01000007)),
            (False, ">", "static", b"!<arch>\n", b"!<arch>\n"),
        ]:
            with self.subTest(wide=wide, endian=endian, expected=expected):
                artifact = self.root / ("fat-" + str(wide) + endian.replace("<", "little").replace(">", "big") + expected)
                original = self.artifact
                self.artifact = artifact
                self.framework(fat([(0x0100000C, arm), (0x01000007, intel)], endian, wide))
                result = self.run_cli(config=self.root / (artifact.name + ".xcconfig"), embed=False)
                self.artifact = original
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stdout)

    def test_malformed_present_artifact_fails_without_output(self):
        self.artifact.mkdir(parents=True)
        (self.artifact / "Info.plist").write_bytes(b"invalid plist")
        self.assert_failure(self.run_cli())
        self.assertFalse(self.config.exists())

    def test_no_compatible_or_ambiguous_slice_fails(self):
        for entries in [[self.library(architectures=["x86_64"])], [self.library(), self.library("duplicate")]]:
            with self.subTest(entries=entries):
                self.write_plist(entries)
                self.assert_failure(self.run_cli())

    def test_traversal_metadata_is_rejected(self):
        self.write_plist([self.library("../escape")])
        self.assert_failure(self.run_cli())
        self.assertFalse(self.config.exists())

    def test_framework_symlink_cannot_escape_artifact(self):
        framework = self.framework()
        outside = self.root / "outside-secret"
        outside.write_text("private fixture")
        (framework / "Headers" / "escape").symlink_to(outside)
        self.assert_failure(self.run_cli())
        self.assertFalse(self.embed.exists())

    def test_info_plist_symlink_cannot_escape_artifact(self):
        self.artifact.mkdir(parents=True)
        outside = self.root / "outside.plist"
        outside.write_bytes(plistlib.dumps({"AvailableLibraries": []}))
        (self.artifact / "Info.plist").symlink_to(outside)
        self.assert_failure(self.run_cli())
        self.assertFalse(self.config.exists())

    def test_output_hardlink_cannot_change_another_file(self):
        self.framework()
        generated = self.root / "previous.xcconfig"
        generated.write_text("// Generated by Native/prepare-whisper.py. Do not edit.\n")
        self.config.parent.mkdir(parents=True)
        os.link(generated, self.config)
        self.assert_failure(self.run_cli())
        self.assertEqual(generated.read_text(), "// Generated by Native/prepare-whisper.py. Do not edit.\n")

    def test_config_and_embed_destinations_cannot_modify_artifact(self):
        self.framework()
        for destination in [self.artifact / "generated.xcconfig", self.artifact / "Info.plist"]:
            with self.subTest(destination=destination):
                self.assert_failure(self.run_cli(config=destination))
        self.embed = self.artifact / "embed"
        self.assert_failure(self.run_cli())

    def test_xcconfig_injection_paths_are_rejected(self):
        for fragment in ["bad\nOTHER_LDFLAGS = surprise", 'bad"quote', "bad$(inherited)", "bad\\escape"]:
            with self.subTest(fragment=fragment):
                self.assert_failure(self.run_cli(artifact=self.root / fragment))
        self.assertFalse(self.config.exists())

    def test_unrecognised_truncated_or_inconsistent_binaries_fail(self):
        binaries = [b"not a library", b"\xcf\xfa\xed\xfe", macho(0x01000007),
                    fat([(0x0100000C, macho()), (0x01000007, b"!<arch>\n")]),
                    struct.pack(">7I", 0xCAFEBABE, 1, 0x0100000C, 0, 9999, 32, 0)]
        for index, binary in enumerate(binaries):
            with self.subTest(index=index):
                self.artifact = self.root / ("invalid-" + str(index))
                self.framework(binary)
                self.assert_failure(self.run_cli())

    def test_user_outputs_are_preserved_and_repeat_embed_is_idempotent(self):
        self.framework()
        self.config.parent.mkdir(parents=True)
        self.config.write_text("// user configuration\n")
        self.assert_failure(self.run_cli())
        self.assertEqual(self.config.read_text(), "// user configuration\n")
        self.assertFalse(self.embed.exists())
        self.config = self.root / "owned.xcconfig"
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual(self.run_cli().returncode, 0)
        (self.embed / "whisper.framework" / "user-file").write_text("preserve")
        self.assert_failure(self.run_cli())
        self.assertEqual((self.embed / "whisper.framework" / "user-file").read_text(), "preserve")

    def archive(self, entries=None):
        archive = self.root / "whisper.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            if entries is not None:
                for name, content in entries:
                    stream.writestr(name, content)
            else:
                for path in self.artifact.rglob("*"):
                    name = "whisper.xcframework/" + path.relative_to(self.artifact).as_posix()
                    if path.is_symlink():
                        info = zipfile.ZipInfo(name)
                        info.create_system = 3
                        info.external_attr = (stat.S_IFLNK | 0o777) << 16
                        stream.writestr(info, os.readlink(path).encode())
                    elif path.is_file():
                        stream.write(path, name)
        return archive

    def run_archive(self, archive, checksum=None, destination=None):
        checksum = checksum or hashlib.sha256(archive.read_bytes()).hexdigest()
        return subprocess.run([sys.executable, str(SCRIPT), "--archive", str(archive),
                               "--sha256", checksum, "--extract-directory", str(destination or self.root / "extracted"),
                               "--config-output", str(self.config)], capture_output=True, text=True, timeout=10)

    def test_verified_archive_is_extracted_without_losing_framework_symlinks(self):
        self.framework()
        result = self.run_archive(self.archive())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-framework whisper", self.config.read_text())
        extracted = self.root / "extracted" / "whisper.xcframework" / "macos-arm64_x86_64" / "whisper.framework"
        self.assertEqual(os.readlink(extracted / "whisper"), "Versions/Current/whisper")
        self.assertEqual((extracted / "whisper").read_bytes(), macho())

    def test_archive_checksum_mismatch_writes_nothing(self):
        result = self.run_archive(self.archive([]), "0" * 64)
        self.assert_failure(result)
        self.assertIn("checksum", result.stderr)
        self.assertFalse((self.root / "extracted").exists())
        self.assertFalse(self.config.exists())

    def test_archive_traversal_and_existing_output_are_rejected(self):
        result = self.run_archive(self.archive([("../escape", b"bad")]))
        self.assert_failure(result)
        self.assertIn("non-traversing", result.stderr)
        destination = self.root / "user-output"
        destination.mkdir()
        (destination / "user-file").write_text("preserve")
        self.assert_failure(self.run_archive(self.archive([]), destination=destination))
        self.assertEqual((destination / "user-file").read_text(), "preserve")

    def test_archive_symlink_escape_is_rejected_before_extraction(self):
        archive = self.root / "escape.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            info = zipfile.ZipInfo("framework/Headers")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            stream.writestr(info, b"../../outside")
        result = self.run_archive(archive)
        self.assert_failure(result)
        self.assertIn("symlink", result.stderr)
        self.assertFalse((self.root / "extracted").exists())

    def test_archive_member_nested_under_symlink_is_rejected(self):
        archive = self.root / "nested.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            info = zipfile.ZipInfo("framework/Headers")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            stream.writestr(info, b"Versions/A/Headers")
            stream.writestr("framework/Headers/file", b"unsafe order")
        result = self.run_archive(archive)
        self.assert_failure(result)
        self.assertIn("nested inside a symlink", result.stderr)
        self.assertFalse((self.root / "extracted").exists())

    def test_prepared_config_embedding_does_not_rewrite_configuration(self):
        self.framework()
        self.assertEqual(self.run_cli(embed=False).returncode, 0)
        before = self.config.stat().st_mtime_ns
        result = subprocess.run([sys.executable, str(SCRIPT), "--prepared-config", str(self.config),
                                 "--embed-directory", str(self.embed)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.embed / "whisper.framework").exists())
        self.assertEqual(self.config.stat().st_mtime_ns, before)


if __name__ == "__main__":
    unittest.main()
