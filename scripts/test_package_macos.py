#!/usr/bin/env python3
"""Focused tests for release identity, architecture, and fail-closed notarization."""
import base64
import json
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import build_macos
import package_macos
import sparkle_support


class PackagingTests(unittest.TestCase):
    def package_args(self, output, app=Path("provided.app")):
        return SimpleNamespace(version="0.1.0-alpha.1", build_number="2", output_dir=output,
                               app=app, sign_identity=None, notary_profile=None)

    def provenance_fixture(self, root, relative="apps/macos/Sources/Hidden\nInput.swift"):
        source = root / relative
        source.parent.mkdir(parents=True)
        source.write_bytes(b"// committed source\n")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}

        def git(*args, **kwargs):
            return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True,
                                  env=environment, **kwargs)

        git("init", "-q")
        git("add", ".")
        git("-c", "user.name=Packaging Test", "-c", "user.email=packaging@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")
        return source, git

    def sparkle_fixture(self, package):
        """A versioned framework fixture with SwiftPM's actual provenance shape."""
        artifact = package / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework"
        framework = artifact / "macos-arm64_x86_64/Sparkle.framework"
        version = framework / "Versions/B"
        for name in ["Sparkle", "Autoupdate", "XPCServices/Installer.xpc/Contents/MacOS/Installer",
                     "XPCServices/Downloader.xpc/Contents/MacOS/Downloader", "Updater.app/Contents/MacOS/Updater"]:
            code = version / name
            code.parent.mkdir(parents=True, exist_ok=True)
            code.write_bytes(b"fixture nested code")
        (version / "Resources").mkdir()
        with (version / "Resources/Info.plist").open("wb") as target:
            plistlib.dump({"CFBundleIdentifier": "org.sparkle-project.Sparkle",
                          "CFBundleShortVersionString": sparkle_support.SPARKLE_VERSION,
                          "CFBundleVersion": sparkle_support.SPARKLE_BUILD}, target)
        (framework / "Versions/Current").symlink_to("B", target_is_directory=True)
        (framework / "Resources").symlink_to("Versions/Current/Resources", target_is_directory=True)
        (framework / "Sparkle").symlink_to("Versions/Current/Sparkle")
        with (artifact / "Info.plist").open("wb") as target:
            plistlib.dump({"AvailableLibraries": [{"LibraryIdentifier": "macos-arm64_x86_64",
                          "LibraryPath": "Sparkle.framework", "SupportedPlatform": "macos",
                          "SupportedArchitectures": ["arm64", "x86_64"]}]}, target)
        pin = {"revision": sparkle_support.SPARKLE_REVISION, "version": sparkle_support.SPARKLE_VERSION}
        (package / "Package.resolved").write_text(json.dumps({"pins": [{"identity": "sparkle",
            "location": sparkle_support.SPARKLE_URL, "state": pin}]}))
        manifest = {"object": {"dependencies": [{"packageRef": {"identity": "sparkle"},
                       "state": {"checkoutState": pin}}], "artifacts": [{
                       "packageRef": {"identity": "sparkle"}, "targetName": "Sparkle",
                       "path": str(artifact), "source": {"type": "remote",
                       "url": sparkle_support.SPARKLE_ARCHIVE_URL,
                       "checksum": sparkle_support.SPARKLE_CHECKSUM}}]}}
        (package / ".build/workspace-state.json").write_text(json.dumps(manifest))
        (artifact.parent / "LICENSE").write_bytes(b"Synthetic test dependency license\n")
        resources = package / "Resources"
        resources.mkdir(exist_ok=True)
        (resources / "UpdateConfiguration.json").write_text(json.dumps({
            "feed_url": sparkle_support.FEED_URL,
            "public_ed_key": base64.b64encode(bytes(range(32))).decode()}))
        return framework

    def test_prerelease_has_separate_numeric_apple_version(self):
        self.assertEqual(build_macos.version_metadata("0.1.0-alpha.1", "2"), {
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2",
            "RiverReleaseVersion": "0.1.0-alpha.1"})
        for invalid in ["v0.1.0", "../0.1.0", "0.1.0-alpha.01", "01.1.0", "0.1"]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                build_macos.version_metadata(invalid, "2")
        with self.assertRaises(ValueError):
            build_macos.version_metadata("0.1.0", "0")

    def test_developer_signs_nested_sparkle_inside_out_then_engine_and_bundle(self):
        details = {"Authority": ["Developer ID Application: Test"], "Timestamp": ["today"],
                   "TeamIdentifier": ["TEAM"], "CodeDirectory v": ["20500 flags=0x10000(runtime)"]}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            framework = self.sparkle_fixture(root / "package")
            bundle = root / "River.app"
            destination = bundle / "Contents/Frameworks/Sparkle.framework"
            shutil.copytree(framework, destination, symlinks=True)
            with patch.object(build_macos.subprocess, "run") as run, \
                    patch.object(build_macos, "signature_details", return_value=details), \
                    patch.object(build_macos, "signature_entitlements", return_value={
                        "com.apple.security.app-sandbox": True, "com.apple.security.network.client": True}):
                build_macos.sign_bundle(bundle, "identity")
            signed = [call.args[0] for call in run.call_args_list if "--sign" in call.args[0]]
            self.assertEqual([Path(command[-1]).relative_to(bundle).as_posix() if Path(command[-1]) != bundle else "."
                              for command in signed], [
                "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc",
                "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc",
                "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
                "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app",
                "Contents/Frameworks/Sparkle.framework", "Contents/Helpers/workbench", "."])
            for index, command in enumerate(signed):
                self.assertIn("--timestamp", command)
                self.assertNotIn("--deep", command)
                self.assertEqual(command[command.index("--options") + 1], "runtime")
                self.assertEqual("--preserve-metadata=entitlements" in command, index < 5)

    def test_signing_failure_propagates_without_signing_outer_bundle(self):
        with patch.object(build_macos, "signed_code_paths", return_value=[Path("Installer.xpc"), Path("River.app")]), \
                patch.object(build_macos.subprocess, "run", side_effect=
                             subprocess.CalledProcessError(1, ["codesign"])) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                build_macos.sign_bundle(Path("River.app"), "identity")
        self.assertEqual(run.call_count, 1)

    def test_same_team_image_signature_still_requires_developer_id_and_timestamp(self):
        cases = [({"Authority": ["Apple Development: Test"], "TeamIdentifier": ["TEAM"],
                   "Timestamp": ["today"]}, "Developer ID Application"),
                 ({"Authority": ["Developer ID Application: Test"], "TeamIdentifier": ["TEAM"]},
                  "secure timestamp")]
        for details, message in cases:
            with self.subTest(message=message), patch.object(package_macos, "run"), \
                    patch.object(package_macos, "signature_details", return_value=details):
                with self.assertRaisesRegex(ValueError, message):
                    package_macos.verify_distribution_image_signature(Path("River.dmg"), "TEAM")

    def test_bundle_requires_matching_binary_architectures_and_release_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "River.app"
            (bundle / "Contents").mkdir(parents=True)
            info = {"CFBundleIdentifier": build_macos.APP_IDENTIFIER,
                    "CFBundleExecutable": build_macos.APP_EXECUTABLE,
                    "RiverBuildConfiguration": "release",
                    **build_macos.version_metadata("0.1.0-alpha.1", "2")}
            with (bundle / "Contents/Info.plist").open("wb") as target:
                plistlib.dump(info, target)
            with patch.object(package_macos, "architectures", side_effect=[{"arm64"}, {"x86_64"}]), \
                    patch.object(package_macos, "verify_signature") as verify:
                with self.assertRaisesRegex(ValueError, "architectures differ"):
                    package_macos.bundle_metadata(bundle)
                verify.assert_not_called()
            info["RiverBuildConfiguration"] = "debug"
            with (bundle / "Contents/Info.plist").open("wb") as target:
                plistlib.dump(info, target)
            with self.assertRaisesRegex(ValueError, "release bundle"):
                package_macos.bundle_metadata(bundle)

    def test_notarization_rejection_even_with_success_exit_does_not_staple(self):
        result = subprocess.CompletedProcess([], 0, json.dumps({"status": "Invalid", "id": "id"}), "")
        with patch.object(package_macos.subprocess, "run", return_value=result) as run:
            with self.assertRaisesRegex(ValueError, "not accepted"):
                package_macos.notarize(Path("River.dmg"), "profile")
        self.assertEqual(run.call_count, 1)

    def test_notarization_credentials_error_is_not_echoed(self):
        result = subprocess.CompletedProcess([], 1, "", "sensitive credential error")
        with patch.object(package_macos.subprocess, "run", return_value=result):
            with self.assertRaises(ValueError) as failure:
                package_macos.notarize(Path("River.dmg"), "profile")
        self.assertNotIn("sensitive", str(failure.exception))

    def test_stapling_failure_does_not_report_notarization_success(self):
        accepted = subprocess.CompletedProcess([], 0, json.dumps({"status": "Accepted", "id": "id"}), "")
        failed = subprocess.CompletedProcess([], 1, "", "")
        with patch.object(package_macos.subprocess, "run", side_effect=[accepted, failed]) as run:
            with self.assertRaisesRegex(ValueError, "staple failed"):
                package_macos.notarize(Path("River.dmg"), "profile")
        self.assertEqual(run.call_count, 2)

    def test_competing_cli_fails_without_touching_outputs_and_lock_file_persists(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            existing = output / "River-0.1.0-alpha.1-macos-arm64.dmg"
            existing.write_bytes(b"existing release")
            with package_macos.output_lock(output):
                result = subprocess.run([sys.executable, str(Path(package_macos.__file__).resolve()),
                                         "--version", "0.1.0-alpha.1", "--build-number", "2",
                                         "--app", "/nonexistent/River.app", "--output-dir", str(output)],
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("another packager", result.stderr)
                self.assertEqual(existing.read_bytes(), b"existing release")
                self.assertFalse(list(output.glob(".river-release-*")))
            self.assertTrue((output / ".river-package.lock").is_file())
            with package_macos.output_lock(output):
                self.assertEqual(existing.read_bytes(), b"existing release")

    def test_packaging_requires_an_explicit_release_identity(self):
        for identity in [[], ["--version", "0.1.0-alpha.3"], ["--build-number", "4"]]:
            with self.subTest(identity=identity):
                result = subprocess.run([sys.executable, str(Path(package_macos.__file__).resolve()),
                                         *identity, "--app", "/nonexistent/River.app"],
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--version and --build-number are required", result.stderr)
        with patch.object(sys, "argv", ["package_macos.py", "--verify-dmg", "existing.dmg"]), \
                patch.object(package_macos, "verify_dmg", return_value={}) as verify, \
                patch("builtins.print"):
            package_macos.main()
        verify.assert_called_once()

    def test_cargo_reported_executable_is_bundled_with_target_directory_overrides(self):
        # Exercise Cargo itself: its executable moves with both env and config,
        # while an obsolete binary remains at the previously hard-coded path.
        for override in ["environment", "config", "target"]:
            with self.subTest(override=override), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "src").mkdir()
                (root / "src/main.rs").write_text('fn main() { println!("current engine"); }\n')
                (root / "Cargo.toml").write_text(
                    '[package]\nname="workbench-cli"\nversion="0.1.0"\nedition="2024"\n'
                    '[[bin]]\nname="workbench"\npath="src/main.rs"\n')
                stale = root / "target/debug/workbench"
                stale.parent.mkdir(parents=True)
                stale.write_bytes(b"obsolete engine must not be packaged")
                environment = {key: value for key, value in os.environ.items()
                               if not key.startswith("CARGO_")}
                if override == "environment":
                    environment["CARGO_TARGET_DIR"] = str(root / "other-target")
                elif override == "config":
                    (root / ".cargo").mkdir()
                    (root / ".cargo/config.toml").write_text('[build]\ntarget-dir="other-target"\n')
                else:
                    host = subprocess.check_output(["rustc", "-vV"], text=True)
                    environment["CARGO_BUILD_TARGET"] = next(
                        line.split(": ", 1)[1] for line in host.splitlines() if line.startswith("host: "))
                swift = root / "swift"
                swift.mkdir()
                (swift / build_macos.APP_EXECUTABLE).write_bytes(b"swift app")
                package = root / "package"
                (package / "Resources").mkdir(parents=True)
                (package / "Resources/AppIcon.icns").write_bytes(b"icon")
                self.sparkle_fixture(package)
                with patch.object(build_macos, "ROOT", root), patch.dict(os.environ, environment, clear=True):
                    engine = build_macos.build_engine("debug")
                    bundle = root / "River.app"
                    with patch.object(build_macos, "sign_bundle"), \
                            patch.object(build_macos, "verify_sparkle_linkage"), \
                            patch.object(build_macos, "verify_original_framework"), \
                            patch.object(build_macos, "SPARKLE_LICENSE_SHA256", hashlib.sha256(b"Synthetic test dependency license\n").hexdigest()):
                        build_macos.assemble_bundle(bundle, swift, engine, package, "debug", {}, "-")
                bundled = bundle / "Contents/Helpers/workbench"
                self.assertTrue((bundle / "Contents/Frameworks/Sparkle.framework/Versions/Current").is_symlink())
                self.assertNotEqual(engine, stale)
                self.assertEqual(bundled.read_bytes(), engine.read_bytes())
                self.assertEqual(subprocess.check_output([bundled], text=True), "current engine\n")

    def test_provenance_ignores_foreign_git_environment_and_rejects_untracked_cargo_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "actual"
            foreign = Path(temporary) / "foreign"
            for repository in [root, foreign]:
                repository.mkdir()
                subprocess.run(["git", "init", "-q", repository], check=True)
                (repository / "source").write_text("original\n")
                subprocess.run(["git", "-C", repository, "add", "."], check=True)
                subprocess.run(["git", "-C", repository, "-c", "user.name=Packaging Test",
                                "-c", "user.email=packaging@example.invalid", "-c", "commit.gpgsign=false",
                                "-c", "core.hooksPath=/dev/null", "commit", "-qm", repository.name], check=True)
            initial = package_macos.clean_source_snapshot(root)
            with patch.dict(os.environ, {"GIT_DIR": str(foreign / ".git"), "GIT_WORK_TREE": str(foreign),
                                         "GIT_INDEX_FILE": str(foreign / ".git/index")}):
                self.assertEqual(package_macos.clean_source_snapshot(root), initial)
                (root / "source").write_text("dirty actual source\n")
                with self.assertRaisesRegex(ValueError, "clean tracked source"):
                    package_macos.clean_source_snapshot(root)
            (root / "source").write_text("original\n")
            (root / ".git/info/exclude").write_text(".cargo/\n")
            (root / ".cargo").mkdir()
            (root / ".cargo/config.toml").write_text('[build]\nrustflags=["--cfg", "untracked"]\n')
            with self.assertRaisesRegex(ValueError, "untracked build inputs"):
                package_macos.clean_source_snapshot(root)

    def test_provenance_rejects_suppressed_tracked_paths_without_mutating_source_or_index(self):
        for flag in ["--assume-unchanged", "--skip-worktree"]:
            for relative in ["apps/macos/Sources/Hidden\nInput.swift", "docs/release-notes.md"]:
                for modified in [False, True]:
                    with self.subTest(flag=flag, relative=relative, modified=modified), \
                            tempfile.TemporaryDirectory() as temporary:
                        root = Path(temporary)
                        source, git = self.provenance_fixture(root, relative)
                        package_macos.clean_source_snapshot(root)
                        git("update-index", flag, "--", relative)
                        if modified:
                            source.write_bytes(b"// hidden local modification\n")
                        self.assertEqual(git("status", "--porcelain=v1").stdout, b"")
                        source_before = source.read_bytes()
                        index_before = (root / ".git/index").read_bytes()
                        flags_before = git("ls-files", "-v", "-z").stdout
                        for snapshot in [package_macos.source_snapshot, package_macos.clean_source_snapshot]:
                            with self.assertRaisesRegex(ValueError, "assume-unchanged or skip-worktree"):
                                snapshot(root)
                        self.assertEqual(source.read_bytes(), source_before)
                        self.assertEqual((root / ".git/index").read_bytes(), index_before)
                        self.assertEqual(git("ls-files", "-v", "-z").stdout, flags_before)

    def test_new_suppression_after_initial_provenance_invalidates_final_check(self):
        for flag in ["--assume-unchanged", "--skip-worktree"]:
            for modified in [False, True]:
                with self.subTest(flag=flag, modified=modified), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    source, git = self.provenance_fixture(root)
                    initial = package_macos.clean_source_snapshot(root)
                    package_macos.verify_source_unchanged(initial, root)
                    git("update-index", flag, "--", source.relative_to(root))
                    if modified:
                        source.write_bytes(b"// changed during packaging\n")
                    source_before = source.read_bytes()
                    index_before = (root / ".git/index").read_bytes()
                    flags_before = git("ls-files", "-v", "-z").stdout
                    with self.assertRaisesRegex(ValueError, "assume-unchanged or skip-worktree"):
                        package_macos.verify_source_unchanged(initial, root)
                    self.assertEqual(source.read_bytes(), source_before)
                    self.assertEqual((root / ".git/index").read_bytes(), index_before)
                    self.assertEqual(git("ls-files", "-v", "-z").stdout, flags_before)

    def test_provenance_rechecks_suppression_before_returning_snapshot(self):
        for flag in ["--assume-unchanged", "--skip-worktree"]:
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source, git = self.provenance_fixture(root)
                original_run = package_macos.run

                def introduce_suppression(*argv, **kwargs):
                    result = original_run(*argv, **kwargs)
                    if "diff" in argv:
                        git("update-index", flag, "--", source.relative_to(root))
                        source.write_bytes(b"// changed while capturing provenance\n")
                    return result

                with patch.object(package_macos, "run", side_effect=introduce_suppression):
                    with self.assertRaisesRegex(ValueError, "assume-unchanged or skip-worktree"):
                        package_macos.clean_source_snapshot(root)

    def test_provenance_rejects_malformed_index_listings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.provenance_fixture(root)
            original_run = package_macos.run
            for listing in [b"H file", b"H\0", b"X file\0", b"H \0", b"\0"]:
                def malformed_listing(*argv, **kwargs):
                    if "ls-files" in argv and "-v" in argv:
                        return SimpleNamespace(stdout=listing)
                    return original_run(*argv, **kwargs)

                with self.subTest(listing=listing), \
                        patch.object(package_macos, "run", side_effect=malformed_listing):
                    with self.assertRaisesRegex(ValueError, "invalid tracked index listing"):
                        package_macos.clean_source_snapshot(root)

    def test_provenance_still_rejects_unmerged_tracked_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            relative = "apps/macos/Sources/Conflict.swift"
            source, git = self.provenance_fixture(root, relative)
            blob = git("rev-parse", f"HEAD:{relative}").stdout.strip()
            path = os.fsencode(relative)
            entries = b"0 " + b"0" * len(blob) + b"\t" + path + b"\0"
            entries += b"".join(b"100644 " + blob + b" " + str(stage).encode() + b"\t" + path + b"\0"
                                for stage in [1, 2, 3])
            git("update-index", "-z", "--index-info", input=entries)
            self.assertIn(b"M " + path + b"\0", git("ls-files", "-v", "-z").stdout)
            source_before = source.read_bytes()
            index_before = (root / ".git/index").read_bytes()
            with self.assertRaisesRegex(ValueError, "clean tracked source"):
                package_macos.clean_source_snapshot(root)
            self.assertEqual(source.read_bytes(), source_before)
            self.assertEqual((root / ".git/index").read_bytes(), index_before)

    def test_clean_provenance_checks_do_not_refresh_the_index(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, git = self.provenance_fixture(root)
            # Give status a changed stat cache while keeping the committed bytes.
            source_stat = source.stat()
            os.utime(source, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns + 2_000_000_000))
            source_before = source.read_bytes()
            index_before = (root / ".git/index").read_bytes()
            flags_before = git("ls-files", "-v", "-z").stdout
            initial = package_macos.clean_source_snapshot(root)
            self.assertEqual(initial["tracked_status"], "")
            self.assertEqual(initial["tracked_patch_sha256"], hashlib.sha256(b"").hexdigest())
            package_macos.verify_source_unchanged(initial, root)
            self.assertEqual(source.read_bytes(), source_before)
            self.assertEqual((root / ".git/index").read_bytes(), index_before)
            self.assertEqual(git("ls-files", "-v", "-z").stdout, flags_before)

    def test_existing_artifact_set_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            names = ["River-0.1.0-alpha.1-macos-arm64" + suffix
                     for suffix in [".dmg", ".dmg.sha256", ".manifest.json"]]
            for name in names:
                (output / name).write_bytes(name.encode())
            metadata = {"architecture": "arm64", "signing": {"kind": "ad-hoc"}}
            with patch.object(package_macos, "run"), \
                    patch.object(package_macos, "bundle_metadata", return_value=metadata):
                with self.assertRaisesRegex(ValueError, "already exist"):
                    package_macos.package(self.package_args(output))
            for name in names:
                self.assertEqual((output / name).read_bytes(), name.encode())

    def test_clean_provenance_ignores_archive_but_rejects_runtime_and_tracked_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "crates/cli/src/main.rs"
            source.parent.mkdir(parents=True)
            source.write_text("fn main() {}\n")
            (root / ".gitignore").write_text("*.swift\n")

            def git(*args):
                subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)

            git("init", "-q")
            git("config", "user.name", "Packaging Test")
            git("config", "user.email", "packaging@example.invalid")
            git("add", ".")
            git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")
            initial = package_macos.clean_source_snapshot(root)
            self.assertEqual(initial["tracked_patch_sha256"], hashlib.sha256(b"").hexdigest())
            (root / "archive").mkdir()
            (root / "archive/historical.txt").write_text("untracked history\n")
            self.assertEqual(package_macos.clean_source_snapshot(root), initial)
            ignored_source = root / "apps/macos/Sources/Ignored.swift"
            ignored_source.parent.mkdir(parents=True)
            ignored_source.write_text("// ignored but buildable\n")
            with self.assertRaisesRegex(ValueError, "untracked build inputs"):
                package_macos.clean_source_snapshot(root)
            ignored_source.unlink()
            source.write_text("fn main() { println!(\"changed\"); }\n")
            changed = package_macos.source_snapshot(root)
            self.assertNotEqual(changed["tracked_patch_sha256"], initial["tracked_patch_sha256"])
            with self.assertRaisesRegex(ValueError, "clean tracked source"):
                package_macos.clean_source_snapshot(root)
            with self.assertRaisesRegex(ValueError, "source changed"):
                package_macos.verify_source_unchanged(initial, root)
            source.write_text("fn main() {}\n")
            git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit",
                "--allow-empty", "-qm", "HEAD drift")
            with self.assertRaisesRegex(ValueError, "source changed"):
                package_macos.verify_source_unchanged(initial, root)

    def test_source_drift_after_build_publishes_no_artifacts(self):
        initial = {"kind": "clean-git-build", "git_commit": "initial", "tracked_status": "",
                   "tracked_patch_sha256": hashlib.sha256(b"").hexdigest(), "untracked_runtime_files": []}
        changed = {**initial, "git_commit": "changed"}
        metadata = {"architecture": "arm64", "signing": {"kind": "ad-hoc"}}
        readmes = []

        def fake_run(*argv, **kwargs):
            if argv[:2] == ("/usr/bin/hdiutil", "create"):
                readmes.append((Path(argv[-1]).parent / "payload/READ ME - INSTALL.txt").read_text())
                Path(argv[-1]).write_bytes(b"verified image for publication regression")

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with patch.object(package_macos, "run", side_effect=fake_run), \
                    patch.object(package_macos, "bundle_metadata", return_value=metadata), \
                    patch.object(package_macos, "verify_dmg", return_value=metadata), \
                    patch.object(package_macos, "source_snapshot", side_effect=[initial, changed]):
                with self.assertRaisesRegex(ValueError, "source changed"):
                    package_macos.package(self.package_args(output, app=None))
            self.assertEqual([path.name for path in output.iterdir()], [".river-package.lock"])
        for required in ["/usr/bin/git --version", "xcode-select --install", "python3",
                         "Reading status and diffs requires Apple Git 2.43 or later",
                         "상태와 Diff 조회에는 Apple Git 2.43 이상이 필요합니다",
                         "Full Xcode is not required", "전체 Xcode는 필요하지 않습니다",
                         "System Settings > Privacy & Security > Open Anyway",
                         "시스템 설정 > 개인정보 보호 및 보안 > 확인 없이 열기",
                         "https://support.apple.com/en-us/102445"]:
            self.assertIn(required, readmes[0])

    def test_update_configuration_rejects_missing_weak_and_noncanonical_keys_or_foreign_feeds(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "UpdateConfiguration.json"
            with self.assertRaises(FileNotFoundError):
                sparkle_support.load_update_configuration(path)
            good = {"feed_url": sparkle_support.FEED_URL,
                    "public_ed_key": base64.b64encode(bytes(range(32))).decode()}
            for config in [{**good, "public_ed_key": "placeholder"},
                           {**good, "public_ed_key": base64.b64encode(b"short").decode()},
                           {**good, "public_ed_key": base64.b64encode(bytes(32)).decode()},
                           {**good, "feed_url": "https://example.invalid/appcast.xml"},
                           {**good, "secret_key": "must never be bundled"}]:
                path.write_text(json.dumps(config))
                with self.subTest(config=config), self.assertRaises(ValueError):
                    sparkle_support.load_update_configuration(path)
            path.write_text(json.dumps(good))
            self.assertEqual(sparkle_support.load_update_configuration(path), good)

    def test_sparkle_comes_only_from_matching_resolved_remote_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary)
            framework = self.sparkle_fixture(package)
            self.assertEqual(sparkle_support.locate_sparkle_framework(package), framework)
            manifest_path = package / ".build/workspace-state.json"
            original = json.loads(manifest_path.read_text())
            for mutate in [lambda state: state["object"]["artifacts"][0]["source"].update(checksum="0" * 64),
                           lambda state: state["object"].update(artifacts=[]),
                           lambda state: state["object"]["artifacts"][0].update(path=str(package / "untrusted.xcframework")),
                           lambda state: state["object"]["dependencies"][0]["state"]["checkoutState"].update(version="2.9.0")]:
                state = json.loads(json.dumps(original))
                mutate(state)
                manifest_path.write_text(json.dumps(state))
                with self.assertRaises(ValueError):
                    sparkle_support.locate_sparkle_framework(package)
            manifest_path.write_text(json.dumps(original))
            (framework / "Sparkle").unlink()
            (framework / "Sparkle").symlink_to("/usr/bin/true")
            with self.assertRaisesRegex(ValueError, "unsafe or broken symlink"):
                sparkle_support.locate_sparkle_framework(package)

    def test_missing_framework_and_foreign_nested_team_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "framework is missing"):
                build_macos.sign_bundle(Path(temporary) / "River.app", "identity")
        good = {"Authority": ["Developer ID Application: Test"], "Timestamp": ["today"],
                "TeamIdentifier": ["TEAM"], "CodeDirectory v": ["20500 flags=0x10000(runtime)"]}
        with patch.object(build_macos, "signed_code_paths", return_value=[Path("framework"), Path("app")]), \
                patch.object(build_macos, "signature_details", side_effect=[good, {**good, "TeamIdentifier": ["OTHER"]}]), \
                patch.object(build_macos, "signature_entitlements", return_value={}):
            with self.assertRaisesRegex(ValueError, "signing teams differ"):
                build_macos.signing_metadata(Path("River.app"))

    def test_linkage_requires_embedded_framework_and_explicit_runtime_path(self):
        good_library = "app:\n\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.0.0)\n"
        good_rpath = "cmd LC_RPATH\n cmdsize 56\n path @executable_path/../Frameworks (offset 12)\n"
        with patch.object(build_macos.subprocess, "check_output", side_effect=[good_library, good_rpath]):
            build_macos.verify_sparkle_linkage(Path("app"))
        for libraries, rpath in [(good_library.replace("@rpath", "/tmp/build"), good_rpath),
                                 (good_library, good_rpath.replace("../Frameworks", "/tmp/Frameworks"))]:
            with patch.object(build_macos.subprocess, "check_output", side_effect=[libraries, rpath]):
                with self.assertRaises(ValueError):
                    build_macos.verify_sparkle_linkage(Path("app"))

    def test_distribution_rejects_disabled_library_validation(self):
        details = {"Authority": ["Developer ID Application: Test"], "Timestamp": ["today"],
                   "TeamIdentifier": ["TEAM"], "CodeDirectory v": ["20500 flags=0x10000(runtime)"]}
        for path, entitlements, message in [
                (Path("River.app"), {"com.apple.security.cs.disable-library-validation": True}, "library validation")]:
            with patch.object(build_macos, "signed_code_paths", return_value=[path]), \
                    patch.object(build_macos, "signature_details", return_value=details), \
                    patch.object(build_macos, "signature_entitlements", return_value=entitlements):
                with self.assertRaisesRegex(ValueError, message):
                    build_macos.signing_metadata(Path("River.app"))

    def test_lost_sparkle_entitlements_stop_before_outer_signing(self):
        paths = [Path("Downloader.xpc"), Path("workbench"), Path("River.app")]
        with patch.object(build_macos, "signed_code_paths", return_value=paths), \
                patch.object(build_macos, "signature_entitlements", side_effect=[{"network": True}, {}]), \
                patch.object(build_macos.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "entitlements were not preserved"):
                build_macos.sign_bundle(Path("River.app"), "identity")
        self.assertEqual(run.call_count, 1)

    def test_bundle_metadata_binds_update_policy_sparkle_and_entire_resource_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "package"
            framework = self.sparkle_fixture(package)
            bundle = root / "River.app"
            shutil.copytree(framework, bundle / "Contents/Frameworks/Sparkle.framework", symlinks=True)
            shutil.copytree(package / "Resources", bundle / "Contents/Resources")
            resources = bundle / "Contents/Resources"
            provenance = sparkle_support.framework_provenance(package, framework)
            license_bytes = (framework.parents[2] / "LICENSE").read_bytes()
            provenance["license_sha256"] = hashlib.sha256(license_bytes).hexdigest()
            (resources / "Sparkle-LICENSE.txt").write_bytes(license_bytes)
            (resources / "SparkleProvenance.json").write_text(json.dumps(provenance))
            for relative in ["Contents/MacOS/AgentGitWorkbench", "Contents/Helpers/workbench"]:
                code = bundle / relative
                code.parent.mkdir(parents=True)
                code.write_bytes(b"fixture executable")
            config = sparkle_support.load_update_configuration(resources / "UpdateConfiguration.json")
            info = {"CFBundleIdentifier": build_macos.APP_IDENTIFIER,
                    "CFBundleExecutable": build_macos.APP_EXECUTABLE,
                    "RiverBuildConfiguration": "release",
                    **build_macos.version_metadata("0.1.0-alpha.1", "2"),
                    **sparkle_support.update_info(config)}
            info_path = bundle / "Contents/Info.plist"
            with info_path.open("wb") as target:
                plistlib.dump(info, target)
            with patch.object(package_macos, "architectures", return_value={"arm64"}), \
                    patch.object(package_macos, "verify_signature"), \
                    patch.object(package_macos, "verify_sparkle_linkage"), \
                    patch.object(package_macos, "SPARKLE_LICENSE_SHA256", provenance["license_sha256"]), \
                    patch.object(package_macos, "signing_metadata", return_value={"kind": "developer-id", "team_identifier": "TEAM"}):
                metadata = package_macos.bundle_metadata(bundle)
                self.assertEqual(metadata["updates"], sparkle_support.update_info(config))
                self.assertEqual(metadata["sparkle"]["revision"], sparkle_support.SPARKLE_REVISION)
                (resources / "extra.txt").write_text("mounted-copy resource tampering")
                self.assertNotEqual(package_macos.bundle_metadata(bundle)["bundle_tree_sha256"], metadata["bundle_tree_sha256"])
                info["SURequireSignedFeed"] = False
                with info_path.open("wb") as target:
                    plistlib.dump(info, target)
                with self.assertRaisesRegex(ValueError, "update settings"):
                    package_macos.bundle_metadata(bundle)


if __name__ == "__main__":
    unittest.main()
