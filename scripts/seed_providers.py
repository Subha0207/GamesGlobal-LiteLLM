#!/usr/bin/env python3
"""Push providers/models.yaml into LiteLLM's Postgres-backed model table.

The proxy runs with store_model_in_db=true, so the model table - not a config
file and not the UI - is the live provider list. This script makes that table
match the YAML file, which keeps the provider list in version control.

Idempotent: a model_name already present is replaced, so re-running after an
edit updates it. With --prune, models in the database that are absent from the
file are deleted too, making the file authoritative.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")


def call(base_url, key, path, payload=None, method=None):
    url = f"{base_url.rstrip('/')}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method or ("POST" if data else "GET"))
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode()[:500]
        raise SystemExit(f"{method or 'GET'} {path} failed: HTTP {exc.code}\n{detail}")
    except urllib.error.URLError as exc:
        raise SystemExit(f"cannot reach {url}: {exc.reason}")


def resolve_env_refs(params, model_name):
    """Substitute os.environ/NAME values from this shell's environment.

    LiteLLM resolves those references when the row is written, against the
    proxy pod's environment - not at call time. If the variable is empty there
    the credential is dropped entirely and the row is stored with no api_key,
    which surfaces later as an upstream authentication error that looks nothing
    like a seeding problem. Resolving here instead sends the real value, which
    LiteLLM encrypts at rest with LITELLM_SALT_KEY exactly as the UI does.
    """
    resolved = {}
    for name, value in params.items():
        if isinstance(value, str) and value.startswith("os.environ/"):
            var = value.split("/", 1)[1]
            actual = os.environ.get(var, "")
            if not actual:
                raise SystemExit(
                    f"{model_name}: {var} is unset or empty in this shell.\n"
                    f"Put it in .env at the repo root; 40-seed-providers.sh sources it."
                )
            resolved[name] = actual
        else:
            resolved[name] = value
    return resolved


def existing_models(base_url, key):
    """model_name -> [db ids] for everything currently stored in Postgres."""
    found = {}
    for entry in call(base_url, key, "/model/info").get("data", []):
        name = entry.get("model_name")
        model_id = (entry.get("model_info") or {}).get("id")
        if name and model_id:
            found.setdefault(name, []).append(model_id)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True, help="e.g. http://k8s-litellm-xxxx.elb.amazonaws.com")
    ap.add_argument("--master-key", required=True)
    ap.add_argument("--file", required=True, help="path to providers/models.yaml")
    ap.add_argument("--prune", action="store_true",
                    help="delete models present in the database but not in the file")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with open(args.file) as fh:
        desired = yaml.safe_load(fh).get("models") or []
    if not desired:
        sys.exit(f"no models defined in {args.file}")

    current = existing_models(args.base_url, args.master_key)
    print(f"database currently holds {sum(len(v) for v in current.values())} model(s)")

    for model in desired:
        name = model["model_name"]
        if args.dry_run:
            print(f"  would seed  {name}  ->  {model['litellm_params']['model']}")
            continue

        for stale_id in current.get(name, []):
            call(args.base_url, args.master_key, "/model/delete", {"id": stale_id})

        call(args.base_url, args.master_key, "/model/new", {
            "model_name": name,
            "litellm_params": resolve_env_refs(model["litellm_params"], name),
            "model_info": model.get("model_info", {}),
        })
        print(f"  seeded      {name}  ->  {model['litellm_params']['model']}")

    if args.prune:
        keep = {m["model_name"] for m in desired}
        for name, ids in current.items():
            if name in keep:
                continue
            for model_id in ids:
                if args.dry_run:
                    print(f"  would prune {name}")
                else:
                    call(args.base_url, args.master_key, "/model/delete", {"id": model_id})
                    print(f"  pruned      {name}")

    if not args.dry_run:
        print("\ndone. Replicas pick up the change within "
              "proxy_config_reload_interval_seconds (30s).")


if __name__ == "__main__":
    main()
