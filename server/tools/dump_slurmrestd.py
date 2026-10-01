#!/usr/bin/env python3
"""Record the slurmrestd payloads the Slurm Monitor server consumes.

Single file, standard library only, Python 3.6+ syntax, so that it runs with
the system Python of a cluster login node.

    SLURM_JWT=... python3 dump_slurmrestd.py --base-url https://slurm.example.org:6820

Writes jobs.json, nodes.json, partitions.json, qos.json, shares.json,
openapi.json and manifest.json to the output directory. By default every
payload is anonymised before it is written; see README.md next to this file.
"""

import argparse
import datetime
import getpass
import hashlib
import json
import os
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_RUNNER_PATTERNS = [r"^ci-\d+", r"^dask-gateway", r"^(spawner-)?jupyterhub"]
# Words that survive inside an anonymised job name or command, because the
# server uses them to tell a Dask scheduler from its workers.
DEFAULT_KEEP_WORDS = ["scheduler", "worker"]

OPENAPI_PATHS = ["/openapi/v3", "/openapi.json", "/openapi"]

# (file stem, plugin, resource)
ENDPOINTS = [
    ("jobs", "slurm", "jobs"),
    ("nodes", "slurm", "nodes"),
    ("partitions", "slurm", "partitions"),
    ("qos", "slurmdb", "qos"),
    ("shares", "slurm", "shares"),
]

USER_KEYS = {"user_name", "user", "username", "owner", "users", "allow_users",
             "deny_users", "coordinators", "reason_set_by_user"}
ACCOUNT_KEYS = {"account", "accounts", "parent", "parent_account",
                "allow_accounts", "deny_accounts", "default_account"}
GROUP_KEYS = {"group_name", "group", "groups", "allow_groups", "deny_groups"}
COMMENT_KEYS = {"comment", "admin_comment", "system_comment"}
# Free text written by administrators (the reason a node is down or drained,
# the description of a QOS): replaced as a whole, like a comment. The job
# field "state_reason" is a fixed Slurm word and is kept (see KEEP_KEYS).
TEXT_KEYS = {"reason", "description"}
# Reservation names are chosen by people and often name a person or a
# project ("pgierz_workshop"): hashed, also inside comma-separated lists.
RESERVATION_KEYS = {"reservation", "reservations", "resv_name"}
PATH_KEYS = {"current_working_directory", "cwd", "work_dir",
             "working_directory", "standard_output", "standard_error",
             "standard_input", "stdout", "stderr", "stdin", "container"}
COMMAND_KEYS = {"command", "submit_line", "script", "batch_script"}
EMAIL_KEYS = {"mail_user", "email"}
HASH_KEYS = {"wckey", "extra", "mcs_label", "selinux_context", "burst_buffer",
             "environment", "argv"}
# Strings under these keys are never touched: they are what the server
# classifies on, and none of them carries personal data.
KEEP_KEYS = {"partition", "partitions", "qos", "nodes", "node", "hostname",
             "address", "batch_host", "cluster", "gres", "gres_used",
             "gres_drain", "gres_detail", "tres", "tres_used", "tres_req_str",
             "tres_alloc_str", "tres_per_node", "tres_per_job",
             "tres_per_task", "tres_per_socket", "state", "job_state",
             "state_reason", "flags", "features", "active_features",
             "architecture", "operating_system", "version", "type",
             "scheduled_nodes", "required_nodes", "excluded_nodes",
             "licenses", "dependency", "release"}
NEVER_RENAMED = {"", "root", "nobody", "(null)", "ALL", "all"}

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
PATH_RE = re.compile(r"^(~|\.{0,2}/)")
EMBEDDED_PATH_RE = re.compile(r"(?<![\w.])~?/(?:[\w.+@-]+/)+[\w.+@-]*")
LIST_SPLIT_RE = re.compile(r"([,\s]+)")


