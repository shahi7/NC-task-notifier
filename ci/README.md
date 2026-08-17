# Approved image lock

CI/CD deployment remains disabled until `approved-images.lock` is committed, reviewed, and bound to the exact approved commit. The lock contains one image per non-comment line and accepts only the protected project namespace:

```text
${CI_REGISTRY_IMAGE}/approved/<repository>@sha256:<64 lowercase hex>
```

Do not put environment values, registry credentials, scan output, or secret metadata in this directory. Promotion evidence belongs in protected GitLab job artifacts and OCI attestations.
