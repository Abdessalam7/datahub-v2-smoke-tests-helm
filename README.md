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
  cronjob-dags.yaml        optional — DAG-level monitoring, env from .Values.dags.env
  configmap-instances.yaml renders .Values.smokeTest.instancesJson as-is
  serviceaccount.yaml
  externalsecret.yaml      optional — pulls the image-pull secret from Vault
  certificate.yaml         optional — client cert for Spark's Vault cert-auth
  vaultdynamicsecret-spark-cert.yaml   optional — Vault PKI reissue generator
  externalsecret-spark-cert-renew.yaml optional — writes the reissued cert back
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
5. **Spark only — Vault mTLS cert**: `spark_auth.py` needs a client
   certificate mounted at `/client-cert` to authenticate to Vault (cert-auth
   method). Two things gate this, both off by default:

   - **`spark.vaultClientCert.enabled`**: when `true`, `templates/certificate.yaml`
     requests a client cert from `datalab-cloud-echonet-issuer` (the same
     ClusterIssuer that already issues the web UI's ingress TLS cert in this
     cluster — proven working, no Vault-team dependency for this part),
     stored in `spark.vaultClientCert.secretName`. You still need to add the
     matching volume/volumeMount under `spark.volumes`/`spark.volumeMounts`
     (see the commented example right above them in `values.yaml`) — this
     can't be wired automatically since `values.yaml` isn't templated.
   - **A Vault cert-auth role trusting that CA** — this chart can't create it
     (Vault config, not a Kubernetes resource). Once the `Certificate` above
     is `Ready`, pull its CA, create a dedicated read-only policy for the
     Spark client-credentials secret `spark_auth.py` reads, and register the
     role (adapt namespace to your setup):
     ```bash
     kubectl get secret datahub-v2-smoke-tests-spark-vault-cert \
       -n <namespace> -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.pem

     vault policy write -namespace="a101731" pysmoke-test-spark - <<'EOF'
     path "secret/data/astronomer-a101731-aas/astronomer-a101731-dev-53d53716/cp-spark-*" {
       capabilities = ["read"]
     }
     EOF

     vault write -namespace="a101731" auth/cert/certs/pysmoke-test-spark \
       display_name=pysmoke-test-spark \
       policies=pysmoke-test-spark \
       allowed_common_names=pysmoke-test-spark.data.cloud.net.intra \
       certificate=@/tmp/ca.pem
     ```
     The secret path above is the one `spark_auth.py` already reads — its
     `client-id`/`client-secret` have access to every client's Spark tenants
     (confirmed), so no new Keycloak client needs provisioning. Don't reuse
     the org's existing `secretstore` policy for this: it's scoped to one
     specific Airflow instance's own secrets and can be overwritten whenever
     that instance is redeployed.

   Once both are done, fill in `VAULT_NS`/`VAULT_URL` in `spark.env`
   (currently defaulted to `a101731` / the staging Vault address, matching
   the non-prod branch of this org's CI — override for prod).
6. **Spark only — automatic cert renewal (`spark.vaultCertRenewal`)**: the
   client cert from step 5 has a 30-day TTL and isn't renewed by anything
   above. Since the Vault Kubernetes-auth mount in this cluster isn't
   self-service (403 on role creation for anyone outside the team that owns
   it), renewal reuses the cert-auth role you already control instead:
   `vaultdynamicsecret-spark-cert.yaml` calls Vault's PKI `issue/<pkiRole>`
   endpoint, authenticating with the *current* client cert
   (`spark.vaultClientCert.secretName`) via cert-auth — and
   `externalsecret-spark-cert-renew.yaml` writes the freshly issued
   cert/key straight back into that same Secret (`creationPolicy: Merge`).
   Since the refresh runs well inside the 30-day TTL (default
   `refreshInterval: 24h`), each cycle always has a still-valid cert on hand
   to authenticate the next one — no bootstrap problem once the Secret
   exists.

   Both resources are gated by `spark.vaultCertRenewal.enabled` (default
   `false`) and need the PKI-issue policy added to the existing cert-auth
   role from step 5:
   ```bash
   vault write -namespace="a101731" auth/cert/certs/pysmoke-test-spark \
     display_name=pysmoke-test-spark \
     policies=pysmoke-test-spark,pysmoke-spark-pki-issue \
     allowed_common_names=pysmoke-test-spark.data.cloud.net.intra \
     certificate=@/tmp/ca.pem
   ```
   where `pysmoke-spark-pki-issue` is a policy granting `create`/`update` on
   `pkis/pysmoke-test/issue/pysmoke-spark`. Requires the
   `generators.external-secrets.io/v1alpha1 VaultDynamicSecret` CRD (ESO
   generator, separate from the plain `SecretStore`-based `externalsecret.yaml`
   above).
7. **`vault.enabled`** (default `false`): if set, `externalsecret.yaml`
   creates the `imagePullSecretName` Secret from Vault (via the
   external-secrets operator, KV path `vault.kv.path`) instead of assuming
   `image-pull-secret` already exists in the namespace. Not yet validated
   against a real SecretStore for this workload — leave off until confirmed.
8. **`dags.enabled`** (default `false`): a separate CronJob that walks
   *every* DAG on each client's Airflow instance (not just the health probe
   `cronjob-airflow.yaml` does) via the Airflow REST API, flagging any DAG
   still `queued` past `QUEUED_THRESHOLD_SECONDS` (default 600s — well above
   normal executor cold-start, tune once you have real data). Requires a
   technical user created on each client's Airflow, credentials in a
   `airflow-dag-monitor` Secret (keys `username`/`password`) this chart does
   not create:
   ```bash
   kubectl create secret generic airflow-dag-monitor \
     --from-literal=username=<technical-user> \
     --from-literal=password=<password> \
     -n <namespace>
   ```
   Basic Auth for now; migrating to Vault-issued credentials is planned but
   not implemented. `dags.env.ENV_LIST` filters by environment, same as
   `airflow.env.ENV_LIST`, but each client's Airflow is a separate instance
   with its own user base — the technical user only exists on whichever
   clients it's been created on. Use `dags.env.CLIENT_LIST` (comma-separated
   business_line names, e.g. `"pf"`) to scope the check to only those
   clients during rollout; leaving it empty checks everyone and 403s for
   every client not yet provisioned. The web UI shows every DAG; email
   alerting (`dags.env.EMAIL_ENABLED`, off by default) sends problems only
   (failed or delayed) straight off the same run's in-memory results — no
   extra storage. It's unconditional per run: while a DAG stays broken,
   an email goes out every cycle that still sees it broken (no dedup/
   throttling yet). `SMTP_HOST`/`SMTP_USERNAME`/`SMTP_PASSWORD`/`EMAIL_FROM`
   read from a `smtp-credentials` Secret (keys `HOST`/`PORT`/`USER`/
   `PASSWORD`) this chart does not create — double-check those key names
   against whatever your real Vault-backed Secret's keys actually are, same
   caveat as `cos-credentials` above. `EMAIL_TO` (comma-separated
   recipients) is a plain value, set per environment. Sending is skipped
   with a warning if `SMTP_HOST`/`EMAIL_TO` are empty. `SMTP_USE_TLS`
   defaults to `true` (STARTTLS + login) for an authenticated relay; set it
   to `false` if yours takes unauthenticated connections instead.
