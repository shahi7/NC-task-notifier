# GitLab Registry promotion policy

This policy applies to **new CI/CD deployments only**. It does not alter running stacks, existing manual Compose deployments, or current image references. Once a stack is migrated to the CI/CD path, its production Compose variables must reference only immutable images from the approved GitLab Container Registry namespace. Do not deploy directly from an upstream registry or a mutable tag.

## Promotion path

1. Mirror the exact upstream image digest into a GitLab Registry `quarantine/` repository. Preserve the upstream digest and source metadata.
2. Scan the quarantined image for OS and language vulnerabilities, generate an SBOM, and store scan/SBOM artifacts with the pipeline.
3. Build a hardened derivative only when required: non-root user, minimal base, dropped capabilities, read-only filesystem compatibility, and no embedded credentials. Scan the derivative again.
4. An administrator reviews the findings and approves promotion by digest into the project's protected `approved/` repository. Never promote a mutable tag.
5. Commit `ci/approved-images.lock` with one exact approved image per line:

   ```text
   registry.example/group/project/approved/app@sha256:<64 lowercase hex>
   ```

6. Set the protected `CI_IMAGE_PROMOTION_APPROVED_SHA` to the exact reviewed commit. The deploy transaction verifies the lock against the production `.env` immediately before publishing and again before Compose starts.

## Required GitLab controls

- Protect `quarantine/` and `approved/` registry namespaces.
- Permit promotion only from protected branches and an administrator-approved manual job.
- Keep registry credentials protected and scoped to pull/push only for their required namespace.
- Retain scan, SBOM, source-digest, and approval metadata with each promoted digest.
- Set `APPROVED_IMAGE_REGISTRY` to `${CI_REGISTRY_IMAGE}/approved`, not the whole registry host.
- Disable pipeline-variable overrides (`no_one_allowed`) so a user cannot replace approval, target, or registry policy variables when starting a pipeline.

The mirror/scan/sign/promotion pipeline is still a required implementation item. The deployment template remains disabled until that pipeline and an isolated executor exist.