class Anonymiser(object):
    """Replaces personal data in slurmrestd payloads with stable pseudonyms.

    Use `collect()` on every payload first, then `scrub()` on every payload:
    names found in one payload are then also removed from free text in the
    others.
    """

    def __init__(self, runner_patterns=None, keep_users=None, keep_words=None,
                 salt=None):
        patterns = DEFAULT_RUNNER_PATTERNS if runner_patterns is None else runner_patterns
        self.runner_patterns = [re.compile(p) for p in patterns]
        self.keep_users = set(keep_users or [])
        self.keep_words = list(DEFAULT_KEEP_WORDS if keep_words is None else keep_words)
        self.salt = salt if salt is not None else hashlib.sha256(os.urandom(32)).hexdigest()
        self.users = {}
        self.accounts = {}
        self.groups = {}
        self.job_names = {}
        self._user_re = None

    # -- pseudonyms -------------------------------------------------------

    def _digest(self, text, length):
        raw = (self.salt + "\0" + text).encode("utf-8")
        return hashlib.sha256(raw).hexdigest()[:length]

    def user(self, name):
        if name in NEVER_RENAMED or name in self.keep_users:
            return name
        if name not in self.users:
            self.users[name] = "user%03d" % (len(self.users) + 1)
            self._user_re = None
        return self.users[name]

    def account(self, name):
        if name in NEVER_RENAMED:
            return name
        if name not in self.accounts:
            self.accounts[name] = "acct%02d" % (len(self.accounts) + 1)
        return self.accounts[name]

    def group(self, name):
        if name in NEVER_RENAMED:
            return name
        if name not in self.groups:
            self.groups[name] = "group%02d" % (len(self.groups) + 1)
        return self.groups[name]

    def _kept_words(self, text):
        low = text.lower()
        return "".join("-" + w for w in self.keep_words if w in low)

    def job_name(self, name):
        if name == "":
            return name
        for pattern in self.runner_patterns:
            match = pattern.search(name)
            if match and match.start() == 0:
                rest = name[match.end():]
                if rest == "":
                    return name
                return match.group(0) + self._kept_words(rest) + "-" + self._digest(name, 6)
        if name not in self.job_names:
            self.job_names[name] = "job%06d" % (len(self.job_names) + 1)
        return self.job_names[name]

    def comment(self, text):
        return "c-" + self._digest(text, 10) if text else text

    def reservation(self, name):
        return "resv-" + self._digest(name, 8) if name else name

    def opaque(self, text):
        return "x-" + self._digest(text, 10) if text else text

    def path(self, text):
        return "/scrubbed/path-" + self._digest(text, 10) if text else text

    def command(self, text):
        if not text:
            return text
        return "/scrubbed/command-" + self._digest(text, 10) + self._kept_words(text)

    def email(self, text):
        def replace(match):
            local = match.group(0).split("@")[0]
            if local in self.keep_users:
                return match.group(0)
            if local in self.users:
                return self.users[local] + "@example.org"
            return "mail-" + self._digest(match.group(0), 8) + "@example.org"
        if text and not EMAIL_RE.search(text):
            # mail_user often holds a bare user name
            return self._name_list(text, self.user)
        return EMAIL_RE.sub(replace, text)

    def free_text(self, text):
        """Fallback for string fields this script has no rule for."""
        if not text:
            return text
        if PATH_RE.match(text):
            return self.path(text)
        text = EMBEDDED_PATH_RE.sub(lambda m: self.path(m.group(0)), text)
        text = self.email(text) if EMAIL_RE.search(text) else text
        if self.users:
            if self._user_re is None:
                names = sorted(self.users, key=len, reverse=True)
                self._user_re = re.compile(
                    r"(?<![A-Za-z0-9_])(%s)(?![A-Za-z0-9_])"
                    % "|".join(re.escape(n) for n in names))
            text = self._user_re.sub(lambda m: self.users[m.group(1)], text)
        return text

    @staticmethod
    def _name_list(text, rename):
        parts = LIST_SPLIT_RE.split(text)
        return "".join(p if i % 2 else rename(p) for i, p in enumerate(parts))

    # -- walking ----------------------------------------------------------

    def collect(self, payload):
        """First pass: learn user, account and group names. Returns nothing."""
        self._walk(payload, (), None, True)

    def scrub(self, payload):
        """Second pass: return an anonymised deep copy of the payload."""
        return self._walk(payload, (), None, False)

    def _walk(self, value, path, parent, collecting):
        if isinstance(value, dict):
            return dict((k, self._walk(v, path + (k,), value, collecting))
                        for k, v in value.items())
        if isinstance(value, list):
            return [self._walk(v, path, parent, collecting) for v in value]
        if isinstance(value, str):
            return self._string(value, path, parent, collecting)
        return value

    def _string(self, text, path, parent, collecting):
        key = path[-1].lower() if path else ""
        keys = set(k.lower() for k in path)
        if keys & COMMENT_KEYS:
            return self.comment(text)
        if key in TEXT_KEYS:
            return self.comment(text)
        if key in RESERVATION_KEYS:
            return self._name_list(text, self.reservation)
        if key == "name":
            return self._name(text, parent, collecting)
        if key in ACCOUNT_KEYS or "accounts" in keys:
            return self._name_list(text, self.account)
        if key in GROUP_KEYS or "groups" in keys:
            return self._name_list(text, self.group)
        if key in USER_KEYS:
            return self._name_list(text, self.user)
        if collecting:
            return text  # everything below only matters in the second pass
        if key == "source" and "meta" in keys:
            return "scrubbed"
        if key in EMAIL_KEYS:
            return self.email(text)
        if key in PATH_KEYS:
            return self.path(text)
        if key in COMMAND_KEYS:
            return self.command(text)
        if key in HASH_KEYS:
            return self.opaque(text)
        if key in KEEP_KEYS:
            return text
        return self.free_text(text)

    def _name(self, text, parent, collecting):
        parent = parent or {}
        if "job_id" in parent:
            return text if collecting else self.job_name(text)
        if "parent" in parent:  # a row of the shares payload
            kinds = parent.get("type")
            kinds = kinds if isinstance(kinds, list) else [kinds]
            if any(str(k).upper() == "USER" for k in kinds):
                return self.user(text)
            return self.account(text)
        return text  # node, partition, QOS, TRES names

    # -- checking ---------------------------------------------------------

    def residue(self, payload):
        """Return (key path, original name) pairs for names that still occur.

        A plain search, ignoring case, for every original user, account and
        group name longer than two characters, anywhere inside any string:
        "pgierz" is found in "pgierz_workshop" and in "/home/PGierz". A hit
        is not always a leak: an account called like a partition will be
        reported because the partition name is kept on purpose, and a short
        name may occur inside an unrelated word.
        """
        names = set(self.users) | set(self.accounts) | set(self.groups)
        names = sorted(set(n.lower() for n in names if len(n) > 2))
        hits = []
        # One pass with a combined expression tells whether a string holds
        # any name at all; only then is every name looked for by itself.
        any_name = re.compile("|".join(re.escape(n) for n in names)) if names else None

        def visit(value, path):
            if isinstance(value, dict):
                for k, v in value.items():
                    visit(v, path + (k,))
            elif isinstance(value, list):
                for v in value:
                    visit(v, path)
            elif isinstance(value, str):
                found = set()
                low = value.lower()
                if any_name is not None and any_name.search(low):
                    found.update(n for n in names if n in low)
                for mail in EMAIL_RE.findall(value):
                    if not mail.endswith("@example.org") and \
                            mail.split("@")[0] not in self.keep_users:
                        found.add("<e-mail address>")
                for name in found:
                    hits.append((".".join(path), name))

        visit(payload, ())
        return sorted(set(hits))


