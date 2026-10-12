#!/usr/bin/env python3
"""Bounded synthetic fixtures for optional native framework preparation."""

import os
import hashlib
import json
import plistlib
import shutil
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

    def test_framework_links_inside_artifact_but_outside_bundle_are_rejected(self):
        for name in ("Headers", "whisper"):
            with self.subTest(name=name):
                self.artifact = self.root / (name + ".xcframework")
                framework = self.framework()
                shared = self.artifact / "Shared"
                shared.mkdir()
                if name == "Headers":
                    outside = shared / "Headers"
                    outside.mkdir()
                    protected = outside / "whisper.h"
                    protected.write_text("void whisper_free(void *ctx);\n")
                else:
                    outside = shared / "whisper"
                    protected = outside
                    protected.write_bytes(macho())
                original = protected.read_bytes()
                link = framework / name
                link.unlink()
                relative = "../../Shared/" + name
                link.symlink_to(relative)
                result = self.run_cli()
                self.assert_failure(result)
                self.assertIn("selected framework bundle", result.stderr)
                self.assertEqual(os.readlink(link), relative)
                self.assertEqual(protected.read_bytes(), original)
                self.assertFalse(self.config.exists())
                self.assertFalse(self.embed.exists())

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

    def test_generated_filelists_enumerate_only_verified_bundle_inputs_and_outputs(self):
        framework = self.framework()
        self.assertEqual(self.run_cli(embed=False).returncode, 0)
        inputs = self.config.with_suffix(".inputs.xcfilelist")
        outputs = self.config.with_suffix(".outputs.xcfilelist")
        self.assertTrue(inputs.exists())
        source_paths = {line for line in inputs.read_text().splitlines() if line and not line.startswith("#")}
        self.assertIn(str(self.config), source_paths)
        self.assertIn(str(self.artifact / "Info.plist"), source_paths)
        self.assertIn(str(framework / "whisper"), source_paths)
        self.assertIn(str(framework / "Versions/A/whisper"), source_paths)
        self.assertNotIn(str(self.root), source_paths)
        output_paths = {line for line in outputs.read_text().splitlines() if line and not line.startswith("#")}
        prefix = "$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)"
        self.assertIn(prefix + "/whisper.framework/Versions/A/whisper", output_paths)
        self.assertTrue(all(path.startswith(prefix) for path in output_paths))
        self.assertIn("VARTA_WHISPER_INPUT_FILE_LIST = " + str(inputs), self.config.read_text())
        self.assertIn("VARTA_WHISPER_OUTPUT_FILE_LIST = " + str(outputs), self.config.read_text())

    def test_static_framework_declares_no_embed_outputs(self):
        self.framework(b"!<arch>\n")
        self.assertEqual(self.run_cli(embed=False).returncode, 0)
        outputs = self.config.with_suffix(".outputs.xcfilelist").read_text()
        self.assertFalse(any(line and not line.startswith("#") for line in outputs.splitlines()))

    def test_existing_user_filelist_is_preserved(self):
        self.framework()
        self.config.parent.mkdir(parents=True)
        inputs = self.config.with_suffix(".inputs.xcfilelist")
        inputs.write_text("/user/input\n")
        self.assert_failure(self.run_cli())
        self.assertEqual(inputs.read_text(), "/user/input\n")
        self.assertFalse(self.config.exists())
        self.assertFalse(self.embed.exists())

    def test_xcode_empty_directory_skeleton_can_receive_framework(self):
        self.framework()
        for name in ("Versions/A/Headers", "Versions/A/Modules"):
            (self.embed / "whisper.framework" / name).mkdir(parents=True, exist_ok=True)
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.embed / "whisper.framework/whisper").read_bytes(), macho())
        self.assertEqual(os.readlink(self.embed / "whisper.framework/Versions/Current"), "A")

    def test_partial_file_symlink_or_unknown_directory_is_preserved_and_rejected(self):
        self.framework()
        for name, entry_kind in (("Versions/A/whisper", "file"), ("Versions/A/Headers", "symlink"),
                                 ("user-directory", "directory"), ("Headers", "directory")):
            with self.subTest(name=name, entry_kind=entry_kind):
                self.embed = self.root / ("output-" + name.replace("/", "-"))
                entry = self.embed / "whisper.framework" / name
                entry.parent.mkdir(parents=True)
                if entry_kind == "file":
                    entry.write_bytes(b"preserve")
                elif entry_kind == "symlink":
                    entry.symlink_to("elsewhere")
                else:
                    entry.mkdir()
                self.assert_failure(self.run_cli())
                if entry_kind == "file":
                    self.assertEqual(entry.read_bytes(), b"preserve")
                elif entry_kind == "symlink":
                    self.assertEqual(os.readlink(entry), "elsewhere")
                else:
                    self.assertTrue(entry.is_dir())

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("sandbox-exec"), "macOS sandbox-exec required")
    def test_literal_filelist_permissions_allow_sandboxed_embedding(self):
        self.framework()
        self.assertEqual(self.run_cli(embed=False).returncode, 0)
        for name in ("Versions/A/Headers", "Versions/A/Modules"):
            (self.embed / "whisper.framework" / name).mkdir(parents=True, exist_ok=True)
        inputs = [line for line in self.config.with_suffix(".inputs.xcfilelist").read_text().splitlines()
                  if line and not line.startswith("#")]
        inputs.append(str(SCRIPT))
        outputs = [line.replace("$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)", str(self.embed))
                   for line in self.config.with_suffix(".outputs.xcfilelist").read_text().splitlines()
                   if line and not line.startswith("#")]
        source_root = SCRIPT.parents[1]
        blocked_roots = (self.root, source_root)
        rules = ["(version 1)", "(allow default)"]
        rules.extend("(deny file-read* file-write* (subpath " + json.dumps(str(root)) + "))" for root in blocked_roots)
        for value in inputs + outputs:
            for parent in Path(value).parents:
                if any(parent == root or root in parent.parents for root in blocked_roots):
                    rules.append("(allow file-read* (literal " + json.dumps(str(parent)) + "))")
        rules.extend("(allow file-read* (literal " + json.dumps(value) + "))" for value in inputs)
        rules.extend("(allow file-read* file-write* (literal " + json.dumps(value) + "))" for value in outputs)
        profile = self.root / "embed.sb"
        profile.write_text("\n".join(rules))
        result = subprocess.run(["sandbox-exec", "-f", str(profile), sys.executable, str(SCRIPT),
                                 "--prepared-config", str(self.config), "--embed-directory", str(self.embed)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.embed / "whisper.framework/whisper").read_bytes(), macho())


if __name__ == "__main__":
    unittest.main()
