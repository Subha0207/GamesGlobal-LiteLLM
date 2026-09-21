# LiteLLM on EKS - POC

A working proof of concept: the LiteLLM proxy running on Amazon EKS, backed by
RDS PostgreSQL and ElastiCache Valkey, with the Admin UI exposed through an
Application Load Balancer.

The provider list is **not** configured through the UI. It lives in
[`providers/models.yaml`](providers/models.yaml) and is pushed into Postgres by
[`scripts/40-seed-providers.sh`](scripts/40-seed-providers.sh), so the set of
models is version-controlled, reviewable and reproducible across rebuilds.

Built against the LiteLLM [deployment](https://docs.litellm.ai/docs/proxy/deploy)
and [production](https://docs.litellm.ai/docs/proxy/prod) guides.

---

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://koboyo.com/e/90c56981-1afb-4d0c-8d53-81cb4285045c/eb71a4aa-39e1-4004-a1cc-c30cee751324.svg?theme=dark">
  <img alt="LiteLLM on EKS - runtime wiring" src="https://koboyo.com/e/90c56981-1afb-4d0c-8d53-81cb4285045c/eb71a4aa-39e1-4004-a1cc-c30cee751324.svg">
</picture>

Both datastores sit in private subnets and only accept traffic from the EKS node
security group. The ALB is created by the load balancer controller in response to
the Ingress object, not by Terraform.

### Why each piece is there

| Component | Role |
|---|---|
| **RDS PostgreSQL** | Virtual keys, teams, budgets, spend logs, and the model/provider table. Provider API keys are encrypted at rest with `LITELLM_SALT_KEY`. |
| **ElastiCache Valkey** | Shared state across replicas: routing/cooldowns, response cache, rate-limit counters, spend buffering. Without it, replicas make independent decisions. |
| **Migrations Job** | Owns the schema. Proxy pods run with `DISABLE_SCHEMA_UPDATE=true` so replicas never race each other on a migration. |
| **ALB Ingress** | One entry point for both the OpenAI-compatible API and the Admin UI, with a 600s idle timeout for streaming. |
| **IRSA roles** | The proxy pods get an AWS identity, scoped to reading their own Secrets Manager secret. Provider credentials come from the Kubernetes Secret. |

---

## Layout

```
terraform/            VPC, EKS, RDS, Valkey, IAM/IRSA, generated secrets
k8s/                  Namespace, SA, ConfigMap, migrations Job, Deployment,
                      Service, ALB Ingress, HPA, PDB
providers/models.yaml The provider list - source of truth, seeded into Postgres
scripts/              Numbered, run in order
```

---

## Deploy

Needs `terraform`, `aws`, `kubectl`, `helm`, `python3` (with `pyyaml`), and AWS
credentials that can create VPC/EKS/RDS/ElastiCache/IAM resources.

```bash
./scripts/00-prereqs.sh          # verify toolchain and credentials

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars   # at minimum, set ingress_allowed_cidrs

./scripts/10-deploy-infra.sh     # ~20-25 min (EKS + RDS dominate)
./scripts/20-bootstrap-cluster.sh  # LB controller + metrics-server
```

Provider API keys go in a gitignored `.env` at the repo root before deploying.
They are written only into the Kubernetes Secret; the database stores
`os.environ/...` references, never a raw key.

```bash
cat > .env <<'ENV'
GEMINI_API_KEY=...
HUGGINGFACE_API_KEY=hf_...
ENV

./scripts/30-deploy-litellm.sh   # renders manifests, migrates, rolls out, waits for the ALB
./scripts/40-seed-providers.sh   # loads providers/models.yaml into Postgres
./scripts/50-smoke-test.sh       # health -> model list -> mint key -> chat completion
```

The deploy script prints the ALB hostname when it finishes.

---

## Using it

```bash
BASE_URL=http://<alb-hostname>
MASTER_KEY=$(terraform -chdir=terraform output -raw litellm_master_key)
```

**Admin UI** - `$BASE_URL/ui`, log in as `admin` with the master key.
The UI reads the same Postgres table the seeder writes, so every seeded provider
appears there immediately.

**Proxy** - any OpenAI-compatible client:

```bash
curl $BASE_URL/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "gemini-flash", "messages": [{"role": "user", "content": "hello"}]}'
```

Hand out per-team virtual keys rather than the master key:

```bash
curl -X POST $BASE_URL/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"key_alias": "team-search", "models": ["gemini-flash"], "max_budget": 50}'
```

---

## Managing providers without the UI

This is the part the POC is really about.

![Provider list flow](https://koboyo.com/e/90c56981-1afb-4d0c-8d53-81cb4285045c/db3008bf-5be6-4ad5-9dd7-230baf2d4817.svg)


1. `general_settings.store_model_in_db: true` and `STORE_MODEL_IN_DB=True` make
   the database the live provider list. `model_list` in the ConfigMap is
   intentionally empty.
2. Edit [`providers/models.yaml`](providers/models.yaml).
3. Run `./scripts/40-seed-providers.sh`. It calls the admin API - `/model/info`
   to read what exists, `/model/delete` + `/model/new` to make the table match
   the file. Re-running is safe; an existing `model_name` is replaced.
4. Every replica re-reads the table within 30 seconds
   (`proxy_config_reload_interval_seconds`). No restart, no redeploy.

```bash
./scripts/40-seed-providers.sh --dry-run   # show what would change
./scripts/40-seed-providers.sh             # add and update
./scripts/40-seed-providers.sh --prune     # also delete anything not in the file
```

`--prune` is what makes the file authoritative: anything added by hand in the UI
gets removed on the next run. That is the intended behaviour for this setup.

**Credential handling.** Entries use `api_key: os.environ/GEMINI_API_KEY`, so
the file and the database hold a reference rather than a raw key.

The reference is resolved **when the model row is written**, not when it is read.
Seeding while the pods have an empty value for that variable stores a row with no
key at all, and every call through it then fails with an upstream authentication
error that looks nothing like a configuration problem. So the order matters:

1. Put the key in `.env`.
2. Get it into the pods' environment - `./scripts/30-deploy-litellm.sh`, or patch
   the Secret and restart the Deployment.
3. Confirm it arrived: `kubectl -n litellm exec deploy/litellm -- printenv GEMINI_API_KEY`
4. Only then run `./scripts/40-seed-providers.sh`.

To verify a seeded row actually carries a credential:

```bash
curl -sS -H "Authorization: Bearer $MASTER_KEY" $BASE_URL/model/info \
  | python3 -c 'import json,sys; [print(m["model_name"], "api_key" in m.get("litellm_params",{})) for m in json.load(sys.stdin)["data"]]'
```

---

## IAM

Three roles, created by Terraform, each scoped to one workload:

![IRSA token exchange](https://koboyo.com/e/90c56981-1afb-4d0c-8d53-81cb4285045c/c5c4e397-d028-4dfb-b3a6-3c86db49063c.svg)


| Role | Trusted by | Grants |
|---|---|---|
| `<name>-runtime` | `litellm:litellm` SA | `GetSecretValue` on its own Secrets Manager secret |
| `<name>-alb-controller` | `kube-system:aws-load-balancer-controller` SA | The AWS-published load balancer controller policy |
| `<name>-ebs-csi` | `kube-system:ebs-csi-controller-sa` SA | The managed EBS CSI policy |

The master key, salt key, database URL and Valkey endpoint are also written to a
Secrets Manager secret (`<name>/proxy`) as the durable source of truth.

---

## Editing the diagrams

All three diagrams live on one canvas and the embeds above track it, so an edit there
updates this README: https://koboyo.com/edit/test-90p8j7

## Teardown

```bash
./scripts/99-destroy.sh
```

It deletes the Ingress and waits for the ALB to disappear before running
`terraform destroy` - skipping that leaves an orphaned ALB that blocks the VPC
delete.

---

## What this POC deliberately does not do

Honest list of the gaps between this and a production deployment:

- **Single-AZ datastores.** `multi_az = false` on RDS and one Valkey node with no
  failover. Flip `multi_az`, and set `num_cache_clusters = 2` with
  `automatic_failover_enabled` and `multi_az_enabled`, for production.
- **No TLS on Valkey.** `transit_encryption_enabled = false` keeps the connection
  a plain `redis://`. The cluster is reachable only from the node security group.
  For production, enable it and set `REDIS_SSL="True"` on the pods.
- **HTTP by default.** Set `acm_certificate_arn` in tfvars and the ALB listens on
  443 and redirects HTTP. Without it, the UI and master key travel in clear text.
- **`ingress_allowed_cidrs` defaults to `0.0.0.0/0`.** Narrow it. An open Admin UI
  is an open door to every provider key in the database.
- **No dedicated background-job pod.** At higher volume, run one replica with
  `LITELLM_JOB_ROLE=worker` and the rest as `serving` so scheduled jobs do not
  run on every pod.
- **No SSO, no alerting, no observability wiring.** LiteLLM supports Slack
  alerting (`general_settings.alerting`) and Prometheus metrics; neither is
  configured here.
- **Terraform state is local.** Move it to S3 with DynamoDB locking before more
  than one person touches this.
- **`LITELLM_SALT_KEY` is generated once by Terraform and cannot be rotated**
  after models exist without making every stored provider credential unreadable.
  Treat a `terraform destroy` of the secret as destroying those credentials.

## Rough cost

Running continuously in `us-east-1`, approximately: EKS control plane $73/mo,
2x t3.large $120/mo, db.t4g.medium $50/mo, cache.t4g.micro $12/mo, ALB + NAT
gateway $50/mo - on the order of **$300/month**, before any token spend. Run
`./scripts/99-destroy.sh` when the POC is not in use.
