# akeyless-ops-gists

Operational scripts migrated from Fahmy-Kadiri-akl's personal gists on 2026-10-15.

| Directory | Original gist | Description |
|---|---|---|
| `gateway-connectivity-test/` | [90c9b94f…](https://gist.github.com/Fahmy-Kadiri-akl/90c9b94fc8c314463713fc3299a60b5f) | Akeyless gateway connectivity test (DNS or IP mode, multi-tenant) |
| `connectivity-ip-mt/` | [449e61ef…](https://gist.github.com/Fahmy-Kadiri-akl/449e61eff8b32c3bdabf94b302fbd018) | `ip-connectivity.sh` + `mt-connectivity.sh` |
| `kind-docker-install/` | [46fbabec…](https://gist.github.com/Fahmy-Kadiri-akl/46fbabecd737c5ffa9183e925fccc108) | Kind + Docker install guide (ends with Akeyless Helm repo setup) |
| `keygen/` | [e54aaf8d…](https://gist.github.com/Fahmy-Kadiri-akl/e54aaf8dd40a03c09db037ecc6a62341) | Akeyless key generation helper |
| `microk8s-install/` | [a61d01c7…](https://gist.github.com/Fahmy-Kadiri-akl/a61d01c7d90acc833966cee2953cd39b) | Microk8s installation + Akeyless Gateway/SRA Helm walkthrough |
| `gateway-sra-docker-compose/` | [4323fc31…](https://gist.github.com/Fahmy-Kadiri-akl/4323fc31e702733424a4c87e1c2ad9e6) | Gateway + SSH bastion + zero-trust bastion + syslog docker-compose (sanitized: placeholder access IDs, email, hostnames) |
| `k8s-auth-terraform/` | [b6674c57…](https://gist.github.com/Fahmy-Kadiri-akl/b6674c57374f2c24385660bc83e929fa) | Akeyless Kubernetes Auth setup via Terraform |
| `gke-gateway-k8s-auth/` | [204c5db7…](https://gist.github.com/Fahmy-Kadiri-akl/204c5db7fbd622fb2fac8bd905f16df9) | GKE gateway deployment + apps + K8s auth scripts |

Migration notes:

- All 8 gists scanned for Islamic-studies content (none found), hardcoded credentials (none found), and private information. The docker-compose file was sanitized before migration: real access IDs, a work email, an internal hostname and a personal home-directory path were replaced with placeholders. The original gist retains the real values; see the gist for the pre-sanitization reference.
- The `k8s-auth-terraform/1.README.md` curl commands point at the original gist URLs; they still work because the gists remain in place.
- The 13 secret gists were not migrated.
