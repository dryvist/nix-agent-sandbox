import datetime as dt
import fcntl
import importlib.util
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
resolver_module = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(resolver_module)


NOW = 1_797_000_000
SHA = "a" * 40
REPO = "owner/project"


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
        self.jobs = {}
        self.heads = {}
        self.prs = {REPO: []}
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

    def pages(self, path, field):
        if path.startswith("/installation/repositories"):
            return list(self.repo_data.values())
        if "/actions/runs?status=failure" in path:
            repo = path.split("/repos/", 1)[1].split("/actions/runs", 1)[0]
            return self.runs.get(repo, [])[:30]
        if "/actions/runs?status=queued" in path:
            repo = path.split("/repos/", 1)[1].split("/actions/runs", 1)[0]
            return self.queued.get(repo, [])
        if "/actions/runs?status=in_progress" in path:
            repo = path.split("/repos/", 1)[1].split("/actions/runs", 1)[0]
            return self.in_progress.get(repo, [])
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
            return [item for item in checks if item.get("name") == "ci-resolver"] if "check_name=ci-resolver" in path else checks
        return []

    def json(self, method, path, body=None, headers=None):
        headers = headers or {}
        self.calls.append((method, path, body, dict(headers)))
        if method == "GET" and path.startswith("/repos/") and "/actions/runs?status=failure" in path:
            repo = path.split("/repos/", 1)[1].split("/actions/runs", 1)[0]
            if self.not_modified and headers.get("If-None-Match"):
                return 304, {}, {"ETag": '"runs"'}
            return 200, {"workflow_runs": self.runs.get(repo, [])[:30]}, {"ETag": '"runs"'}
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
        if method == "GET" and path.startswith("/repos/") and "/commits/" in path and "/check-runs" in path:
            repo = path.split("/repos/", 1)[1].split("/commits/", 1)[0]
            sha = path.split("/commits/", 1)[1].split("/check-runs", 1)[0]
            checks = self.checks.get((repo, sha), [])
            if "check_name=ci-resolver" in path:
                checks = [item for item in checks if item.get("name") == "ci-resolver"]
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
            item = {"id": self.next_check_id, "name": body["name"], "head_sha": body["head_sha"], "status": body["status"], "created_at": iso(), "started_at": iso(), "output": body["output"]}
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
        self.env = {"CI_RESOLVER_STATE_DIR": str(self.state), "CI_RESOLVER_MAX_ATTEMPTS": "3"}
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
        item = {"id": 44, "name": "ci-resolver", "head_sha": sha, "status": status, "created_at": started, "started_at": started, "external_id": external_id, "output": {"summary": self.resolver.summary("existing", meta or {})}}
        if conclusion:
            item["conclusion"] = conclusion
        self.gh.checks.setdefault((repo, sha), []).append(item)
        return item

    def test_normalizer_stabilizes_paths_shas_timestamps_and_detects_new_errors(self):
        left = "2026-02-03T01:02:03Z \033[31mFAILED\033[0m /home/runner/work/a/b/tmp-123 0123456789abcdef HTTP 503"
        right = "2025-09-01 10:11:12 FAILED /home/runner/work/x/y/tmp-999 ffffffffffffffff HTTP 503"
        self.assertEqual(resolver_module.signature(left)[1], resolver_module.signature(right)[1])
        self.assertNotEqual(resolver_module.signature(left)[1], resolver_module.signature("HTTP 404 not found")[1])

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
        resolver_module.Resolver(self.gh2, env={"CI_RESOLVER_STATE_DIR": str(self.state / "pr")}, dispatcher=lambda args: (dispatcher_calls.append(args) or (0, {"job": "j-x"})), now=lambda: NOW).tick()
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
                self.resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state)}, dispatcher=self.dispatcher, now=lambda: NOW)
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
        ]
        for reply, expected in cases:
            with self.subTest(reply=reply):
                self.gh = FakeGitHub()
                self.state = Path(self.tmp.name) / str(len(reply))
                self.resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state)}, dispatcher=self.dispatcher, now=lambda: NOW)
                meta = {"tier": "t1", "signature": "0123456789ab", "signature_text": "failure", "classification": "novel"}
                check = self.make_check(external_id="j-1", meta=meta)
                self.status_reply = (0, reply)
                self.resolver.process_group(self.group())
                created = self.gh.checks[(REPO, SHA)]
                self.assertEqual(created[0]["conclusion"], "neutral")
                self.assertEqual(self.resolver.metadata(created[-1])["forced_tier"], expected)
        self.gh = FakeGitHub()
        self.state = Path(self.tmp.name) / "moved"
        self.resolver = resolver_module.Resolver(self.gh, env={"CI_RESOLVER_STATE_DIR": str(self.state)}, dispatcher=self.dispatcher, now=lambda: NOW)
        check = self.make_check(external_id="j-moved", meta={"tier": "t1"})
        self.status_reply = (0, {"state": "failed", "reason": "head moved"})
        self.resolver.process_group(self.group())
        self.assertEqual(check["conclusion"], "neutral")
        self.assertIn("abandoned: branch moved", check["output"]["summary"])

    def test_succeeded_job_with_commit_completes_check_successfully(self):
        meta = {"tier": "t2", "signature": "0123456789ab", "signature_text": "failure"}
        check = self.make_check(external_id="j-done", meta=meta)
        self.status_reply = (0, {"state": "succeeded", "commit": "c" * 40})
        self.resolver.process_group(self.group())
        self.assertEqual(check["conclusion"], "success")
        self.assertIn("fix pushed: " + "c" * 40, check["output"]["summary"])

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

    def test_merge_only_t0_or_t1_with_all_green_checks(self):
        branch = "ci-resolver/5"
        sha = "b" * 40
        pr = {"number": 5, "title": "fix(ci): build", "head": {"ref": branch, "sha": sha, "repo": {"full_name": REPO}}, "mergeable": True, "html_url": "pr-url"}
        self.gh.prs[REPO] = [pr]
        resolver_check = {"id": 1, "name": "ci-resolver", "status": "completed", "conclusion": "success", "output": {"summary": self.resolver.summary("green", {"signature": "0123456789ab", "signature_text": "broken", "sha": SHA, "tier": "t1"})}}
        other = {"id": 2, "name": "build", "status": "completed", "conclusion": "success"}
        self.gh.checks[(REPO, sha)] = [resolver_check, other]
        self.gh.commit_messages[(REPO, sha)] = "fix build\n\nCI-Resolver-Tier: t1"
        self.resolver.merge_and_learn(REPO)
        self.assertEqual(len([call for call in self.gh.calls if call[0] == "PUT" and call[1].endswith("/merge")]), 1)
        self.assertTrue((self.state / "candidates.jsonl").exists())

        self.gh.calls.clear()
        self.gh.commit_messages[(REPO, sha)] = "fix build\n\nCI-Resolver-Tier: t0"
        self.resolver.merge_and_learn(REPO)
        self.assertEqual(len([call for call in self.gh.calls if call[0] == "PUT" and call[1].endswith("/merge")]), 1)
        self.gh.calls.clear()
        self.gh.commit_messages[(REPO, sha)] = "fix build\n\nCI-Resolver-Tier: t2"
        self.resolver.merge_and_learn(REPO)
        self.assertFalse(any(call[1].endswith("/merge") for call in self.gh.calls))
        self.gh.calls.clear()
        self.gh.commit_messages[(REPO, sha)] = "fix build\n\nCI-Resolver-Tier: t3"
        self.resolver.merge_and_learn(REPO)
        self.assertFalse(any(call[1].endswith("/merge") for call in self.gh.calls))
        self.gh.checks[(REPO, sha)][1]["status"] = "in_progress"
        self.gh.commit_messages[(REPO, sha)] = "fix build\n\nCI-Resolver-Tier: t1"
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
        subprocess.run(["git", "-C", str(out), "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "base"], check=True)
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
        client._token = "test-token"
        client._token_until = time.time() + 3600
        response = client.request("GET", "/repos/owner/project/actions/jobs/4/logs", follow_redirect=True)
        self.assertEqual(response.body, b"plain log")
        self.assertTrue(seen[0].get_header("Authorization"))
        self.assertIsNone(seen[1].get_header("Authorization"))


if __name__ == "__main__":
    unittest.main()
