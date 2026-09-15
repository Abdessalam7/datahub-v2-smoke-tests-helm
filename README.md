# datahub-v2-smoke-tests-helm

Helm chart deploying [datahub-v2-smoke-tests](https://github.com/Abdessalam7/datahub-v2-smoke-tests)
into the **same namespace** as
[datahub-v2-web-ui-helm](https://github.com/Abdessalam7/datahub-v2-web-ui-helm)
(`monitoring-datahub-v2` by default) — it's the producer for the COS status
files the web UI reads.

## Layout

```
Chart.yaml
values.yaml
templates/
  cronjob-airflow.yaml     runs scripts/main.py with SERVICE=airflow
  cronjob-spark.yaml       runs scripts/main.py with SERVICE=spark
  configmap-instances.yaml Airflow instance list mounted at INSTANCES_CONFIG_PATH
  serviceaccount.yaml
```

Two separate CronJobs, one per tech, both on `smokeTests.schedule` (every 10
minutes by default). Splitting them means a Spark auth failure (e.g. Vault
cert not provisioned yet) can't affect the Airflow check.

## Before deploying

1. **`smokeTests.instances`** in `values.yaml` is a native YAML list (same
   shape as the Airflow `airflowctl_inst_list_json` variable) rendered to
   JSON by `templates/configmap-instances.yaml`. Currently seeded with two
   example instances — update the list for your real set before installing.
   Only the Airflow CronJob mounts this ConfigMap.
2. **COS credentials**: this chart reads from the same `cos-credentials`
   Secret as `datahub-v2-web-ui-helm` (must already exist in the namespace —
   this chart does not create it). Its key names don't all match what
   `scripts/config.py` expects; `values.yaml`'s `smokeTests.cosSecret.keys`
   bridges the difference (e.g. the Secret's `COS_ENDPOINT_URL` is exposed to
   the container as `COS_ENDPOINT`). Double-check this mapping against
   whatever the real Secret's keys are before installing.
3. **`TARGET`/`ENV_LIST`**: set independently per tech under
   `smokeTests.airflow.env` / `smokeTests.spark.env` (default
   `TARGET=hprd`, `ENV_LIST=dev,int,qual`) — override per
   `helm install`/`-f values-<env>.yaml` for the other splits (e.g.
   `TARGET=prod ENV_LIST=prod,pprd`). `SERVICE` itself is set directly in
   each CronJob template, not in `values.yaml`.
4. **Spark only — Vault mTLS cert**: `smokeTests.spark.vaultClientCert.enabled`
   is `false` by default. `spark_auth.py` needs a client certificate mounted
   at `/client-cert` to authenticate to Vault. Once a Vault cert-auth role is
   set up for this workload: set `vaultClientCert.enabled: true`, point
   `vaultClientCert.secretName` at the Secret cert-manager issues, and fill
   in `spark.env.VAULT_NS`/`spark.env.VAULT_URL`.
