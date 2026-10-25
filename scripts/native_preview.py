#!/usr/bin/env python3
"""Render our own native content view in real, newly generated Git states."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--appearance", choices=["light", "dark"], default="light")
    parser.add_argument("--width", type=int, default=1440)
    parser.add_argument("--height", type=int, default=960)
    parser.add_argument("--scene", choices=["partial", "review", "staged", "clean", "waiting"], default="partial")
    parser.add_argument("--inspector", choices=["auto", "show", "hide"], default="auto")
    parser.add_argument("--history", choices=["expanded", "collapsed"], default="expanded")
    parser.add_argument("--renderer", type=Path, help="use an already built native renderer")
    parser.add_argument("--stashes", action="store_true", help="create two real synthetic Git stashes")
    parser.add_argument("--stash-detail", action="store_true", help="render the first stash's files and diff")
    parser.add_argument("--branches", action="store_true", help="render real local/remote branch browser")
    parser.add_argument("--original", action="store_true", help="render the original project folder")
    parser.add_argument("--verify-switch-cache", action="store_true", help="verify live per-folder restoration and external-change refresh")
    parser.add_argument("--verify-preparation-readiness", action="store_true", help="verify unfinished task is read-only and original/Ready sibling remain editable")
    parser.add_argument("--verify-review-continuity", action="store_true", help="verify mounted diff scrolling, reading checkpoint, external edits and selected-hunk handoff")
    parser.add_argument("--verify-task-context", action="store_true", help="verify saved purpose, observed/reported evidence, stale context and multi-repo handoff")
    parser.add_argument("--verify-file-staging", action="store_true", help="verify real selected-file new-file stage/unstage without changing HEAD or working bytes")
    parser.add_argument("--file-staging-view", choices=["working", "staged"], default="working", help="final synthetic new-file side after --verify-file-staging")
    parser.add_argument("--layout", choices=["focus", "balanced", "classic", "review", "tracks"], default="focus")
    parser.add_argument("--graph", choices=["top", "bottom", "hidden"])
    parser.add_argument("--verify-layout", action="store_true", help="verify persistence and unchanged live Git review across layout changes")
    parser.add_argument("--layout-settings", action="store_true", help="render the actual layout settings content")
    parser.add_argument("--layout-settings-section", choices=["layouts", "panels", "reading"], default="layouts")
    parser.add_argument("--verify-personalization", action="store_true", help="verify same-root saved layouts, focus geometry, reading state and unchanged Git snapshots")
    parser.add_argument("--focus-pane", choices=["files", "diff", "graph", "commit", "stash", "details", "branches"])
    parser.add_argument("--code-size", type=int, choices=range(11, 21), default=13)
    parser.add_argument("--compact", action="store_true", help="use compact code rows and file-list spacing")
    parser.add_argument("--dock-scene", choices=["default", "free", "tabs", "drag-preview", "branches", "empty"], default="default")
    parser.add_argument("--verify-docking", action="store_true", help="exercise the real dock drag controller using mounted pane geometry")
    args = parser.parse_args()
    if args.verify_file_staging and args.scene in {"clean", "waiting"}:
        parser.error("--verify-file-staging requires a changed synthetic working folder")
    if args.verify_personalization and (args.layout_settings or (args.branches and args.dock_scene != "branches") or args.scene in {"clean", "waiting"} or args.stash_detail):
        parser.error("--verify-personalization requires the mounted current-changes workspace (not settings, standalone branches, clean/waiting, or stash detail)")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    binary = ROOT / "target/debug/workbench"
    renderer = args.renderer
    if renderer is None:
        bin_dir = Path(subprocess.check_output(["swift", "build", "--package-path", str(ROOT / "apps/macos"), "--show-bin-path"], text=True).strip())
        renderer = bin_dir / "workbench-native-preview"
    base = Path(tempfile.mkdtemp(prefix="workbench-preview-", dir="/tmp"))
    fixture, state = base / "fixture", base / "state"
    state.mkdir(mode=0o700)
    subprocess.run([str(binary), "fixture", str(fixture)], check=True, stdout=subprocess.DEVNULL)
    (fixture / ".native-preview-fixture").write_text(str(fixture.resolve()))
    configuration = fixture / "workspace.json"
    workspace = json.loads(configuration.read_text())
    workspace["id"] = "모바일 프로젝트"
    configuration.write_text(json.dumps(workspace, ensure_ascii=False, indent=2))
    samples = {"Sources/Session.swift": "struct Session {\n    var isAuthenticated = false\n}\n",
               "Views/LoginView.swift": "struct LoginView {\n    let title = \"Sign in\"\n}\n",
               "Tests/SessionTests.swift": "// Synthetic test fixture\nlet expectedTitle = \"Sign in\"\n",
               "README.md": "# Synthetic login project\n\nLogin screen development.\n"}
    if args.verify_review_continuity or args.verify_personalization:
        # Tracked context separates the first logical change from the long tail,
        # so the probe can prove handoff/filtering preserve hunk identity.
        samples["Sources/Session.swift"] += "".join(f"// Baseline context {i}\n" for i in range(40))
    for repo_name in ["ios-app", "api"]:
        repo = fixture / f"{repo_name} 합성 repo"
        for name, content in samples.items():
            destination = repo / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(content)
        subprocess.run(["git", "-C", str(repo), "add", "--", *samples], check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "Add login screen and session model"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["git", "-C", str(repo), "branch", "-f", "release/2.4", "HEAD"], check=True)
        if args.branches:
            for name, revision in [("feature/password-reset", "HEAD~1"), ("feature/session-expiry", "HEAD")]:
                subprocess.run(["git", "-C", str(repo), "branch", name, revision], check=True)
            for name, revision in [("refs/remotes/origin/main", "HEAD"), ("refs/remotes/origin/release/2.4", "HEAD~1")]:
                subprocess.run(["git", "-C", str(repo), "update-ref", name, revision], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "remote.origin.url", "https://example.invalid/synthetic.git"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], check=True)
            subprocess.run(["git", "-C", str(repo), "branch", "--set-upstream-to=origin/main", "main"], check=True, stdout=subprocess.DEVNULL)
    for recipe in ["api.set-version@1", "ios-app.set-version@1"]:
        subprocess.run([str(binary), "trust", str(fixture / "workspace.json"), recipe], check=True, stdout=subprocess.DEVNULL)
    if args.scene == "partial":
        (fixture / "api.fail").write_text("synthetic partial failure")
    socket = state / "service.sock"
    service = subprocess.Popen([str(binary), "serve", str(fixture / "workspace.json"), str(state / "journal.sqlite"), str(socket)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def rpc(method, **params):
        data = json.loads(subprocess.check_output([str(binary), "rpc", str(socket)], input=json.dumps({"method": method, "params": params}), text=True))
        assert "error" not in data, data
        return data["result"]
    try:
        until = time.monotonic() + 10
        while not socket.exists():
            assert service.poll() is None and time.monotonic() < until
            time.sleep(.03)
        plan = rpc("plan_task", group_id="ios-2-4", label="로그인 화면 개선", task_slug="login", mode="branch_only" if args.scene == "waiting" else "materialize")
        op = rpc("execute_plan", plan_id=plan["id"], idempotency_key="native-preview-login")
        until = time.monotonic() + 20
        while op["status"] in {"queued", "running"}:
            assert time.monotonic() < until
            time.sleep(.03)
            op = rpc("get_operation", op_id=op["id"])
        expected = "partial_failure" if args.scene == "partial" else ("waiting_for_worktree" if args.scene == "waiting" else "ready")
        assert op["status"] == expected, op
        files = []
        if args.scene != "waiting":
            selected = Path(next(r["plan"]["worktree_path"] for r in op["repos"] if r["plan"]["repo_id"] == "ios-app"))
            if args.stashes or args.stash_detail:
                version = (selected / "Config/Version.xcconfig").read_bytes()
                for name, message in [("Sources/Session.swift", "로그인 세션 처리 보류"), ("Views/LoginView.swift", "로그인 화면 초안 보류")]:
                    (selected / name).write_text(samples[name] + "// Saved login draft\n")
                    subprocess.run(["git", "-C", str(selected), "stash", "push", "-m", message], check=True, stdout=subprocess.DEVNULL)
                (selected / "Config/Version.xcconfig").write_bytes(version)
            for name, content in samples.items():
                (selected / name).write_text(content.replace("false", "true").replace("Sign in", "Continue") + "// Review fixture change\n")
            if args.verify_review_continuity or args.verify_personalization:
                long_file = selected / "Sources/Session.swift"
                long_file.write_text(long_file.read_text() + "".join(f"// Synthetic review line {i}\n" for i in range(160)))
            (selected / "Notes").mkdir()
            (selected / "Notes/review.md").write_text("Synthetic review checklist\n")
            if args.scene == "staged":
                subprocess.run(["git", "-C", str(selected), "add", "Config/Version.xcconfig"], check=True)
            elif args.scene == "clean":
                subprocess.run(["git", "-C", str(selected), "add", "--all"], check=True)
                subprocess.run(["git", "-C", str(selected), "commit", "-m", "Complete reviewed login changes"], check=True, stdout=subprocess.DEVNULL)
            files = rpc("get_repo_status", repo_id="ios-app", op_id=op["id"])["files"]
            assert len(files) == (0 if args.scene == "clean" else 6), files
            assert sum(f["index"] not in [" ", "?"] for f in files) == (1 if args.scene == "staged" else 0), files
        environment = dict(os.environ)
        environment.pop("WORKBENCH_PREVIEW_STAGED", None)
        environment.pop("WORKBENCH_PREVIEW_INSPECTOR", None)
        environment["WORKBENCH_PREVIEW_HISTORY"] = "0" if args.history == "collapsed" else "1"
        environment["WORKBENCH_PREVIEW_REPO"] = "ios-app"
        environment["WORKBENCH_PREVIEW_STASH"] = "1" if args.stash_detail else "0"
        environment["WORKBENCH_PREVIEW_BRANCHES"] = "1" if args.branches and args.dock_scene != "branches" else "0"
        environment["WORKBENCH_PREVIEW_ORIGINAL"] = "1" if args.original else "0"
        environment["WORKBENCH_PREVIEW_VERIFY_SWITCH"] = "1" if args.verify_switch_cache else "0"
        environment["WORKBENCH_PREVIEW_FIXTURE_ROOT"] = str(fixture.resolve())
        environment["WORKBENCH_PREVIEW_VERIFY_READINESS"] = "1" if args.verify_preparation_readiness else "0"
        environment["WORKBENCH_PREVIEW_VERIFY_REVIEW"] = "1" if args.verify_review_continuity else "0"
        environment["WORKBENCH_PREVIEW_VERIFY_CONTEXT"] = "1" if args.verify_task_context else "0"
        environment["WORKBENCH_PREVIEW_VERIFY_FILE_STAGING"] = "1" if args.verify_file_staging else "0"
        environment["WORKBENCH_PREVIEW_FILE_STAGING_VIEW"] = args.file_staging_view
        environment["WORKBENCH_PREVIEW_LAYOUT"] = args.layout
        environment["WORKBENCH_PREVIEW_GRAPH"] = args.graph or ""
        environment["WORKBENCH_PREVIEW_VERIFY_LAYOUT"] = "1" if args.verify_layout else "0"
        environment["WORKBENCH_PREVIEW_LAYOUT_SETTINGS"] = "1" if args.layout_settings else "0"
        environment["WORKBENCH_PREVIEW_LAYOUT_SETTINGS_SECTION"] = args.layout_settings_section
        environment["WORKBENCH_PREVIEW_VERIFY_PERSONALIZATION"] = "1" if args.verify_personalization else "0"
        environment["WORKBENCH_PREVIEW_PERSONALIZATION_REPORT"] = str(args.output.resolve().with_suffix(".personalization.json"))
        environment["WORKBENCH_PREVIEW_FOCUS_PANE"] = args.focus_pane or ""
        environment["WORKBENCH_PREVIEW_CODE_SIZE"] = str(args.code_size)
        environment["WORKBENCH_PREVIEW_COMPACT"] = "1" if args.compact else "0"
        environment["WORKBENCH_PREVIEW_DOCK_SCENE"] = args.dock_scene
        environment["WORKBENCH_PREVIEW_VERIFY_DOCKING"] = "1" if args.verify_docking else "0"
        if args.scene == "staged":
            environment["WORKBENCH_PREVIEW_STAGED"] = "1"
        if args.inspector != "auto":
            environment["WORKBENCH_PREVIEW_INSPECTOR"] = "1" if args.inspector == "show" else "0"
        subprocess.run([str(renderer), str(socket), str(args.output.resolve()), args.appearance, str(args.width), str(args.height)], check=True, timeout=60 if args.verify_personalization else 30, env=environment)
        if args.scene != "waiting":
            files = rpc("get_repo_status", repo_id="ios-app", op_id=op["id"])["files"]
        stashes = rpc("list_stashes", repo_id="ios-app")
        report = {"image": str(args.output.resolve()), "fixture": str(fixture), "scene": args.scene, "file_count": len(files), "staged_count": sum(f["index"] not in [" ", "?"] for f in files), "stash_count": len(stashes), "stash_detail": args.stash_detail, "status": op["status"], "repos": [{"id": r["plan"]["repo_id"], "state": r["state"], "attempts": r["attempts"]} for r in op["repos"]]}
        report.update(original_folder=args.original, switch_cache_verified=args.verify_switch_cache, branch_browser=args.branches and args.dock_scene != "branches", review_continuity_verified=args.verify_review_continuity)
        report.update(layout=args.layout, graph_override=args.graph, layout_verified=args.verify_layout, layout_settings=args.layout_settings)
        report.update(dock_scene=args.dock_scene, docking_verified=args.verify_docking)
        report.update(preparation_readiness_verified=args.verify_preparation_readiness)
        report.update(task_context_verified=args.verify_task_context)
        report.update(file_staging_verified=args.verify_file_staging, file_staging_view=args.file_staging_view if args.verify_file_staging else None)
        report.update(focus_pane=args.focus_pane, code_size=args.code_size, compact=args.compact,
                      layout_settings_section=args.layout_settings_section,
                      personalization_verified=args.verify_personalization)
        report["renderer_provenance"] = {"path": str(renderer.resolve()), "sha256": hashlib.sha256(renderer.read_bytes()).hexdigest(),
                                         "source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                                         "source_tracked_changes": subprocess.check_output(["git", "diff", "HEAD", "--name-only"], cwd=ROOT, text=True).splitlines(),
                                         "source_untracked_build_inputs": subprocess.check_output(["git", "ls-files", "--others", "--", "apps/macos/Sources", "crates", ".cargo"], cwd=ROOT, text=True).splitlines(),
                                         "scope": "Renderer hash and current source metadata; this does not attest which sources built an externally supplied --renderer."}
        forwarded_keys = ["WORKBENCH_PREVIEW_VERIFY_PERSONALIZATION", "WORKBENCH_PREVIEW_FOCUS_PANE", "WORKBENCH_PREVIEW_CODE_SIZE",
                          "WORKBENCH_PREVIEW_COMPACT", "WORKBENCH_PREVIEW_LAYOUT_SETTINGS_SECTION", "WORKBENCH_PREVIEW_PERSONALIZATION_REPORT"]
        report["personalization_environment"] = {key: environment[key] for key in forwarded_keys}
        if args.verify_personalization:
            report["personalization_verification"] = json.loads(args.output.with_suffix(".personalization.json").read_text())
        if args.branches:
            branches = rpc("list_branches", repo_id="ios-app", op_id=op["id"])
            report.update(local_branch_count=sum(not b["is_remote"] for b in branches), remote_branch_count=sum(b["is_remote"] for b in branches))
        args.output.with_suffix(".json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(json.dumps(report, ensure_ascii=False, indent=2))
    finally:
        service.terminate()
        service.wait(timeout=5)


if __name__ == "__main__":
    main()