# -- slurmrestd access ----------------------------------------------------

def obtain_token(environ=None, run=None):
    """Token from SLURM_JWT, else from `scontrol token`."""
    environ = os.environ if environ is None else environ
    token = environ.get("SLURM_JWT", "").strip()
    if token:
        return token
    run = run or _run_scontrol
    output = run()
    match = re.search(r"SLURM_JWT=(\S+)", output)
    if not match:
        raise RuntimeError("`scontrol token` did not print SLURM_JWT=...")
    return match.group(1)


def _run_scontrol():
    try:
        proc = subprocess.Popen(["scontrol", "token"], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, universal_newlines=True)
    except OSError as exc:
        raise RuntimeError("SLURM_JWT is not set and scontrol cannot be run: %s" % exc)
    out, err = proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError("`scontrol token` failed: %s" % err.strip())
    return out


def version_key(version):
    return tuple(int(n) for n in re.findall(r"\d+", version))


def detect_versions(openapi):
    """Newest data-parser version per plugin: {"slurm": "v0.0.41", "slurmdb": ...}."""
    found = {}
    for path in (openapi or {}).get("paths", {}):
        match = re.match(r"^/(slurm|slurmdb)/(v\d+(?:\.\d+)+)/", path)
        if match:
            plugin, version = match.groups()
            if plugin not in found or version_key(version) > version_key(found[plugin]):
                found[plugin] = version
    return found


