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
   method).

   **`spark.vaultClientCert.enabled` must stay `false`.** It was originally
   meant to request the client cert from `datalab-cloud-echonet-issuer`
   (EverTrust Horizon) via `templates/certificate.yaml`, same as the web
   UI's ingress TLS cert. Confirmed in production: this issuer always
   returns a certificate with Extended Key Usage `TLS Web Server
   Authentication` — never `client auth` — no matter what `spec.usages`
   the `Certificate` resource requests. Vault's cert-auth backend rejects
   that cert outright (`x509: certificate specifies an incompatible key
   usage`). Worse, if left `true` alongside `vaultCertRenewal.enabled`,
   cert-manager periodically re-issues and overwrites a good Vault-PKI cert
   with this broken one. Don't turn it back on for this secret; it's kept
   in the chart only in case a future EverTrust profile actually supports
   client-auth certs.

   Instead, seed the secret **once**, manually, straight from Vault's own
   PKI engine (the same one `vaultCertRenewal` below uses for ongoing
   renewal), authenticated with your own Vault session (token/OIDC — not
   cert-auth, since there's no cert yet to bootstrap from):
   ```bash
   vault write -namespace="a101731" -format=json pkis/pysmoke-test/issue/pysmoke-spark \
     common_name=pysmoke-test-spark.data.cloud.net.intra > /tmp/issued.json

   kubectl create secret generic pysmoke-test-spark-vault-cert -n <namespace> \
     --from-literal=tls.crt="$(jq -r '.data.certificate' /tmp/issued.json)" \
     --from-literal=tls.key="$(jq -r '.data.private_key' /tmp/issued.json)" \
     --from-literal=ca.crt="$(jq -r '.data.issuing_ca' /tmp/issued.json)"
   ```
   Use `kubectl create` (not `apply` on top of an old cert-manager-owned
   Secret) — an inherited `ownerReferences` pointing at a `Certificate`
   gets the Secret cascade-deleted by Kubernetes the moment that
   `Certificate` is removed (e.g. by flipping `vaultClientCert.enabled` to
   `false` in a later `helm upgrade`). Confirm `kubectl get secret
   pysmoke-test-spark-vault-cert -n <namespace> -o jsonpath='{.metadata.ownerReferences}'`
   comes back empty.

   Then register a Vault cert-auth role trusting **Vault's own PKI CA**
   (not any corporate/EverTrust CA — the cert above was issued by
   `pkis/pysmoke-test`, so that's the CA the role must trust):
   ```bash
   vault read -namespace="a101731" -field=certificate pkis/pysmoke-test/cert/ca > /tmp/vault_pki_ca.pem

   vault policy write -namespace="a101731" pysmoke-test-spark - <<'EOF'
   path "secret/data/astronomer-a101731-aas/astronomer-a101731-dev-53d53716/cp-spark-*" {
     capabilities = ["read"]
   }
   EOF

   vault write -namespace="a101731" auth/cert/certs/pysmoke-test-spark \
     display_name=pysmoke-test-spark \
     policies=pysmoke-test-spark,pysmoke-spark-pki-issue \
     allowed_common_names=pysmoke-test-spark.data.cloud.net.intra \
     certificate=@/tmp/vault_pki_ca.pem
   ```
   (`pysmoke-spark-pki-issue` is the renewal policy from step 6 below —
   included here since the role needs both from the start.) The secret
   path above is the one `spark_auth.py` already reads — its
   `client-id`/`client-secret` have access to every client's Spark tenants
   (confirmed), so no new Keycloak client needs provisioning. Don't reuse
   the org's existing `secretstore` policy for this: it's scoped to one
   specific Airflow instance's own secrets and can be overwritten whenever
   that instance is redeployed.

   Once done, fill in `VAULT_NS`/`VAULT_URL` in `spark.env` (currently
   defaulted to `a101731` / the staging Vault address, matching the
   non-prod branch of this org's CI — override for prod).
6. **Spark only — automatic cert renewal (`spark.vaultCertRenewal`)**: the
   client cert from step 5 has a 30-day TTL. Since the Vault Kubernetes-auth
   mount in this cluster isn't self-service (403 on role creation for
   anyone outside the team that owns it), renewal reuses the cert-auth role
   you already control instead: `vaultdynamicsecret-spark-cert.yaml` calls
   Vault's PKI `issue/<pkiRole>` endpoint, authenticating with the *current*
   client cert (`spark.vaultClientCert.secretName`) via cert-auth — and
   `externalsecret-spark-cert-renew.yaml` writes the freshly issued
   cert/key straight back into that same Secret (`creationPolicy: Merge`).
   Since the refresh runs well inside the 30-day TTL (default
   `refreshInterval: 24h`), each cycle always has a still-valid cert on hand
   to authenticate the next one — as long as it's seeded once per step 5.

   **`spark.vaultCertRenewal.enabled` should stay `true`** — this is the
   only thing that should ever manage this secret post-bootstrap; it's why
   `vaultClientCert.enabled` above must stay `false` (both fighting over
   the same Secret is exactly what broke Spark auth in production). The
   PKI-issue policy is already included in the role write above. Requires
   the `generators.external-secrets.io/v1alpha1 VaultDynamicSecret` CRD
   (ESO generator, separate from the plain `SecretStore`-based
   `externalsecret.yaml` above).
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
   throttling yet). `SMTP_HOST`/`SMTP_PORT`/`SMTP_USERNAME`/`SMTP_PASSWORD`/
   `EMAIL_FROM` read from a `smtp-credentials` Secret (keys `host`/`port`/
   `user`/`password`/`sender`) this chart does not create — double-check
   those key names against whatever your real Vault-backed Secret's keys
   actually are, same caveat as `cos-credentials` above. `EMAIL_TO` (comma-separated
   recipients) is a plain value, set per environment. Sending is skipped
   with a warning if `SMTP_HOST`/`EMAIL_TO` are empty. `SMTP_USE_TLS`
   defaults to `true` (STARTTLS + login) for an authenticated relay; set it
   to `false` if yours takes unauthenticated connections instead.
