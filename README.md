# datahub-v2-smoke-tests-helm

Helm chart deploying [datahub-v2-smoke-tests](https://github.com/Abdessalam7/datahub-v2-smoke-tests)
into the **same namespace** as
[datahub-v2-web-ui-helm](https://github.com/Abdessalam7/datahub-v2-web-ui-helm)
— it's the producer for the COS status files the web UI reads.

## Layout

```
Chart.yaml
values.yaml
templates/
  _helpers.tpl
  cronjob-airflow.yaml     runs scripts/main.py, env from .Values.airflow.env
  cronjob-spark.yaml       runs scripts/main.py, env from .Values.spark.env
  configmap-instances.yaml renders .Values.smokeTest.instancesJson as-is
  serviceaccount.yaml
  externalsecret.yaml      optional — pulls the image-pull secret from Vault
```

Two separate CronJobs, one per tech, both on `.Values.schedule` (every 10
minutes by default). Splitting them means a Spark auth failure (e.g. Vault
cert not provisioned yet) can't affect the Airflow check.

Templates are intentionally generic passthroughs (`{{- with .Values.x }}` +
`toYaml`) for `env`, `volumes`, `volumeMounts`, `resources`, `nodeSelector`,
`tolerations`, `affinity` — all the specifics live in `values.yaml`, not in
the templates.

## Before deploying

1. **`smokeTest.instancesJson`** in `values.yaml` is a **raw JSON string**
   (not a native YAML structure) rendered as-is into the ConfigMap — same
   shape as the Airflow `airflowctl_inst_list_json` variable. Currently
   seeded with two example instances — replace with the real list before
   installing. Only the Airflow CronJob mounts this ConfigMap.
2. **`airflow.volumes[0].configMap.name`**: because `values.yaml` isn't
   templated, this can't reference the chart's fullname helper — it's a
   literal string that must match `<release-name>-<chart-name>-instances`
   for whatever release name you actually install under. The default assumes
   `helm install datahub-v2-smoke-tests ./datahub-v2-smoke-tests-helm`; update
   it if you use a different release name.
3. **COS credentials**: both CronJobs read `COS_ENDPOINT` / `COS_BUCKET_NAME` /
   `COS_REGION` / `COS_ACCESS_KEY_ID` / `COS_SECRET_ACCESS_KEY` directly from
   a `cos-credentials` Secret (must already exist in the namespace — this
   chart does not create it) via `secretKeyRef` entries in `airflow.env` /
   `spark.env`. Double-check those key names against whatever the real
   Secret's keys are before installing.
4. **`TARGET`/`ENV_LIST`**: set independently per tech in `airflow.env` /
   `spark.env` (default `TARGET=hprd`, `ENV_LIST=dev,int,qual`) — override
   per `helm install`/`-f values-<env>.yaml` for the other splits (e.g.
   `TARGET=prod ENV_LIST=prod,pprd`).
5. **Spark only — Vault mTLS cert**: `spark.env` ships with `VAULT_NS`/
   `VAULT_URL` empty and `spark.volumes`/`spark.volumeMounts` empty —
   `spark_auth.py` needs a client certificate mounted to authenticate to
   Vault. The `serviceAccount.annotations` (cert-manager issuer) already
   provision an identity for this workload; once a Vault cert-auth role is
   set up for that identity, fill in `VAULT_NS`/`VAULT_URL` and add the
   cert Secret as a volume/volumeMount under `spark.volumes`/
   `spark.volumeMounts`.
6. **`vault.enabled`** (default `false`): if set, `externalsecret.yaml`
   creates the `imagePullSecretName` Secret from Vault (via the
   external-secrets operator, KV path `vault.kv.path`) instead of assuming
   `image-pull-secret` already exists in the namespace. Not yet validated
   against a real SecretStore for this workload — leave off until confirmed.