class Client(object):
    def __init__(self, base_url, user, token, timeout=60, ca_file=None):
        self.base_url = base_url.rstrip("/")
        self.headers = {"X-SLURM-USER-NAME": user, "X-SLURM-USER-TOKEN": token,
                        "Accept": "application/json"}
        self.timeout = timeout
        self.context = None
        if self.base_url.startswith("https"):
            self.context = ssl.create_default_context(cafile=ca_file)

    def get(self, path):
        request = urllib.request.Request(self.base_url + path, headers=self.headers)
        response = urllib.request.urlopen(request, timeout=self.timeout,
                                          context=self.context)
        try:
            return json.loads(response.read().decode("utf-8"))
        finally:
            response.close()


def describe_error(exc):
    if isinstance(exc, urllib.error.HTTPError):
        return "HTTP %d %s" % (exc.code, exc.reason)
    return "%s: %s" % (type(exc).__name__, exc)


def fetch_all(client, api_version=None, log=None):
    """Return (payloads, statuses, versions). Failures are recorded, not raised."""
    log = log or (lambda message: None)
    payloads, statuses = {}, {}
    for path in OPENAPI_PATHS:
        try:
            payloads["openapi"] = client.get(path)
            statuses["openapi"] = {"path": path, "ok": True}
            break
        except Exception as exc:  # noqa: any failure means "try the next one"
            statuses["openapi"] = {"path": path, "ok": False,
                                   "error": describe_error(exc)}
            log("openapi: %s failed (%s)" % (path, describe_error(exc)))
    versions = detect_versions(payloads.get("openapi"))
    if api_version:
        versions = {"slurm": api_version, "slurmdb": api_version}
    if "slurm" not in versions:
        raise RuntimeError("could not detect the API version from the OpenAPI "
                           "document; pass --api-version (for example v0.0.41)")
    versions.setdefault("slurmdb", versions["slurm"])
    for stem, plugin, resource in ENDPOINTS:
        path = "/%s/%s/%s" % (plugin, versions[plugin], resource)
        try:
            payloads[stem] = client.get(path)
            statuses[stem] = {"path": path, "ok": True}
        except Exception as exc:  # noqa
            statuses[stem] = {"path": path, "ok": False, "error": describe_error(exc)}
            log("%s: %s failed (%s)" % (stem, path, describe_error(exc)))
    return payloads, statuses, versions


def anonymise_payloads(payloads, anonymiser):
    """Anonymise everything except the OpenAPI schema. Returns (payloads, residue)."""
    data = dict((k, v) for k, v in payloads.items() if k != "openapi")
    for stem in sorted(data):
        anonymiser.collect(data[stem])
    result, residue = dict(payloads), {}
    for stem in sorted(data):
        result[stem] = anonymiser.scrub(data[stem])
        hits = anonymiser.residue(result[stem])
        if hits:
            residue[stem] = hits
    return result, residue


def write_dump(out_dir, payloads, manifest):
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    written = []
    for stem in sorted(payloads) + ["manifest"]:
        content = manifest if stem == "manifest" else payloads[stem]
        if stem == "manifest":
            manifest["files"] = dict((name, size) for name, size in written)
        target = os.path.join(out_dir, stem + ".json")
        with open(target, "w") as handle:
            json.dump(content, handle, indent=1, sort_keys=True)
            handle.write("\n")
        written.append((stem + ".json", os.path.getsize(target)))
    return written


