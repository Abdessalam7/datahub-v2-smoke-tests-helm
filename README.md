# datahub-v2-smoke-tests-helm

Helm chart deploying [datahub-v2-smoke-tests](https://github.com/Abdessalam7/datahub-v2-smoke-tests)
into the **same namespace** as
[datahub-v2-web-ui-helm](https://github.com/Abdessalam7/datahub-v2-web-ui-helm)
(`monitoring-datahub-v2` by default) — it's the producer for the COS status
files the web UI reads.

Modeled directly on `datahub-v2-web-ui-helm`'s structure and conventions
(plain `.Values.x` references, no generic passthrough templating).

## Layout

```
Chart.yaml
values.yaml
templates/
  deployment.yaml          runs scripts/main.py
  configmap-instances.yaml Airflow instance list mounted at INSTANCES_CONFIG_PATH
  serviceaccount.yaml
```

## Before deploying

1. **`smokeTests.instances`** in `values.yaml` is a native YAML list (same
   shape as the Airflow `airflowctl_inst_list_json` variable) rendered to
   JSON by `templates/configmap-instances.yaml`. Currently seeded with two
   example instances — update the list for your real set before installing,
   otherwise `run_airflow()` only checks those two.
2. **COS credentials**: this chart reads from the same `cos-credentials`
   Secret as `datahub-v2-web-ui-helm` (must already exist in the namespace —
   this chart does not create it). Its key names don't all match what
   `scripts/config.py` expects; `values.yaml`'s `smokeTests.cosSecret.keys`
   bridges the difference (e.g. the Secret's `COS_ENDPOINT_URL` is exposed to
   the container as `COS_ENDPOINT`). Double-check this mapping against
   whatever the real Secret's keys are before installing.
3. **`SERVICE`/`TARGET`/`ENV_LIST`**: `values.yaml` defaults to
   `SERVICE=airflow`, `TARGET=hprd`, `ENV_LIST=dev,int,qual` — override per
   `helm install`/`-f values-<env>.yaml` for the other splits (e.g.
   `TARGET=prod ENV_LIST=prod,pprd`, or `SERVICE=spark`).
4. **Spark only — Vault mTLS cert**: `smokeTests.vaultClientCert.enabled` is
   `false` by default. `spark_auth.py` needs a client certificate mounted at
   `/client-cert` to authenticate to Vault, which depends on a Vault
   cert-auth role being set up for this workload's own identity (a separate,
   still-open decision — see the design discussion that produced this chart
   for the trade-offs between reusing Airflow's existing role vs. creating a
   dedicated one). Once that's settled: set `vaultClientCert.enabled: true`,
   point `vaultClientCert.secretName` at the Secret cert-manager issues, and
   fill in `env.VAULT_NS`/`env.VAULT_URL`.

## Note on the "one Deployment" shape

This mirrors what's actually running today for `pysmoke-test`/
`datahub-v2-smoke-tests`: a single-replica Deployment (not a CronJob) whose
container exits after one pass and gets restarted by Kubernetes. If you want
true periodic scheduling instead of restart-driven repetition, this chart
would need a `CronJob` instead of a `Deployment` — not done here since the
brief was to match what's actually deployed today, not to change the
scheduling model.
