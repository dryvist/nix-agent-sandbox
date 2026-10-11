import datetime as dt
import contextlib
import fcntl
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
module_spec = importlib.util.spec_from_file_location("ci_resolver", Path(__file__).resolve().parents[1] / "scripts" / "ci-resolver.py")
assert module_spec is not None and module_spec.loader is not None
resolver_module = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(resolver_module)


NOW = 1_797_000_000
SHA = "a" * 40
REPO = "owner/project"
APP_ID = "12345"


def iso(timestamp=NOW):
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).isoformat().replace("+00:00", "Z")


def workbook_md(data, body=""):
    return "---\ntype: LLM Prompt Fragment\nci_workbook: '%s'\n---\n\n%s\n" % (json.dumps(data).replace("'", "''"), body)


def entry(kind, pattern="failure", **extra):
    value = {"id": kind, "class": kind, "match": {"log": pattern}}
    value.update(extra)
    return value


class FakeGitHub:
    """Path keyed GitHub fake; all writes are recorded and no request hits the network."""

    def __init__(self):
        self.calls = []
        self.repo_data = {REPO: {"full_name": REPO, "default_branch": "main", "private": False, "archived": False, "allow_squash_merge": True, "allow_merge_commit": True}}
        self.runs = {REPO: []}
        self.runs_by_status = {}
        self.jobs = {}
        self.heads = {}
        self.prs = {REPO: []}
        self.pr_details = {}
        self.pull_commits = {REPO: []}
        self.pull_queries = {REPO: []}
        self.checks = {}
        self.workflows_missing = set()
        self.compare_commits = {}
        self.commit_messages = {}
        self.run_annotations = {}
        self.queued = {}
        self.in_progress = {}
        self.not_modified = False
        self.redirect_log = ""
        self.next_check_id = 100
        self.page_calls = []

    def pages(self, path, field):
        self.page_calls.append(path)
        if path.startswith("/installation/repositories") or path.startswith("/orgs/"):
            return list(self.repo_data.values())
        if "/actions/runs?status=in_progress" in path:
            repo = path.split("/repos/", 1)[1].split("/actions/runs", 1)[0]
            return self.in_progress.get(repo, [])
        if "/actions/runs?status=queued" in path:
            repo = path.split("/repos/", 1)[1].split("/actions/runs", 1)[0]
            return self.queued.get(repo, [])
        if "/actions/runs?status=" in path:
            repo = path.split("/repos/", 1)[1].split("/actions/runs", 1)[0]
            status = resolver_module.urllib.parse.parse_qs(path.split("?", 1)[1]).get("status", [""])[0]
            return self.runs_by_status.get(status, self.runs.get(repo, []) if status == "failure" else [])[:30]
        if "/pulls?state=open" in path:
            repo = path.split("/repos/", 1)[1].split("/pulls", 1)[0]
            return self.prs.get(repo, [])
        if "/pulls/" in path and "/commits?" in path:
            repo = path.split("/repos/", 1)[1].split("/pulls/", 1)[0]
            return self.pull_commits.get(repo, [])
        if "/commits/" in path and "/check-runs" in path:
            repo = path.split("/repos/", 1)[1].split("/commits/", 1)[0]
            sha = path.split("/commits/", 1)[1].split("/check-runs", 1)[0]
            checks = self.checks.get((repo, sha), [])
            if "check_name=ci-resolver" in path:
                checks = [item for item in checks if item.get("name") == "ci-resolver"]
            app_id = resolver_module.urllib.parse.parse_qs(path.split("?", 1)[1]).get("app_id")
            if app_id:
                checks = [item for item in checks if str((item.get("app") or {}).get("id", "")) == app_id[0]]
            return checks
        return []

    def json(self, method, path, body=None, headers=None, repo=None):
        body = body or {}
        headers = headers or {}
        self.calls.append((method, path, body, dict(headers)))
        if method == "GET" and path.startswith("/repos/") and "/actions/runs?status=" in path:
            repo = path.split("/repos/", 1)[1].split("/actions/runs", 1)[0]
            run_status = resolver_module.urllib.parse.parse_qs(path.split("?", 1)[1]).get("status", [""])[0]
            if self.not_modified and headers.get("If-None-Match"):
                return 304, {}, {"ETag": '"runs"'}
            runs = self.runs_by_status.get(run_status, self.runs.get(repo, []) if run_status == "failure" else [])
            return 200, {"workflow_runs": runs[:30]}, {"ETag": '"runs"'}
        if method == "GET" and path.startswith("/repos/") and "/actions/runs/" in path and "/jobs" in path:
            run_id = int(path.split("/actions/runs/", 1)[1].split("/", 1)[0])
            return 200, {"jobs": self.jobs.get(run_id, [])}, {}
        if method == "GET" and path.startswith("/repos/") and "/branches/" in path:
            suffix = path.split("/branches/", 1)[1]
            branch = resolver_module.urllib.parse.unquote(suffix)
            if branch not in self.heads:
                raise resolver_module.APIError(404)
            return 200, {"name": branch, "commit": {"sha": self.heads[branch]}}, {}
        if method == "GET" and path.startswith("/repos/") and "/pulls?head=" in path:
            repo = path.split("/repos/", 1)[1].split("/pulls", 1)[0]
            return 200, self.pull_queries.get(repo, []), {}
        if method == "GET" and path.startswith("/repos/") and "/actions/workflows/" in path:
            workflow_id = path.rsplit("/", 1)[-1]
            if workflow_id in self.workflows_missing:
                raise resolver_module.APIError(404)
            return 200, {"id": workflow_id}, {}
        if method == "GET" and path.startswith("/repos/") and "/check-runs/" in path and path.endswith("/annotations"):
            return 200, [], {}
        if method == "GET" and path.startswith("/repos/") and "/pulls/" in path and path.rsplit("/", 1)[-1].isdigit():
            repo = path.split("/repos/", 1)[1].split("/pulls/", 1)[0]
            number = int(path.rsplit("/", 1)[-1])
            pr = self.pr_details.get((repo, number))
            if pr is None:
                pr = next((item for item in self.prs.get(repo, []) if item.get("number") == number), {})
            return 200, pr, {}
        if method == "GET" and path.startswith("/repos/") and "/commits/" in path and "/check-runs" in path:
            repo = path.split("/repos/", 1)[1].split("/commits/", 1)[0]
            sha = path.split("/commits/", 1)[1].split("/check-runs", 1)[0]
            checks = self.checks.get((repo, sha), [])
            if "check_name=ci-resolver" in path:
                checks = [item for item in checks if item.get("name") == "ci-resolver"]
            app_id = resolver_module.urllib.parse.parse_qs(path.split("?", 1)[1]).get("app_id")
            if app_id:
                checks = [item for item in checks if str((item.get("app") or {}).get("id", "")) == app_id[0]]
            return 200, {"check_runs": checks}, {}
        if method == "GET" and path.startswith("/repos/") and "/compare/" in path:
            repo = path.split("/repos/", 1)[1].split("/compare/", 1)[0]
            return 200, {"commits": self.compare_commits.get(repo, [])}, {}
        if method == "GET" and path.startswith("/repos/") and "/commits/" in path:
            repo = path.split("/repos/", 1)[1].split("/commits/", 1)[0]
            sha = path.rsplit("/", 1)[-1]
            return 200, {"commit": {"message": self.commit_messages.get((repo, sha), "")}}, {}
        if method == "GET" and path.startswith("/repos/") and "/pulls?state=open" in path:
            repo = path.split("/repos/", 1)[1].split("/pulls", 1)[0]
            return 200, self.prs.get(repo, []), {}
        if method == "GET" and path.startswith("/repos/"):
            repo = path.split("/repos/", 1)[1].split("?", 1)[0]
            if repo in self.repo_data:
                return 200, self.repo_data[repo], {}
        if method == "POST" and path.endswith("/check-runs"):
            repo = path.split("/repos/", 1)[1].split("/check-runs", 1)[0]
            self.next_check_id += 1
            item = {"id": self.next_check_id, "name": body["name"], "head_sha": body["head_sha"], "status": body["status"], "created_at": iso(), "started_at": iso(), "output": body["output"], "app": {"id": int(APP_ID)}}
            self.checks.setdefault((repo, body["head_sha"]), []).append(item)
            return 201, item, {}
        if method == "PATCH" and "/check-runs/" in path:
            repo = path.split("/repos/", 1)[1].split("/check-runs/", 1)[0]
            check_id = int(path.rsplit("/", 1)[1])
            for items in self.checks.values():
                for item in items:
                    if item["id"] == check_id:
                        item.update(body)
                        return 200, item, {}
            return 200, body, {}
        if method == "POST" and "/rerun-failed-jobs" in path:
            return 201, {}, {}
        if method == "PUT" and "/pulls/" in path and path.endswith("/merge"):
            return 200, {"merged": True}, {}
        return 200, {}, {}

    def logs(self, repo, job_id):
        return self.redirect_log

    def calls_to(self, method, suffix):
        return [call for call in self.calls if call[0] == method and call[1].endswith(suffix)]


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name) / "state"
        self.gh = FakeGitHub()
        self.env = {"CI_RESOLVER_STATE_DIR": str(self.state), "CI_RESOLVER_MAX_ATTEMPTS": "3", "CI_RESOLVER_APP_ID": APP_ID}
        self.dispatched = []
        self.dispatch_reply = (0, {"job": "j-0123456789abcdef", "state": "running"})
        self.status_reply = (0, {"state": "running"})
        self.resolver = resolver_module.Resolver(self.gh, env=self.env, dispatcher=self.dispatcher, now=lambda: NOW)

    def tearDown(self):
        self.tmp.cleanup()

    def dispatcher(self, args):
        self.dispatched.append(args)
        if args[0] == "status":
            return self.status_reply
        return self.dispatch_reply

    def run_row(self, **extra):
        row = {"id": 1, "run_number": 1, "name": "CI", "head_sha": SHA, "head_branch": "main", "created_at": iso(), "run_attempt": 1, "workflow_id": 7, "html_url": "run-url"}
        row.update(extra)
        return row

    def failed_job(self, **extra):
        row = {"id": 9, "name": "Build", "status": "completed", "conclusion": "failure", "runner_name": "hosted", "labels": ["ubuntu-latest"], "steps": [{"name": "Compile", "conclusion": "failure"}], "annotations": [{"annotation_level": "failure", "message": "compiler failure"}]}
        row.update(extra)
        return row

    def group(self, run=None, jobs=None, repo=REPO, branch=None, prs=None):
        run = run or self.run_row()
        return {"repo": repo, "sha": run["head_sha"], "branch": branch or run["head_branch"], "runs": [run], "run": run, "jobs": jobs if jobs is not None else [self.failed_job()], "annotations": [], "prs": prs or []}

    def make_check(self, status="in_progress", external_id=None, meta=None, age=0, conclusion=None, sha=SHA, repo=REPO):
        started = iso(NOW - age)
        item = {"id": 44, "name": "ci-resolver", "head_sha": sha, "status": status, "created_at": started, "started_at": started, "external_id": external_id, "output": {"summary": self.resolver.summary("existing", meta or {})}, "app": {"id": int(APP_ID)}}
        if conclusion:
            item["conclusion"] = conclusion
        self.gh.checks.setdefault((repo, sha), []).append(item)
        return item

    def test_normalizer_stabilizes_paths_shas_timestamps_and_detects_new_errors(self):
        left = "2026-02-03T01:02:03Z \033[31mFAILED\033[0m /home/runner/work/a/b/tmp-123 0123456789abcdef HTTP 503"
        right = "2025-09-01 10:11:12 FAILED /home/runner/work/x/y/tmp-999 ffffffffffffffff HTTP 503"
        self.assertEqual(resolver_module.signature(left)[1], resolver_module.signature(right)[1])
        self.assertNotEqual(resolver_module.signature(left)[1], resolver_module.signature("HTTP 404 not found")[1])

    def test_timestamped_failed_step_log_keeps_only_the_failing_step(self):
        log = "\n".join([
            "2026-10-10T12:00:00.000Z ##[group]Set up job",
            "2026-10-10T12:00:01.000Z Downloaded setup tools",
            "2026-10-10T12:00:02.000Z ##[group]Run npm test",
            "2026-10-10T12:00:03.000Z running test suite",
            "2026-10-10T12:00:04.000Z ##[error]test assertion failed",
        ])
        kept = resolver_module.extract_failed_step(log)
        self.assertIn("##[group]Run npm test", kept)
        self.assertIn("##[error]test assertion failed", kept)
        self.assertNotIn("Set up job", kept)
        self.assertNotIn("Downloaded setup tools", kept)

    def test_prompt_strips_ansi_and_controls_and_caps_decoded_headline_bytes(self):
        group = self.group(jobs=[self.failed_job(name="Build", ci_log_text="\x1b[31mcompiler\x00 failed\x1b[0m")])
        group["jobs"][0]["name"] = "é" * 100
        prompt = self.resolver.build_prompt(group, {"signature": "0123456789ab", "signature_text": "failure", "entry": {}}, "t2", 1)
        decoded = resolver_module.urllib.parse.unquote(prompt.split("headline=", 1)[1].split()[0])
        self.assertLessEqual(len(decoded.encode("utf-8")), 100)
        self.assertIn("compiler failed", prompt)
        self.assertNotIn("\x1b", prompt)
        self.assertNotIn("\x00", prompt)
        self.assertFalse(any(ord(char) < 32 and char not in "\t\n" for char in prompt))

    def test_workbook_regex_uses_normalized_text(self):
        entry_data = entry("deterministic", r"compiler failed commit SHA", fix={"command": "make check"})
        result = resolver_module.classify_data({"conclusion": "failure"}, [self.failed_job(ci_log_text="Compiler failed commit 0123456789abcdef")], [], [entry_data], REPO)
        self.assertEqual(result["class"], "deterministic")

    def test_invalid_workbook_entry_is_skipped_and_prompt_stays_bounded(self):
        workbook = Path(self.tmp.name) / "workbook"
        workbook.mkdir()
        (workbook / "bad.md").write_text(workbook_md({"id": "bad", "class": "transient", "match": {"log": "["}}))
        self.assertEqual(resolver_module.load_workbook(workbook), [])
        job = self.failed_job(ci_log_text="x" * 12000, name="j" * 1000, steps=[{"name": "s" * 1000, "conclusion": "failure"}])
        group = self.group(jobs=[job], branch="b" * 1000)
        group["run"]["name"] = "w" * 1000
        classification = {"signature": "0123456789ab", "signature_text": "x", "entry": {"class": "recipe", "recipe": "r" * 2000, "reproduce": "p" * 2000}}
        prompt = self.resolver.build_prompt(group, classification, "t2", 1, "target-branch")
        self.assertLessEqual(len(prompt.encode("utf-8")), 16384)
        self.assertIn("run the reproduce or failing command until it passes", prompt.lower())
        self.assertIn("never edit .github/workflows/", prompt.lower())

    def test_classifier_rules_first_match_wins(self):
        rows = [
            ("infra-startup", {"conclusion": "failure"}, [], [], [], False),
            ("infra-startup", {"conclusion": "startup_failure"}, [self.failed_job()], [], [], False),
            ("infra-starved", {"conclusion": "failure"}, [{"conclusion": "cancelled", "runner_name": "", "steps": []}], [], [], False),
            ("infra-billing", {"conclusion": "failure"}, [self.failed_job()], ["Spending limit exceeded"], [], False),
            ("orphaned", {"conclusion": "failure"}, [self.failed_job()], [], [], True),
            ("never_retry", {"conclusion": "failure"}, [self.failed_job(name="download_vpn")], [], [], False),
            ("secret-finding", {"conclusion": "failure"}, [self.failed_job(name="gitleaks scan")], [], [], False),
            ("transient", {"conclusion": "failure"}, [self.failed_job(ci_log_text="ECONNRESET while fetching")], [], [], False),
            ("deterministic", {"conclusion": "failure"}, [self.failed_job(ci_log_text="compiler failure")], [], [entry("deterministic", "compiler failure", fix={"command": "make"})], False),
            ("recipe", {"conclusion": "failure"}, [self.failed_job(ci_log_text="dependency mismatch")], [], [entry("recipe", "dependency mismatch", recipe="update lock")], False),
            ("novel", {"conclusion": "failure"}, [self.failed_job(ci_log_text="unknown regression")], [], [], False),
        ]
        for expected, run, jobs, annotations, entries, orphaned in rows:
            with self.subTest(expected=expected, run=run, jobs=jobs):
                result = resolver_module.classify_data(run, jobs, annotations, entries, REPO, orphaned)
                self.assertEqual(result["class"], expected)

    def test_tier_repeats_private_cap_and_human_commit_reset(self):
        result = resolver_module.classify_data({"conclusion": "failure"}, [self.failed_job()], [], [entry("deterministic", "compiler failure", fix={"command": "make"})], REPO)
        self.gh.compare_commits[REPO] = [{"commit": {"message": "first\n\nCI-Resolver-Attempt: 1\nCI-Resolver-Tier: t1\nCI-Resolver-Signature: %s" % result["signature"]}}]
        tier, _ = self.resolver.decide_tier(result, REPO, "main")
        self.assertEqual(tier, "t2")
        self.gh.repo_data[REPO]["private"] = True
        self.gh.compare_commits[REPO] = [{"commit": {"message": "fix\n\nCI-Resolver-Attempt: 2\nCI-Resolver-Tier: t2\nCI-Resolver-Signature: %s" % result["signature"]}}]
        tier, _ = self.resolver.decide_tier(result, REPO, "main")
        self.assertEqual(tier, "escalate")
        self.gh.repo_data[REPO]["private"] = False
        self.gh.compare_commits[REPO] = [
            {"commit": {"message": "old\n\nCI-Resolver-Attempt: 1\nCI-Resolver-Tier: t3\nCI-Resolver-Signature: old"}},
            {"commit": {"message": "human change"}},
            {"commit": {"message": "new\n\nCI-Resolver-Attempt: 1\nCI-Resolver-Tier: t1\nCI-Resolver-Signature: current"}},
        ]
        history = self.resolver.attempt_history(REPO, "main", "main")
        self.assertEqual((history["last_sig"], history["last_tier"], history["model_attempts"], len(history["fixes"])), ("current", "t1", 0, 1))
        self.gh.compare_commits[REPO] = [{"commit": {"message": "model\n\nCI-Resolver-Attempt: 1\nCI-Resolver-Tier: t2\nCI-Resolver-Signature: current"}}]
        self.resolver.env["CI_RESOLVER_MAX_ATTEMPTS"] = "1"
        self.assertEqual(self.resolver.decide_tier(result, REPO, "main")[0], "escalate")

    def test_default_branch_creates_resolver_branch_and_open_pr_keeps_branch(self):
        self.gh.runs[REPO] = [self.run_row()]
        self.gh.jobs[1] = [self.failed_job()]
        self.gh.heads["main"] = SHA
        self.resolver.entries = [entry("deterministic", "compiler failure", fix={"command": "make check"})]
        self.resolver.tick()
        self.assertEqual(self.dispatched[0][0:4], ["fix", "shell", REPO, "ci-resolver/1"])
        self.assertEqual(self.dispatched[0][-1].split("\n", 1)[1], "make check")
        self.assertRegex(self.dispatched[0][-1].split("\n", 1)[0], r"^CI-RESOLVER headline=\S+ attempt=1 tier=t1 signature=[0-9a-f]{12}$")

        self.gh2 = FakeGitHub()
        branch = "feature/topic"
        run = self.run_row(head_branch=branch, id=2)
        self.gh2.runs[REPO] = [run]
        self.gh2.jobs[2] = [self.failed_job()]
        self.gh2.heads[branch] = SHA
        pr = {"number": 5, "state": "open", "head": {"ref": branch, "sha": SHA, "repo": {"full_name": REPO}}}
        self.gh2.pull_queries[REPO] = [pr]
        dispatcher_calls = []
        resolver_module.Resolver(self.gh2, env={"CI_RESOLVER_STATE_DIR": str(self.state / "pr"), "CI_RESOLVER_APP_ID": APP_ID}, dispatcher=lambda args: (dispatcher_calls.append(args) or (0, {"job": "j-x"})), now=lambda: NOW).tick()
        self.assertEqual(dispatcher_calls[0][3], branch)

    def test_existing_completed_check_skips_and_stale_claim_retries(self):
        group = self.group()
        self.make_check(status="completed", conclusion="neutral")
        self.resolver.process_group(group)
        self.assertEqual(self.dispatched, [])

        self.gh.checks[(REPO, SHA)] = []
        self.make_check(age=71 * 60)
        self.resolver.process_group(group)
        self.assertEqual(self.dispatched[0][0], "fix")

    def test_etag_304_reuses_cached_failed_runs(self):
        self.gh.runs[REPO] = [self.run_row()]
        self.assertEqual(self.resolver.failed_runs(REPO), self.gh.runs[REPO])
        self.gh.not_modified = True
        self.gh.runs[REPO] = []
        self.assertEqual(self.resolver.failed_runs(REPO), [{**self.run_row()}])
        conditional = [call for call in self.gh.calls if call[0] == "GET" and "/actions/runs?status=failure" in call[1]][-1]
        self.assertEqual(conditional[3].get("If-None-Match"), '"runs"')

    def test_startup_failure_runs_are_polled_and_classified_as_infrastructure(self):
        run = self.run_row(id=88, conclusion="startup_failure")
        timed_out = self.run_row(id=89, conclusion="timed_out")
        self.gh.runs_by_status["startup_failure"] = [run]
        self.gh.runs_by_status["timed_out"] = [timed_out]
        fetched = self.resolver.failed_runs(REPO)
        self.assertIn(run, fetched)
        self.assertIn(timed_out, fetched)
        startup = next(item for item in fetched if item["id"] == 88)
        result = resolver_module.classify_data(startup, [], [], [], REPO)
        self.assertEqual(result["class"], "infra-startup")
        self.assertTrue(any("status=startup_failure" in call[1] for call in self.gh.calls))
        self.assertTrue(any("status=timed_out" in call[1] for call in self.gh.calls))

    def test_open_pull_listing_uses_one_paginated_helper_call_for_100_plus_prs(self):
        self.gh.prs[REPO] = [{"number": number, "head": {"ref": "feature/%d" % number, "repo": {"full_name": REPO}}} for number in range(101)]
        self.assertEqual(len(self.resolver.open_prs(REPO)), 101)
        pull_pages = [path for path in self.gh.page_calls if "/pulls?state=open" in path]
        self.assertEqual(len(pull_pages), 1)
        self.assertNotIn("&page=", pull_pages[0])

    def test_liveness_opens_one_ticket_after_two_bad_ticks_and_appends_recovery(self):
        run = {"id": 72, "created_at": iso(NOW - 1001)}
        self.gh.queued[REPO] = [run]
        self.gh.jobs[72] = [{"status": "queued", "runner_name": "", "labels": ["self-hosted"]}]
        reports = []
        self.resolver.zammad = lambda kind, sig, body: (reports.append((kind, body)) or True)
        group = self.group(jobs=[self.failed_job(labels=["self-hosted"])])
        self.resolver.update_liveness([group])
        self.assertEqual(reports, [])
        self.resolver.update_liveness([group])
        self.assertEqual(len(reports), 1)
        self.gh.queued[REPO] = []
        recovered = self.resolver.update_liveness([])
        self.assertEqual(len(reports), 2)
        self.assertEqual(reports[0][0], reports[1][0])
        self.assertIn("recovered", reports[1][1].lower())
        self.assertFalse(recovered["incident_open"])

    def test_t0_reruns_only_once_and_only_when_liveness_is_healthy(self):
        for attempt, age, in_progress, expected in [(1, 0, 1, True), (2, 0, 1, False), (1, 901, 0, False)]:
            with self.subTest(attempt=attempt, age=age):
                self.gh = FakeGitHub()
                self.state = Path(self.tmp.name) / ("t0-%s-%s" % (attempt, age))
                self.resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state), "CI_RESOLVER_APP_ID": APP_ID}, dispatcher=self.dispatcher, now=lambda: NOW)
                run = self.run_row(run_attempt=attempt)
                job = self.failed_job(ci_log_text="ETIMEDOUT from registry")
                group = self.group(run, [job])
                self.resolver._liveness = {"oldest_queued_age_s": age, "in_progress_jobs": in_progress}
                self.resolver.process_group(group)
                reruns = [call for call in self.gh.calls if call[0] == "POST" and "/rerun-failed-jobs" in call[1]]
                self.assertEqual(bool(reruns), expected)

    def test_failed_t0_rerun_escalates_after_run_attempt_increments(self):
        group = self.group(jobs=[self.failed_job(ci_log_text="ETIMEDOUT from registry")])
        self.resolver.process_group(group)
        original = self.gh.checks[(REPO, SHA)][0]
        self.assertEqual(original["conclusion"], "neutral")
        self.assertIn("rerun requested", original["output"]["summary"])
        group["run"]["run_attempt"] = 2
        self.resolver.process_group(group)
        checks = self.gh.checks[(REPO, SHA)]
        self.assertEqual(len(checks), 2)
        self.assertEqual(checks[-1]["conclusion"], "action_required")
        self.assertFalse(self.dispatched)
        self.assertEqual(len([call for call in self.gh.calls if call[0] == "POST" and "/rerun-failed-jobs" in call[1]]), 1)

    def test_busy_dispatch_is_left_in_progress_without_external_job(self):
        group = self.group()
        self.dispatch_reply = (75, {"state": "busy"})
        self.resolver.process_group(group)
        check = self.gh.checks[(REPO, SHA)][0]
        self.assertEqual(check["status"], "in_progress")
        self.assertIsNone(check.get("external_id"))
        self.dispatch_reply = (0, {"job": "j-retried", "state": "running"})
        self.resolver.process_group(group)
        self.assertEqual(check.get("external_id"), "j-retried")
        self.assertEqual(len(self.dispatched), 2)

    def test_dispatch_exit_one_with_job_id_is_polled_and_refusal_escalates(self):
        group = self.group()
        self.resolver.entries = [entry("deterministic", "compiler failure", fix={"command": "make"})]
        self.dispatch_reply = (1, {"job": "j-failed", "state": "failed", "reason": "exit 1"})
        self.resolver.process_group(group)
        check = self.gh.checks[(REPO, SHA)][0]
        self.assertEqual(check.get("external_id"), "j-failed")
        self.status_reply = (0, {"state": "failed", "reason": "exit 1"})
        self.resolver.process_group(group)
        self.assertEqual(check["conclusion"], "neutral")
        self.assertEqual(self.resolver.metadata(self.gh.checks[(REPO, SHA)][-1])["forced_tier"], "t2")

        self.gh = FakeGitHub()
        self.state = Path(self.tmp.name) / "refused"
        self.dispatched = []
        self.dispatch_reply = (64, {"reason": "protected branch refused"})
        self.resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state), "CI_RESOLVER_APP_ID": APP_ID}, dispatcher=self.dispatcher, now=lambda: NOW)
        self.resolver.process_group(self.group())
        refused = self.gh.checks[(REPO, SHA)][0]
        self.assertEqual(refused["conclusion"], "action_required")
        self.assertIn("protected branch refused", refused["output"]["summary"])
        self.assertIsNone(refused.get("external_id"))

    def test_tick_without_app_id_reconciles_nothing(self):
        resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state)}, dispatcher=self.dispatcher, now=lambda: NOW)
        resolver.repos = lambda: self.fail("repos listed without an App ID")
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            resolver.tick()
        self.assertEqual(output.getvalue().count("CI_RESOLVER_APP_ID is unset"), 1)
        self.assertEqual(self.gh.calls, [])

    def test_tick_keeps_processing_after_group_error(self):
        resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state), "CI_RESOLVER_APP_ID": APP_ID}, dispatcher=self.dispatcher, now=lambda: NOW)
        resolver.repos = lambda: [REPO]
        resolver.load_groups = lambda repo: [self.group()]
        resolver.update_liveness = lambda groups: {}
        resolver.process_group = lambda group: (_ for _ in ()).throw(ValueError("sensitive detail"))
        merged = []
        resolver.merge_and_learn = lambda repo: merged.append(repo)
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            resolver.tick()
        self.assertEqual(merged, [REPO])
        self.assertIn("ValueError", output.getvalue())
        self.assertNotIn("sensitive detail", output.getvalue())

    def test_tick_exits_zero_without_token_or_api_work_when_lock_is_held(self):
        self.state.mkdir(parents=True)
        lock_path = self.state / "lock"
        with lock_path.open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.dict(os.environ, {"CI_RESOLVER_STATE_DIR": str(self.state)}, clear=True):
                self.assertEqual(resolver_module.main(["tick"]), 0)

    def test_followups_no_change_guard_timeout_and_head_moved(self):
        cases = [
            ({"state": "succeeded"}, "t2"),
            ({"state": "failed", "reason": "guard: changed protected file"}, "t2"),
            ({"state": "timeout", "reason": "deadline"}, "t2"),
            ({"state": "no-change", "reason": "no diff"}, "t2"),
            ({"state": "cancelled", "reason": "cancelled"}, "t2"),
        ]
        for reply, expected in cases:
            with self.subTest(reply=reply):
                self.gh = FakeGitHub()
                self.state = Path(self.tmp.name) / str(len(reply))
                self.resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state), "CI_RESOLVER_APP_ID": APP_ID}, dispatcher=self.dispatcher, now=lambda: NOW)
                meta = {"tier": "t1", "signature": "0123456789ab", "signature_text": "failure", "classification": "novel"}
                check = self.make_check(external_id="j-1", meta=meta)
                self.status_reply = (0, reply)
                self.resolver.process_group(self.group())
                created = self.gh.checks[(REPO, SHA)]
                self.assertEqual(created[0]["conclusion"], "neutral")
                self.assertEqual(self.resolver.metadata(created[-1])["forced_tier"], expected)
        self.gh = FakeGitHub()
        self.state = Path(self.tmp.name) / "moved"
        self.resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state), "CI_RESOLVER_APP_ID": APP_ID}, dispatcher=self.dispatcher, now=lambda: NOW)
        check = self.make_check(external_id="j-moved", meta={"tier": "t1"})
        self.status_reply = (0, {"state": "failed", "reason": "head moved"})
        self.resolver.process_group(self.group())
        self.assertEqual(check["conclusion"], "neutral")
        self.assertIn("abandoned: branch moved", check["output"]["summary"])

        self.gh = FakeGitHub()
        self.state = Path(self.tmp.name) / "exit-66"
        self.resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state), "CI_RESOLVER_APP_ID": APP_ID}, dispatcher=self.dispatcher, now=lambda: NOW)
        check = self.make_check(external_id="j-moved-66", meta={"tier": "t1"})
        self.status_reply = (0, {"state": "failed", "reason": "exit 66"})
        self.resolver.process_group(self.group())
        self.assertEqual(check["conclusion"], "neutral")
        self.assertIn("abandoned: branch moved", check["output"]["summary"])
        self.assertEqual(len(self.gh.checks[(REPO, SHA)]), 1)

    def test_succeeded_job_with_commit_completes_check_successfully(self):
        meta = {"tier": "t2", "signature": "0123456789ab", "signature_text": "failure"}
        check = self.make_check(external_id="j-done", meta=meta)
        self.status_reply = (0, {"state": "succeeded", "commit": "c" * 40})
        self.resolver.process_group(self.group())
        self.assertEqual(check["conclusion"], "success")
        self.assertIn("fix pushed: " + "c" * 40, check["output"]["summary"])
        self.assertEqual(json.loads((self.state / "published.json").read_text()), {"c" * 40: "t2"})

    def test_orphaned_workflow_completes_neutral_before_workbook_matching(self):
        self.gh.workflows_missing.add("7")
        group = self.group(jobs=[self.failed_job(ci_log_text="compiler failure")])
        self.resolver.entries = [entry("deterministic", "compiler failure", fix={"command": "make"})]
        self.resolver.process_group(group)
        check = self.gh.checks[(REPO, SHA)][0]
        self.assertEqual(check["conclusion"], "neutral")
        self.assertIn("orphaned result", check["output"]["summary"])
        self.assertFalse(self.dispatched)

    def test_shadow_mode_writes_decision_but_does_not_dispatch_rerun_merge_or_escalate(self):
        self.env["CI_RESOLVER_SHADOW"] = "1"
        self.resolver = resolver_module.Resolver(self.gh, env=self.env, dispatcher=self.dispatcher, now=lambda: NOW)
        external = []
        self.resolver.vikunja = lambda *args: external.append("vikunja")
        self.resolver.zammad = lambda *args: external.append("zammad")
        self.resolver.process_group(self.group(jobs=[self.failed_job(name="gitleaks scan")]))
        check = self.gh.checks[(REPO, SHA)][0]
        self.assertEqual(check["conclusion"], "action_required")
        self.assertEqual(external, [])
        self.assertFalse(self.dispatched)
        self.assertFalse(any("/rerun-failed-jobs" in call[1] or call[1].endswith("/merge") for call in self.gh.calls))

    def prepare_merge_pr(self, commits, published):
        branch = "ci-resolver/5"
        sha = commits[-1]
        listing = {"number": 5, "title": "fix(ci): build", "state": "open", "base": {"ref": "main"}, "head": {"ref": branch, "sha": sha, "repo": {"full_name": REPO}}, "html_url": "pr-url"}
        detail = dict(listing, mergeable=True, mergeable_state="clean")
        self.gh.prs[REPO] = [listing]
        self.gh.pr_details[(REPO, 5)] = detail
        self.gh.pull_commits[REPO] = [{"sha": item} for item in commits]
        resolver_check = {"id": 1, "name": "ci-resolver", "status": "completed", "conclusion": "success", "app": {"id": int(APP_ID)}, "output": {"summary": self.resolver.summary("green", {"signature": "0123456789ab", "signature_text": "broken", "sha": SHA, "tier": "t1"})}}
        self.gh.checks[(REPO, sha)] = [resolver_check]
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / "published.json").write_text(json.dumps(published))
        self.resolver.pr_cache = {}

    def test_t3_commit_after_t1_commit_does_not_merge(self):
        t1, t3 = "b" * 40, "c" * 40
        self.prepare_merge_pr([t1, t3], {t1: "t1", t3: "t3"})
        self.resolver.merge_and_learn(REPO)
        self.assertFalse(any(call[1].endswith("/merge") for call in self.gh.calls))

    def test_foreign_t1_trailer_does_not_authorize_merge(self):
        sha = "d" * 40
        self.prepare_merge_pr([sha], {})
        self.gh.commit_messages[(REPO, sha)] = "foreign change\n\nCI-Resolver-Tier: t1"
        self.resolver.merge_and_learn(REPO)
        self.assertFalse(any(call[1].endswith("/merge") for call in self.gh.calls))

    def test_clean_t1_only_pr_merges_from_recorded_commit(self):
        sha = "e" * 40
        self.prepare_merge_pr([sha], {sha: "t1"})
        self.resolver.merge_and_learn(REPO)
        merges = [call for call in self.gh.calls if call[0] == "PUT" and call[1].endswith("/merge")]
        self.assertEqual(len(merges), 1)
        self.assertTrue((self.state / "candidates.jsonl").exists())
        self.assertTrue(any(call[1].endswith("/pulls/5") for call in self.gh.calls))

    def test_pr_to_a_non_default_base_does_not_merge(self):
        sha = "a2" * 20
        self.prepare_merge_pr([sha], {sha: "t1"})
        self.gh.pr_details[(REPO, 5)]["base"] = {"ref": "release"}
        self.resolver.merge_and_learn(REPO)
        self.assertFalse(any(call[1].endswith("/merge") for call in self.gh.calls))

    def test_wrong_app_id_halts_after_one_claim(self):
        resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state), "CI_RESOLVER_APP_ID": "999"}, dispatcher=self.dispatcher, now=lambda: NOW)
        resolver.repos = lambda: [REPO]
        resolver.load_groups = lambda repo: [self.group()]
        resolver.update_liveness = lambda groups: {}
        merged = []
        resolver.merge_and_learn = lambda repo: merged.append(repo)
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            resolver.tick()
            resolver.tick()
        claims = [call for call in self.gh.calls if call[0] == "POST" and call[1].endswith("/check-runs")]
        self.assertEqual(len(claims), 1)
        self.assertEqual(self.gh.checks[(REPO, SHA)][0]["conclusion"], "neutral")
        self.assertFalse(any(args[0] == "fix" for args in self.dispatched))
        self.assertEqual(merged, [])
        self.assertTrue((self.state / "halted").exists())
        self.assertIn("halted", output.getvalue())

    def test_failed_status_command_leaves_the_job_running(self):
        check = self.make_check(external_id="j-running", meta={"tier": "t3", "attempt": 1, "branch": "main", "sha": SHA})
        self.status_reply = (1, {})
        self.resolver.process_group(self.group())
        self.assertEqual(check["status"], "in_progress")
        self.assertEqual(len(self.gh.checks[(REPO, SHA)]), 1)

    def test_model_tier_escalates_on_a_pr_with_auto_merge(self):
        pr = {"number": 3, "auto_merge": {"merge_method": "squash"}, "head": {"ref": "feature", "repo": {"full_name": REPO}}}
        self.resolver.process_group(self.group(run=self.run_row(head_branch="feature"), prs=[pr]))
        self.assertFalse(any(args[0] == "fix" for args in self.dispatched))
        self.assertEqual(self.gh.checks[(REPO, SHA)][-1]["conclusion"], "action_required")
        self.assertIn("auto-merge", self.gh.checks[(REPO, SHA)][-1]["output"]["summary"])

    def test_failing_foreign_check_or_foreign_resolver_check_blocks_merge(self):
        sha = "a1" * 20
        self.prepare_merge_pr([sha], {sha: "t1"})
        self.gh.checks[(REPO, sha)].append({"id": 2, "name": "lint", "status": "completed", "conclusion": "failure", "app": {"id": 99}})
        self.resolver.merge_and_learn(REPO)
        self.assertFalse(any(call[1].endswith("/merge") for call in self.gh.calls))
        checks = self.gh.checks[(REPO, sha)]
        checks[:] = [dict(checks[0], app={"id": 99})]
        self.resolver.merge_and_learn(REPO)
        self.assertFalse((self.state / "candidates.jsonl").exists())

    def test_merge_requires_clean_single_pr_mergeability_and_configured_app_id(self):
        sha = "f" * 40
        self.prepare_merge_pr([sha], {sha: "t1"})
        self.gh.pr_details[(REPO, 5)]["mergeable_state"] = "blocked"
        self.resolver.merge_and_learn(REPO)
        self.assertFalse(any(call[1].endswith("/merge") for call in self.gh.calls))

        self.gh = FakeGitHub()
        self.state = Path(self.tmp.name) / "no-app-id"
        self.resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state)}, dispatcher=self.dispatcher, now=lambda: NOW)
        self.prepare_merge_pr([sha], {sha: "t1"})
        self.resolver.merge_and_learn(REPO)
        self.assertFalse(any(call[1].endswith("/merge") for call in self.gh.calls))

    def test_no_path_opens_issue_or_adds_label(self):
        self.resolver.process_group(self.group(jobs=[self.failed_job(name="gitleaks scan")]))
        writes = [call for call in self.gh.calls if call[0] in ("POST", "PATCH", "PUT")]
        self.assertFalse(any("/issues" in call[1] or "/labels" in call[1] for call in writes))

    def test_learn_deduplicates_candidates_and_writes_okf_workbook_entries(self):
        self.state.mkdir(parents=True)
        candidate = {"signature": "0123456789ab", "signature_text": "it's an error", "repo": REPO, "branch": "ci-resolver/1", "failing_sha": SHA, "green_sha": "b" * 40, "tier_or_human": "t1", "compare_url": "comparison"}
        (self.state / "candidates.jsonl").write_text(json.dumps(candidate) + "\n" + json.dumps(candidate) + "\n")
        out = Path(self.tmp.name) / "checkout"
        (out / "automation" / "ci-workbook").mkdir(parents=True)
        changed = self.resolver.learn(str(out))
        self.assertEqual(changed, [str(out / "automation" / "ci-workbook" / "learned-0123456789ab.md")])
        text = Path(changed[0]).read_text()
        for field in ("type", "title", "description", "resource", "tags", "timestamp", "status", "consumers", "render", "source_history"):
            self.assertRegex(text, r"(?m)^%s:" % field)
        entries = resolver_module.load_workbook(out / "automation" / "ci-workbook")
        self.assertEqual([(item["id"], item["class"], item["stats"]["fixed"]) for item in entries], [("learned-0123456789ab", "recipe", 1)])
        self.assertIn("comparison", entries[0]["recipe"])
        self.assertTrue(resolver_module.match_entry(entries[0], "it's an error", REPO, "job"))
        self.assertEqual(self.resolver.learn(str(out)), [])
        second = dict(candidate, green_sha="c" * 40, compare_url="comparison-2")
        with (self.state / "candidates.jsonl").open("a") as handle:
            handle.write(json.dumps(second) + "\n")
        self.resolver.learn(str(out))
        self.assertEqual(resolver_module.load_workbook(out / "automation" / "ci-workbook")[0]["stats"]["fixed"], 2)

    def test_learn_publish_opens_one_pr_and_keeps_candidates_queued_while_one_is_open(self):
        self.state.mkdir(parents=True)
        candidate = {"signature": "0123456789ab", "signature_text": "boom", "repo": REPO, "branch": "b", "failing_sha": SHA, "green_sha": "b" * 40, "tier_or_human": "t1", "compare_url": "cmp"}
        (self.state / "candidates.jsonl").write_text(json.dumps(candidate) + "\n")
        out = Path(self.tmp.name) / "prompts"
        (out / "automation" / "ci-workbook").mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(out)], check=True)
        subprocess.run(["git", "-C", str(out), "-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "base"], check=True)
        base = subprocess.run(["git", "-C", str(out), "rev-parse", "HEAD"], text=True, capture_output=True, check=True).stdout.strip()
        self.gh.prs[REPO] = [{"number": 3, "head": {"ref": "ci-resolver/workbook-202601010000", "repo": {"full_name": REPO}}}]
        self.assertEqual(self.resolver.learn(str(out), REPO), [])
        self.assertFalse((self.state / "learn.cursor").exists())
        self.gh.prs[REPO] = []
        self.resolver.pr_cache = {}
        self.assertEqual(len(self.resolver.learn(str(out), REPO)), 1)
        ref = self.gh.calls_to("POST", "/git/refs")[0][2]
        self.assertEqual(ref["sha"], base)
        commit = self.gh.calls_to("POST", "/graphql")[0][2]["variables"]["input"]
        self.assertEqual((commit["expectedHeadOid"], [item["path"] for item in commit["fileChanges"]["additions"]]), (base, ["automation/ci-workbook/learned-0123456789ab.md"]))
        self.assertRegex(commit["message"]["headline"], r"^feat\(automation\): ")
        self.assertEqual(self.gh.calls_to("POST", "/pulls")[0][2]["base"], "main")
        self.assertTrue((self.state / "learn.cursor").exists())

    def test_workbook_markdown_body_is_the_recipe_and_index_is_skipped(self):
        workbook = Path(self.tmp.name) / "wb"
        workbook.mkdir()
        (workbook / "index.md").write_text("# CI Workbook\n")
        (workbook / "lint.md").write_text(workbook_md({"id": "lint", "class": "recipe", "match": {"log": "md\\d{3}/|it's"}}, "Fix only changed files."))
        entries = resolver_module.load_workbook(workbook)
        self.assertEqual([(item["id"], item["recipe"]) for item in entries], [("lint", "Fix only changed files.")])

    def test_aggregate_jobs_are_skipped_in_favor_of_the_underlying_failure(self):
        rollup = entry("aggregate", "some of the required to succeed jobs failed")
        lint = entry("recipe", "line too long", recipe="wrap it")
        jobs = [self.failed_job(name="Merge Gate", ci_log_text="Some of the required to succeed jobs failed"), self.failed_job(ci_log_text="line too long")]
        both = resolver_module.classify_data({"conclusion": "failure"}, jobs, [], [rollup, lint], REPO)
        self.assertEqual((both["class"], both["entry"]["id"]), ("recipe", "recipe"))
        self.assertEqual(both["signature"], resolver_module.classify_data({"conclusion": "failure"}, jobs[1:], [], [lint], REPO)["signature"])
        alone = resolver_module.classify_data({"conclusion": "failure"}, jobs[:1], [], [rollup, lint], REPO)
        self.assertEqual(alone["class"], "aggregate")
        self.resolver.entries = [rollup]
        self.resolver.process_group(self.group(jobs=jobs[:1]))
        self.assertEqual(self.dispatched, [])
        self.assertEqual(self.gh.checks[(REPO, SHA)][-1]["conclusion"], "neutral")


class GitHubTokenTests(unittest.TestCase):
    def test_token_command_gets_the_path_repository_or_the_default(self):
        seen = []

        class Done:
            status, headers, body = 200, {}, b"{}"

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return self.body

        def opener(request, timeout=30):
            seen.append(request.get_header("Authorization"))
            return Done()

        client = resolver_module.GitHub("printf tok-%s", opener=opener, default_repo="owner/.github")
        client.json("GET", "/repos/owner/project/actions/runs")
        client.json("POST", "/graphql", {}, repo="owner/prompts")
        client.json("GET", "/orgs/owner/repos")
        self.assertEqual(seen, ["Bearer tok-owner/project", "Bearer tok-owner/prompts", "Bearer tok-owner/.github"])


class VikunjaTests(unittest.TestCase):
    def test_one_task_per_title_without_reading_the_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"CI_RESOLVER_STATE_DIR": tmp, "CI_RESOLVER_VIKUNJA_URL": "https://tasks.test", "CI_RESOLVER_VIKUNJA_TOKEN_CMD": "printf secret", "CI_RESOLVER_VIKUNJA_PROJECT": "44"}
            resolver = resolver_module.Resolver(FakeGitHub(), env=env, dispatcher=lambda args: (0, {}), now=lambda: NOW)
            sent = []
            with patch.object(resolver_module.Resolver, "external_json", side_effect=lambda *args: sent.append(args) or {}):
                group = {"repo": REPO, "branch": "main"}
                resolver.vikunja(group, {"entry": {"id": "markdownlint"}}, "body")
                resolver.vikunja(group, {"entry": {"id": "markdownlint"}}, "body")
            self.assertEqual([(call[0], call[1], call[2]) for call in sent], [("PUT", "https://tasks.test/api/v1/projects/44/tasks", "secret")])
            self.assertEqual(sent[0][3]["title"], "ci-resolver: owner/project markdownlint")


class RedirectTests(unittest.TestCase):
    def test_log_redirect_target_does_not_receive_authorization(self):
        seen = []

        class FakeResponse:
            def __init__(self, status, headers, body):
                self.status = status
                self.headers = headers
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return self.body

        def opener(request, timeout=30):
            seen.append(request)
            if len(seen) == 1:
                return FakeResponse(302, {"Location": "https://redirect.test/log"}, b"")
            return FakeResponse(200, {}, b"plain log")

        client = resolver_module.GitHub("unused", opener=opener)
        client._tokens["owner/project"] = ("test-token", time.time() + 3600)
        response = client.request("GET", "/repos/owner/project/actions/jobs/4/logs", follow_redirect=True)
        self.assertEqual(response.body, b"plain log")
        self.assertTrue(seen[0].get_header("Authorization"))
        self.assertIsNone(seen[1].get_header("Authorization"))


if __name__ == "__main__":
    unittest.main()