def count_items(stem, payload):
    value = payload.get(stem) if isinstance(payload, dict) else None
    if isinstance(value, dict):  # shares: {"shares": {"shares": [...]}}
        value = value.get(stem)
    return len(value) if isinstance(value, list) else None


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Record the slurmrestd payloads the Slurm Monitor server consumes.")
    parser.add_argument("--base-url", default=os.environ.get("SLURMRESTD_URL"),
                        help="slurmrestd base URL, e.g. https://slurm.example.org:6820 "
                             "(default: $SLURMRESTD_URL)")
    parser.add_argument("--api-version",
                        help="e.g. v0.0.41; detected from the OpenAPI document when omitted")
    parser.add_argument("--user", default=None,
                        help="Slurm user the token belongs to (default: current user)")
    parser.add_argument("--output-dir", default="slurmrestd-dump")
    parser.add_argument("--anonymise", dest="anonymise", action="store_true", default=True,
                        help="replace personal data with pseudonyms (default)")
    parser.add_argument("--no-anonymise", dest="anonymise", action="store_false",
                        help="write the payloads as received; do not share the result")
    parser.add_argument("--keep-user", action="append", default=[], metavar="NAME",
                        help="leave this user name untouched (repeatable)")
    parser.add_argument("--runner-pattern", action="append", default=None, metavar="REGEX",
                        help="job name prefix to keep (repeatable; replaces the defaults: %s)"
                             % " ".join(DEFAULT_RUNNER_PATTERNS))
    parser.add_argument("--keep-word", action="append", default=None, metavar="WORD",
                        help="word kept in anonymised job names and commands "
                             "(repeatable; replaces the defaults: %s)"
                             % " ".join(DEFAULT_KEEP_WORDS))
    parser.add_argument("--salt", default=None,
                        help="fixed salt for the hashes (default: random per run)")
    parser.add_argument("--ca-file", default=None, help="CA bundle for HTTPS")
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args(argv)
    if not args.base_url:
        parser.error("--base-url is required (or set SLURMRESTD_URL)")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    user = args.user or getpass.getuser()
    try:
        token = obtain_token()
        client = Client(args.base_url, user, token, args.timeout, args.ca_file)
        payloads, statuses, versions = fetch_all(
            client, args.api_version, log=lambda m: sys.stderr.write(m + "\n"))
    except RuntimeError as exc:
        sys.stderr.write("error: %s\n" % exc)
        return 2

    residue = {}
    anonymiser = None
    if args.anonymise:
        anonymiser = Anonymiser(args.runner_pattern, args.keep_user, args.keep_word,
                                args.salt)
        payloads, residue = anonymise_payloads(payloads, anonymiser)

    manifest = {
        "recorded_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "api_versions": versions,
        "anonymised": bool(args.anonymise),
        "endpoints": statuses,
    }
    written = write_dump(args.output_dir, payloads, manifest)

    print("Wrote to %s (slurm %s, slurmdb %s):"
          % (args.output_dir, versions["slurm"], versions["slurmdb"]))
    for name, size in written:
        stem = name[:-5]
        items = count_items(stem, payloads.get(stem))
        extra = "  %d %s" % (items, stem) if items is not None else ""
        print("  %-16s %10d bytes%s" % (name, size, extra))
    failed = sorted(s for s, status in statuses.items() if not status["ok"])
    for stem in failed:
        print("  MISSING %s: %s (%s)" % (stem, statuses[stem]["path"],
                                         statuses[stem]["error"]))
    if anonymiser is not None:
        print("Anonymised: %d users, %d accounts, %d groups, %d job names."
              % (len(anonymiser.users), len(anonymiser.accounts),
                 len(anonymiser.groups), len(anonymiser.job_names)))
        if residue:
            print("REVIEW BEFORE SHARING - original names still present:")
            for stem in sorted(residue):
                for where, name in residue[stem][:20]:
                    print("  %s.json  %s  contains %r" % (stem, where, name))
                if len(residue[stem]) > 20:
                    print("  %s.json  ... %d more" % (stem, len(residue[stem]) - 20))
        else:
            print("Self-check: no known user, account or group name and no "
                  "foreign e-mail address left in the files.")
    else:
        print("NOT anonymised. Do not share these files.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
