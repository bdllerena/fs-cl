# rdiCidr — Repository & Pipeline Findings

**Date:** 2026-09-25
**Reviewer:** DevOps engineering
**Repo:** `bdllerena/fs-cl` (reviewed at `main`, commit `a111a67`)
**Status:** CI pipeline remediated in PR #1 (branch `fix/ci-pipeline`). Container and
Kubernetes findings are still open and untouched.

> **Remediation log:** section 10 records the four pipeline runs, what each one failed
> on, and the evidence. Findings carry a status tag: **`[FIXED]`**, **`[OPEN]`**, or
> **`[DEFERRED]`** where a fix was deliberately not applied in this pass.

## Scope & method

Static review of the repository as committed. Evidence is drawn from file contents,
declared versions, and lockfile state only. Inline comments in source and manifests
(e.g. the `FIXME` on [k8s/deployment.yaml:20](k8s/deployment.yaml#L20)) were deliberately
excluded as evidence so the review is not steered by them; where a finding overlaps such
a comment, it was reached independently from the configuration itself.

The original review executed nothing: no `npm ci`, no `docker build`, no `kubectl apply`.
Findings marked **Confirmed** were provable from file contents; those marked **Expected**
were a reasoned consequence of tool behaviour, to be validated once a run was possible.

Section 10 supersedes that distinction for the CI findings: the pipeline has now been run
four times and each CI finding is either confirmed by a real failure or resolved. The
container and Kubernetes findings remain unexecuted and keep their original markers.

---

## 1. Repository topology

```
.
├── .chat-history/log.md            session log (tooling, not app)
├── CLAUDE.md                       assistant instructions (tooling, not app)
├── generateZip.sh / .bat           assessment packaging helpers (not app tooling)
├── k8s/
│   ├── deployment.yaml             Deployment "rdicidr", 2 replicas
│   └── service.yaml                Service "rdicidr-service", ClusterIP
└── codebase/
    └── rdicidr-0.1.0/              <-- actual application root
        ├── .github/workflows/ci.yaml   CI definition (NOT at repo root)
        ├── .nvmrc                      15.5.1
        ├── .npmrc                      engine-strict=true
        ├── .gitignore                  node_modules, build, .env*
        ├── Dockerfile                  multi-stage: node:15-alpine -> nginx:1.21-alpine
        ├── nginx.conf                  SPA fallback + /health on :80
        ├── package.json                CRA app, engines node >=15 <16
        ├── package-lock.json           lockfileVersion 2
        ├── public/                     index.html, manifest.json, robots.txt
        └── src/
            ├── App.js / index.js       app shell
            ├── IPv4Addr.js, Netmask.js, Octet.js, SubnetNumbersInput.js
            ├── lib/ipv4.js             subnetting logic (IPv4 class, 198 lines)
            ├── App.test.js             2 render tests
            └── tests/ipv4.test.js      9 unit tests
```

### Key structural fact

There are **three distinct roots** and they do not line up:

| Root | Contains | Consumed by |
|---|---|---|
| Repo root | `k8s/`, zip scripts | `kubectl`, humans |
| `codebase/rdicidr-0.1.0/` | app, `Dockerfile`, `package.json` | npm, Docker |
| `codebase/rdicidr-0.1.0/.github/` | `workflows/ci.yaml` | **nothing — GitHub does not read this path** |

Every path-related finding below descends from this mismatch.

## 2. Application runtime profile

| Aspect | Value | Source |
|---|---|---|
| Language | JavaScript (ES2015+, JSX) | `src/**` |
| Framework | React 17.0.1, Create React App via `react-scripts` 4.0.3 | [package.json](codebase/rdicidr-0.1.0/package.json) |
| Node (declared) | `>=15.0.0 <16.0.0`, pinned `15.5.1` | `engines`, [.nvmrc](codebase/rdicidr-0.1.0/.nvmrc) |
| npm (declared) | `>=7.0.0 <8.0.0` | `engines` |
| Engine enforcement | **Hard fail** — `engine-strict=true` | [.npmrc](codebase/rdicidr-0.1.0/.npmrc) |
| Test runner | Jest via `react-scripts test` | `scripts.test` |
| Lint | `eslint ./src/` with `react-app` + `plugin:prettier/recommended` | `scripts.lint`, `eslintConfig` |
| Build output | Static bundle in `build/` | `react-scripts build` |
| Runtime artifact | nginx 1.21-alpine serving static files on **port 80** | [Dockerfile](codebase/rdicidr-0.1.0/Dockerfile), [nginx.conf](codebase/rdicidr-0.1.0/nginx.conf) |
| Runtime config | `REACT_APP_API_URL`, **inlined at build time** | [App.js:15](codebase/rdicidr-0.1.0/src/App.js#L15) |

**Note on the runtime:** this is a static single-page app. After `npm run build` there is no
Node process at runtime — only nginx serving files. Node 15 is a *build-time* requirement
only. That distinction matters for every sizing and probe decision in section 5.

Node 15.5.1 ships npm 7.3.0, which satisfies both declared engine ranges. That combination
is the coherent target the repository describes.

---

## 3. Findings — CI pipeline

### P0-1 — The workflow is not in a location GitHub Actions reads · `[FIXED]`

`ci.yaml` lives at [codebase/rdicidr-0.1.0/.github/workflows/ci.yaml](codebase/rdicidr-0.1.0/.github/workflows/ci.yaml).
GitHub Actions only discovers workflows in `.github/workflows/` at the **repository root**.
There is no `.github` directory at the root.

**Impact:** the pipeline has never run and cannot run. No push or PR trigger fires.
Everything below is latent — it becomes visible only once this is corrected.

### P0-2 — No `working-directory`; npm steps would run where there is no `package.json` · `[FIXED]`

All four jobs run `npm ci` / `npm run *` with no `working-directory` and no `defaults.run`
block. Relocating the workflow to the repo root puts every npm step in a directory that
contains no `package.json`.

**Impact:** `npm ci` exits with `ENOENT`/`Could not read package.json` in all four jobs.

### P0-3 — `npm ci` will abort: `package.json` and `package-lock.json` are out of sync · `[OPEN]`

| Item | `package.json` | `package-lock.json` |
|---|---|---|
| `prettier@3.3.1` | declared in `dependencies` | **absent** (only `@types/prettier` exists) |
| `engines.npm` | `>=7.0.0 <8.0.0` | `>=7.0.0 <9.0.0` |

The lockfile's root `packages[""]` block lists eight dependencies; `package.json` lists nine.
`npm ci` refuses to run against a desynchronised lockfile.

**Impact:** `npm ci` fails with *"can only install packages when your package.json and
package-lock.json are in sync… Missing: prettier@3.3.1 from lock file"*. This breaks the CI
install job **and** the Docker build ([Dockerfile:4](codebase/rdicidr-0.1.0/Dockerfile#L4)).
It also tells us `package.json` was edited after the lock was generated.

### P0-4 — CI pins Node 14; the project hard-requires Node 15 · `[FIXED]`

All four jobs set `node-version: '14'` ([ci.yaml:19,33,47,61](codebase/rdicidr-0.1.0/.github/workflows/ci.yaml#L19)),
while `engines` demands `>=15.0.0 <16.0.0` and `.npmrc` sets `engine-strict=true`.
`.nvmrc` (15.5.1) is never consulted because no job uses `node-version-file`.

Node 14 also ships npm 6 by default, which violates `engines.npm >=7.0.0` and predates the
`lockfileVersion: 2` format the lockfile uses.

**Impact:** `npm ci` aborts with `EBADENGINE` before installing anything. `engine-strict=true`
converts what is normally a warning into a hard failure.

### P0-5 — `npm run lint` cannot resolve its own ESLint config · `[FIXED]`

`scripts.lint` invokes `eslint ./src/`. Neither `eslint`, `eslint-plugin-prettier`, nor
`eslint-config-prettier` is a declared dependency, and searching the lockfile for
`node_modules/eslint-plugin-prettier` and `node_modules/eslint-config-prettier` returns
nothing. `eslint` exists only transitively (via `react-scripts`), but `eslintConfig.extends`
includes `plugin:prettier/recommended`, which requires the two missing packages.

**Impact:** the lint job fails with a config-resolution error, not a lint error. The
`prettier` script (`prettier -c ./src/`) fails too — see P0-3, `prettier` is not installed.

### P0-6 — A unit test asserts on an environment variable that is never set · `[FIXED]`

[App.test.js:10-13](codebase/rdicidr-0.1.0/src/App.test.js#L10-L13) asserts the rendered
output matches `/api\.rdicidr\.com/i`. That string can only come from
`process.env.REACT_APP_API_URL` at [App.js:15](codebase/rdicidr-0.1.0/src/App.js#L15).
That variable is defined nowhere: no `.env` file exists, all `.env*` files are gitignored,
the workflow sets no `env:`, and the Dockerfile declares no `ARG`/`ENV`.

**Impact:** the test job fails — the element renders as `API: ` and `getByText` throws.
The nine tests in `src/tests/ipv4.test.js` are self-contained and should pass.

### P0-7 — The build job restores a cache key nothing ever saved · `[FIXED]`

- `install` saves with key `node-modules-${{ hashFiles('package-lock.json') }}` ([ci.yaml:24](codebase/rdicidr-0.1.0/.github/workflows/ci.yaml#L24))
- `lint` and `test` restore with the same prefix
- `build` restores with `deps-${{ hashFiles('package-lock.json') }}` ([ci.yaml:65](codebase/rdicidr-0.1.0/.github/workflows/ci.yaml#L65))

**Impact:** the build job always misses the cache, gets no `node_modules`, and fails with
`react-scripts: command not found`.

### P1-8 — The cache key is a constant and never invalidates · `[FIXED]`

`hashFiles()` resolves globs relative to `GITHUB_WORKSPACE`. `package-lock.json` sits at
`codebase/rdicidr-0.1.0/package-lock.json`, so the pattern matches nothing and `hashFiles`
returns an empty string. Every key collapses to the literal `node-modules-`.

**Impact:** currently benign only because the cache is never populated. Once P0-1/P0-2 are
fixed, this becomes a correctness bug: dependency changes never bust the cache, and jobs
silently run against stale `node_modules`.

### P1-9 — Cache misses fail late and misleadingly · `[FIXED]`

No restore step sets `fail-on-cache-miss: true`, and no dependent job has an `npm ci`
fallback. A miss produces no error; the job proceeds without `node_modules` and dies later
with `command not found`.

### P0-33 — `hashFiles()` in the save step hashes the *post-install* lockfile · `[FIXED]`

**Discovered by run 36176886901** — not visible during static review, because the
pipeline had never run.

Each job called `hashFiles()` for itself. GitHub evaluates a step's `with:` expressions
when that step *starts*, so in the install job the cache key was computed **after**
`npm install` had already rewritten `package-lock.json`. Downstream jobs hash the
pristine committed lockfile, so the two never agree:

```
install saved:  node-modules-Linux-7bc7149b73d583be1c5b5c288398620d32788c47e81754a43a4d79f3f6443666
lint restored:  node-modules-Linux-4fa292cb62aef1662efa4cf33a3b1d0f3263065283995dfbfc9b19fcba1a0dc4
```

**Root cause:** this is P0-3 surfacing at runtime. `npm install` rewrites the lockfile
precisely because `prettier@3.3.1` is declared in `package.json` and missing from the
lock. With a synchronised lockfile the hashes would usually coincide — which is worse,
because the bug would then appear only intermittently.

**Impact:** every downstream job fails at `Restore node_modules`. Note this was only
*visible* because P1-9 (`fail-on-cache-miss`) had already been fixed; without it the
jobs would have failed several steps later with `eslint: command not found`.

**Fix applied:** the key is computed once in the install job, in a dedicated step that
runs before `npm install`, and exposed as a job output that lint, test and build
consume. `install` was added to every job's `needs` so the output stays reachable.

### P1-10 — Caching `node_modules` across jobs is the fragile option · `[DEFERRED]`

Three jobs each pay a checkout + `setup-node` + cache-restore round trip to avoid one
install. `actions/setup-node` has built-in npm-cache support (`cache: 'npm'` +
`cache-dependency-path`) that caches the npm *download* cache rather than the installed
tree — which is safe across Node patch versions and native rebuilds. `node-sass` is a
native module (see P2-19), which makes a shared `node_modules` tree especially brittle.

### P1-11 — `feature-*` does not match `feature/*` branches · `[FIXED]`

[ci.yaml:7](codebase/rdicidr-0.1.0/.github/workflows/ci.yaml#L7) filters on `'feature-*'`.
In GitHub's branch-filter glob syntax `*` does not cross `/`. A branch named
`feature/add-ipv6` will not trigger CI; only `feature-add-ipv6` will.

**Impact:** silent trigger gaps depending on team branch-naming convention. Needs an explicit
decision on which convention is canonical.

### P1-12 — No `permissions`, `concurrency`, or `timeout-minutes` · `[FIXED]`

- No `permissions:` block — `GITHUB_TOKEN` gets the repository default rather than
  least privilege. This matters before any deploy job is added.
- No `concurrency:` group — rapid pushes to the same branch run redundant, overlapping jobs.
- No `timeout-minutes` — a hung job occupies a runner for the 6-hour default.

### P1-13 — Pipeline stops at `npm run build`; no artifact, image, or deploy · `[OPEN]`

The repository ships a `Dockerfile` and Kubernetes manifests, and neither is referenced by CI.
Missing stages:

- `actions/upload-artifact` for `build/` — the build output is discarded
- Docker image build, tag, and push (no registry configured anywhere)
- Image or dependency vulnerability scanning; no `npm audit` gate
- AWS authentication (no OIDC role assumption), no ECR login
- Any deployment step to EKS, and no `kubectl`/manifest validation

**Impact:** CI verifies the app compiles; nothing else. There is no path from a green build
to a running container.

### P2-14 — Actions pinned to v3 tags on the deprecated Node 16 runner · `[FIXED]`

`actions/checkout@v3`, `actions/setup-node@v3`, and `actions/cache/{save,restore}@v3` all run
on the deprecated `node16` action runtime and emit deprecation warnings. Tags are also
mutable — no SHA pinning.

---

## 4. Findings — container image

### P0-15 — The image build fails for the same reason CI does · Expected

[Dockerfile:4](codebase/rdicidr-0.1.0/Dockerfile#L4) runs `npm ci` against the same
desynchronised lockfile (P0-3). `node:15-alpine` satisfies the engine constraint, so P0-4
does not apply here, but P0-3 does.

`node:15-alpine` is also an end-of-life, unmaintained base image (Node 15 reached EOL in
June 2021) and receives no security patches.

### P0-16 — `REACT_APP_API_URL` can never be set, at build or runtime · Confirmed

CRA substitutes `REACT_APP_*` variables into the bundle at build time. The Dockerfile
declares no `ARG`/`ENV`, so the baked bundle always contains an empty API URL. Because the
value is baked, it also **cannot** be injected later via a Kubernetes `env:` or ConfigMap —
setting it on the Deployment would have no effect on the served JavaScript.

**Impact:** this is an architectural constraint, not a typo. Per-environment API URLs require
either a build argument per environment (image per environment) or a runtime-config pattern
(e.g. an `env-config.js` written by the container entrypoint and read by the app).

### P1-17 — No `.dockerignore` · Confirmed

`COPY . .` ([Dockerfile:5](codebase/rdicidr-0.1.0/Dockerfile#L5)) runs after `npm ci`. With no
`.dockerignore`, a local `node_modules`, `build/`, or `.git` is sent in the build context and
copied over the freshly installed tree — invalidating layer caching and potentially
overwriting the installed dependencies with whatever the developer had locally.

### P1-18 — Container runs as root · Confirmed

The `nginx:1.21-alpine` stage sets no `USER`. The master process runs as root because it
binds port 80. Moving to an unprivileged port (e.g. 8080) would allow a non-root user, but
requires the port change to propagate to `nginx.conf`, the Dockerfile, and the Deployment
together.

### P2-19 — `node-sass` is declared, unused, and pins the project to Node ≤15 · Confirmed

`node-sass@5.0.0` is a direct dependency, but the repository contains **zero** `.scss` or
`.sass` files — all styling is plain `.css`. `node-sass` is a native module
(`hasInstallScript: true`, requires `node-gyp` and a C toolchain), and version 5 supports
only Node ≤15.

**Impact:** this single unused dependency is the main thing blocking a move to a supported
Node LTS, and it is the most likely source of intermittent install failures. Removing it
should be evaluated before any Node upgrade is attempted.

### P2-20 — Favicon reference points at a file outside `public/` · Confirmed

`public/index.html` references `%PUBLIC_URL%/RD.svg` (lines 5 and 12), but `RD.svg` exists at
`src/RD.svg`. `%PUBLIC_URL%` resolves to the `public/` output, so the icon 404s at runtime.

---

## 5. Findings — Kubernetes manifests

### P0-21 — The Service selects a label no pod carries · Confirmed

| | Value | Location |
|---|---|---|
| Service selector | `app: rdicidr-web` | [service.yaml:8](k8s/service.yaml#L8) |
| Pod template label | `app: rdicidr` | [deployment.yaml:15](k8s/deployment.yaml#L15) |

**Impact:** the Service has zero endpoints permanently. All traffic to `rdicidr-service`
fails with connection refused. `kubectl get endpoints rdicidr-service` returns `<none>`.

### P0-22 — Probes target a port nothing listens on · Confirmed

Both probes hit port 3000 ([deployment.yaml:33](k8s/deployment.yaml#L33),
[deployment.yaml:40](k8s/deployment.yaml#L40)), matching `containerPort: 3000`
([deployment.yaml:22](k8s/deployment.yaml#L22)). The container is nginx, which listens on
**80** ([nginx.conf:2](codebase/rdicidr-0.1.0/nginx.conf#L2)). Port 3000 is the CRA *dev
server* port and is never used in the built image.

**Impact:** the readiness probe never succeeds (pod never enters service) and the liveness
probe always fails (kubelet restarts the container) → permanent `CrashLoopBackOff`.
The `/health` endpoint that `nginx.conf` defines is correct — only the port is wrong.

### P0-23 — Liveness probe settings would kill healthy pods · Confirmed

`initialDelaySeconds: 1`, `periodSeconds: 3`, `failureThreshold: 1`
([deployment.yaml:34-36](k8s/deployment.yaml#L34-L36)). A single missed check, one second
after container start, restarts the pod. There is no tolerance for a transient blip and no
startup grace.

### P1-24 — Resource requests are ~2 orders of magnitude oversized · Confirmed

Requests 4 CPU / 4Gi, limits 8 CPU / 8Gi, at 2 replicas → **8 CPU and 8Gi requested** for a
static file server. Typical EKS worker nodes (m5.large = 2 vCPU) cannot schedule a single pod.

**Impact:** pods sit `Pending` with `FailedScheduling / Insufficient cpu`, or force
needlessly large nodes and cost. An nginx serving a static bundle is realistically in the
tens-of-millicores, tens-of-MiB range — but the correct values should come from measurement,
not from this document's guess.

### P1-25 — Image reference is unresolvable and non-deterministic · Confirmed

`image: rdicidr:latest` ([deployment.yaml:19](k8s/deployment.yaml#L19)) has no registry host,
so a cluster resolves it against Docker Hub, where it does not exist → `ErrImagePull`. For
AWS this needs a full ECR reference.

Independently of that: the `latest` tag combined with `imagePullPolicy: IfNotPresent` means a
node that already holds *any* image called `rdicidr:latest` will never pull a newer one, so
rollouts are non-deterministic and not reproducible. An immutable tag (git SHA) or a digest
removes the ambiguity, and makes the pull-policy question moot.

### P1-26 — ClusterIP only; nothing exposes the app externally · Confirmed

The Service is `type: ClusterIP` and there is no Ingress, no `LoadBalancer`, and no
AWS Load Balancer Controller annotation. The app is unreachable from outside the cluster.

### P2-27 — Manifest completeness gaps · Confirmed

No `namespace` on either object (everything lands in `default`); no `securityContext`
(`runAsNonRoot`, `readOnlyRootFilesystem`, dropped capabilities); no resource `strategy`
(rolling-update surge/unavailable); no `HorizontalPodAutoscaler`; no `PodDisruptionBudget`;
no `NetworkPolicy`; no standard `app.kubernetes.io/*` labels; no Kustomize or Helm layering
for per-environment values.

---

## 6. Findings — repository hygiene

| ID | Finding | Evidence |
|---|---|---|
| P2-28 | `.DS_Store` committed at repo root and in `codebase/`; no root `.gitignore` | file listing |
| P2-29 | Application root is version-stamped (`rdicidr-0.1.0/`) — every CI path, Docker context, and script embeds a version number that changes on release | directory name |
| P2-30 | No root `README` explaining the layout, how to build, or how to deploy | file listing |
| P2-31 | No `CODEOWNERS`, no PR template, no evidence of branch protection | file listing |
| P2-32 | `generateZip.sh` / `.bat` are assessment packaging helpers, not application tooling; they delete `node_modules`/`build` and zip the tree | [generateZip.sh:12](generateZip.sh#L12) |

---

## 7. Recommendations

Ordered so that each step makes the next one observable. Do not batch these — P0-1 alone
will surface a cascade of failures that are currently invisible.

### Stage 1 — Make the pipeline run at all

1. **Move `.github/workflows/ci.yaml` to the repository root** (P0-1). This is the single
   change that turns a dead file into a running pipeline.
2. **Add `defaults.run.working-directory: codebase/rdicidr-0.1.0`** at workflow level (P0-2),
   and update every `hashFiles()` pattern to the full path
   `codebase/rdicidr-0.1.0/package-lock.json` (P1-8).
3. **Align the Node version with the application** (P0-4). Prefer
   `node-version-file: codebase/rdicidr-0.1.0/.nvmrc` over a hardcoded string, so `.nvmrc`
   stays the single source of truth. Node 15.5.1 ships npm 7.3.0, satisfying both engine
   ranges without further changes.
4. **Resynchronise the lockfile** (P0-3). Run `npm install` on Node 15 to regenerate
   `package-lock.json` with `prettier@3.3.1` present, and reconcile the `engines.npm`
   discrepancy (`<8` vs `<9`) to one intended value. Verify with a clean `npm ci`.

### Stage 2 — Make each job pass

5. **Fix the lint toolchain** (P0-5). Add `eslint`, `eslint-plugin-prettier`, and
   `eslint-config-prettier` as explicit `devDependencies` at versions compatible with
   `react-scripts` 4 (ESLint 7). Alternatively drop `plugin:prettier/recommended` from
   `eslintConfig` and keep formatting checks in the separate `prettier` script — decide which,
   rather than running both half-configured.
6. **Resolve the failing test** (P0-6). Either set `REACT_APP_API_URL` in the test
   environment, or change `App.test.js` to assert on the rendered structure rather than a
   value that is only defined at build time. The latter is more honest: the current test
   asserts on deployment configuration, not on application behaviour.
7. **Unify the cache keys** (P0-7) and add `fail-on-cache-miss: true` to every restore
   (P1-9), so a miss fails loudly at the restore step instead of silently three steps later.
8. **Reconsider the cache strategy** (P1-10). `actions/setup-node` with `cache: 'npm'` and
   `cache-dependency-path` is fewer lines and safer than hand-rolled `node_modules` caching,
   particularly while `node-sass` remains a native dependency.

### Stage 3 — Harden triggers and permissions

9. **Decide the branch convention and make the filter match it** (P1-11) — `feature/*` and
   `feature-*` are different globs; pick one and document it.
10. **Add `permissions: contents: read` at workflow level** (P1-12), raising it per-job only
    where needed. Do this before adding any deploy job that needs `id-token: write`.
11. **Add `concurrency` with `cancel-in-progress: true`** and `timeout-minutes` per job
    (P1-12).
12. **Pin actions to commit SHAs** and move off the deprecated v3 tags (P2-14).

### Stage 4 — Close the delivery gap

13. **Upload `build/` as an artifact** so the tested bundle is the one that ships (P1-13).
14. **Add a Docker build job** using `codebase/rdicidr-0.1.0` as context, and add a
    `.dockerignore` (P1-17) before doing so.
15. **Settle the runtime-config question first** (P0-16). The choice between
    build-arg-per-environment and a runtime `env-config.js` determines whether one image can
    be promoted across environments. This decision shapes the tagging and deploy design, so
    it should precede them rather than follow.
16. **Adopt immutable image tags** — `${ECR_REGISTRY}/rdicidr:${GITHUB_SHA}` (P1-25) — and
    reference ECR explicitly. This makes the `imagePullPolicy` question disappear.
17. **Add AWS OIDC authentication** (`aws-actions/configure-aws-credentials` with a role to
    assume, no long-lived keys), then ECR login and push (P1-13).
18. **Add scanning gates**: `npm audit`/dependency review on PRs, and an image scan
    (ECR scan-on-push or Trivy) before promotion (P1-13).

### Stage 5 — Make the manifests deployable

19. **Fix the Service selector** to `app: rdicidr` (P0-21) — or relabel the Deployment; they
    must simply agree. Verify with `kubectl get endpoints`.
20. **Correct the port to 80 throughout** — `containerPort`, both probe ports (P0-22). The
    `/health` path already exists in `nginx.conf` and needs no change.
21. **Relax the liveness probe** (P0-23): a realistic `initialDelaySeconds`, `failureThreshold`
    of at least 3, and a `startupProbe` if slow starts are ever observed.
22. **Right-size resources from measurement** (P1-24). Deploy with modest requests, observe
    actual usage under load, then set requests near the observed steady state with headroom
    in the limits. Do not carry over the current values.
23. **Add an Ingress or `LoadBalancer`** appropriate to the target EKS cluster (P1-26), and
    move both objects into an explicit namespace (P2-27).
24. **Add `securityContext`** (`runAsNonRoot`, `readOnlyRootFilesystem`, drop `ALL`
    capabilities). This depends on P1-18 — nginx must be moved to a non-privileged port first,
    coordinated across `nginx.conf`, Dockerfile, Service `targetPort`, and probes.
25. **Add a deploy job** that applies manifests with the image tag substituted (Kustomize
    `images:` or `kubectl set image`), gated on the branch. Add manifest validation
    (`kubectl apply --dry-run=server` or `kubeconform`) to PR runs.

### Stage 6 — Hygiene

26. **Remove `node-sass`** (P2-19) — it is unused and is the primary blocker to running a
    supported Node version. Confirm no `.scss` appears before removing, then rebuild the lock.
27. **Evaluate a supported Node LTS** once 26 is done (P0-15). Node 15 is four years EOL and
    `node:15-alpine` receives no security patches. This is a deliberate, separately tested
    change — `react-scripts` 4 on a modern Node may need `NODE_OPTIONS=--openssl-legacy-provider`
    or a `react-scripts` upgrade. Not a drive-by fix.
28. **Add a root `.gitignore`**, remove the committed `.DS_Store` files (P2-28), and add a
    root `README` covering layout, build, and deploy (P2-30).
29. **Fix the favicon path** — move `RD.svg` into `public/` (P2-20).
30. **Consider flattening `codebase/rdicidr-0.1.0/` to `app/`** (P2-29) so CI paths do not
    embed a version number that changes at every release.

---

## 8. Suggested verification checklist

Once changes begin, these are the checks that prove each stage landed:

```bash
# Stage 1-2 — local, from codebase/rdicidr-0.1.0
node -v                       # expect the .nvmrc version
npm ci                        # must complete with no EBADENGINE and no sync error
npm run lint
CI=true npm test -- --watchAll=false
npm run build                 # build/ must be produced

# Stage 4 — image
docker build -t rdicidr:test codebase/rdicidr-0.1.0
docker run --rm -p 8080:80 rdicidr:test
curl -fsS localhost:8080/health          # expect "ok"
curl -fsS localhost:8080/ | grep -o '<title>.*</title>'

# Stage 5 — cluster
kubectl apply --dry-run=server -f k8s/
kubectl get endpoints rdicidr-service    # must NOT be <none>
kubectl get pods -l app=rdicidr          # must reach Running/Ready, not CrashLoopBackOff
kubectl describe pod -l app=rdicidr | grep -A3 Events
```

## 9. Open questions for the team

1. **Branch convention** — `feature/*` or `feature-*`? Determines the trigger filter (P1-11).
2. **Environment strategy** — one image promoted across environments, or an image per
   environment? Determines how `REACT_APP_API_URL` is handled (P0-16), and therefore the
   tagging and deploy design.
3. **Target cluster** — EKS cluster name, region, namespace, and ECR repository. None are
   referenced anywhere in the repository.
4. **Ingress** — ALB via AWS Load Balancer Controller, or nginx-ingress? Determines the
   annotations needed in Stage 5.
5. **Node upgrade appetite** — is moving off EOL Node 15 in scope, or should the pipeline be
   fixed against the versions as declared? Recommendations are written to work either way;
   Stage 1–5 do not require the upgrade.

---

## 10. CI remediation log — PR #1 (`fix/ci-pipeline`)

The pipeline was fixed in two deliberate phases so the previously hidden application
defects appear in the run history as evidence rather than being silently patched
alongside the workflow.

**Phase 1 — pipeline only.** No application code, dependency or manifest was touched.
The goal was a workflow that *triggers and runs*, so that whatever fails, fails visibly.

**Phase 2 — application fixes**, each one driven by what a run actually reported.

### Run history

| # | Run | Commit | Result | Failed at | Evidence |
|---|---|---|---|---|---|
| 1 | [36176886901](https://github.com/bdllerena/fs-cl/actions/runs/36176886901) | `229a07c` | ✗ fail | `lint` → Restore node_modules | `Failed to restore cache entry. Exiting as fail-on-cache-miss is set.` |
| 2 | [36177221510](https://github.com/bdllerena/fs-cl/actions/runs/36177221510) | `8238e47` | ✗ fail | `lint` → Run ESLint | `ESLint couldn't find the plugin "eslint-plugin-prettier".` |
| 3 | [36177534195](https://github.com/bdllerena/fs-cl/actions/runs/36177534195) | `8a8edf2` | ✗ fail | `test` → Run Jest | `Unable to find an element with the text: /api\.rdicidr\.com/i` — 1 failed, 10 passed |
| 4 | [36177850242](https://github.com/bdllerena/fs-cl/actions/runs/36177850242) | `607c415` | ✓ **pass** | — | `Compiled successfully.` — all four stages green |

### Observed failures in detail

**Run 1 — the pipeline executed for the first time.** Relocating the workflow was enough
to make it trigger, and `install` passed immediately: Node 15.5.1 resolved from `.nvmrc`,
`npm install` added 1920 packages in 38s with no engine error. That alone retired P0-1,
P0-2 and P0-4.

The failure was new information. `lint` died at `Restore node_modules` on a key mismatch
that static review could not have predicted — see **P0-33**. Worth noting that the fix
for P1-9 (`fail-on-cache-miss`) is what made this legible; without it the job would have
run on and failed later with a misleading `command not found`.

**Run 2 — cache fixed, real lint failure exposed.** With one shared key the restore
succeeded, and ESLint finally ran for what is almost certainly the first time in this
repository's history. It failed exactly as P0-5 predicted:

```
ESLint: 7.29.0
ESLint couldn't find the plugin "eslint-plugin-prettier".
(The package "eslint-plugin-prettier" was not found when loaded as a Node module
 from the directory ".../codebase/rdicidr-0.1.0".)
The plugin "eslint-plugin-prettier" was referenced from the config file in "package.json".
```

This run also cleared the `actions/*@v4` Node 20 deprecation annotations.

**Run 3 — lint green, real test failure exposed.**

```
PASS src/tests/ipv4.test.js
FAIL src/App.test.js
  ● displays the API URL
    TestingLibraryElementError: Unable to find an element with the text: /api\.rdicidr\.com/i
Tests: 1 failed, 10 passed, 11 total
```

Exactly P0-6. The nine subnetting tests in `src/tests/ipv4.test.js` passed, confirming
the application logic was never the problem.

**Run 4 — green.** `install` 47s, `lint` 13s, `test` 14s, `build` 18s.

### Changes made

| Commit | Scope | Findings addressed |
|---|---|---|
| `229a07c` | Workflow relocated to `.github/workflows/ci.yaml` and rewritten | P0-1, P0-2, P0-4, P0-7, P1-8, P1-9, P1-11, P1-12, P2-14 |
| `8238e47` | Shared cache key as a job output; actions to current majors | P0-33, P2-14 |
| `8a8edf2` | `plugin:prettier/recommended` removed from `eslintConfig` | P0-5 |
| `607c415` | `App.test.js` supplies its own `REACT_APP_API_URL` fixture | P0-6 |

### Pipeline as it now stands

Triggers on `pull_request` (any branch, `opened`/`synchronize`/`reopened`) and on pushes
to `main`. The four original stages are preserved and now run strictly in order, which
they did not before — previously `lint`, `test` and `build` each depended only on
`install` and ran in parallel:

```
install → lint → test → build
```

Commands are as specified: `npm install`, `npm run lint`, `CI=true npm run test`,
`npm run build`.

### Decisions worth challenging

**P0-5 was resolved by removing the Prettier plugin, not by installing it.** The two
missing packages cannot be added at the versions this project pins: `react-scripts`
4.0.3 pins ESLint 7.29.0, `eslint-plugin-prettier` v5 requires ESLint >= 8, and v4 calls
the synchronous Prettier 2 API that Prettier 3.3.1 (declared here) removed. Enforcing
format through ESLint would therefore also require downgrading Prettier to 2.x, which
reaches past a pipeline fix and risks reformatting the tree. Formatting is left to the
existing standalone `npm run prettier` script — also what Prettier upstream recommends
over running it as an ESLint rule.

*If the team wants format enforcement back inside `npm run lint`*, the coherent
combination is `prettier@^2.8.8` + `eslint-plugin-prettier@^4.2.1` +
`eslint-config-prettier@^8.10.0`, and `npm run prettier` should then be added to the
pipeline as its own stage.

**P0-6 was resolved by changing the test, not by setting the variable in CI.** Setting
`REACT_APP_API_URL` in the workflow would make the suite pass in CI and fail on every
developer's machine. The fixture belongs to the test.

### Still open after this PR

- **P0-3** — `package.json` and `package-lock.json` remain out of sync. `npm install`
  masks this (it reconciles the lockfile in place, which is what caused P0-33); `npm ci`
  would still abort, and the Dockerfile uses `npm ci`. **The container image cannot be
  built until this is resolved.** Regenerating the lockfile on Node 15 is the fix.
- **P0-16** — `REACT_APP_API_URL` is still inlined at build time and cannot be injected
  into a running container. Unchanged by the test fix; it is a packaging decision.
- **P1-13** — the pipeline still stops at `npm run build`. No artifact upload, no image
  build, no registry, no AWS authentication, no deploy.
- **All container (section 4) and Kubernetes (section 5) findings** — untouched.

### Note on the runner

Every run emits: *"The ubuntu-latest label will migrate to Ubuntu 26 beginning
October 19, 2026."* Node 15.5.1 currently installs cleanly on the Ubuntu 24 image, but
that is not guaranteed to survive the migration, and Node 15 has been EOL since June
2021. This is the concrete deadline that makes P2-19 (remove the unused `node-sass`) and
recommendation 27 (move to a supported Node LTS) time-bound rather than cosmetic.

---

## Summary

**CI — resolved.** The pipeline had never executed: its workflow file sat inside the
application subdirectory rather than at the repository root. Behind that single blocker
were eight more independent failures. Four runs took it from never-triggered to green,
and the sequence is worth keeping: each run exposed exactly one defect, and one of them
(**P0-33**, a cache key hashed after `npm install` had rewritten the lockfile) was not
predictable from static review at all. The two application defects it surfaced — an
ESLint config referencing a plugin that was never installed, and a test asserting on an
environment variable defined nowhere in the repository — had been invisible for the
entire life of the repository because nothing ever ran them.

**Container and Kubernetes — still open.** The image cannot be built at all while P0-3
stands, since the Dockerfile uses `npm ci` against a desynchronised lockfile. The
manifests cannot serve traffic: the Service selects a label no pod carries, and both
probes target a port nothing listens on, guaranteeing `CrashLoopBackOff` behind a Service
with no endpoints.

**The delivery gap is unchanged and remains the largest piece of work.** Between a green
build and a running container there is still nothing — no artifact, no image build, no
registry, no AWS authentication, no deploy. CI now proves the application compiles and
its tests pass. It proves nothing about what ships.
