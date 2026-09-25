# rdiCidr — Repository & Pipeline Findings

**Date:** 2026-09-25
**Reviewer:** DevOps engineering
**Repo:** `bdllerena/fs-cl` (reviewed at `main`, commit `a111a67`)
**Status:** CI pipeline remediated (section 10). Image and manifests remediated and
validated on Minikube (section 11). AWS delivery built and validated — the app is live on
the public internet behind an ALB (section 12); the deploy stage runs on merge to `main`.

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

### P0-3 — `npm ci` sync claim, corrected · `[FIXED]`

| Item | `package.json` | `package-lock.json` |
|---|---|---|
| `prettier@3.3.1` | declared in `dependencies` | **absent** (only `@types/prettier` exists) |
| `engines.npm` | `>=7.0.0 <8.0.0` | `>=7.0.0 <9.0.0` |

The lockfile's root `packages[""]` block lists eight dependencies; `package.json` lists nine.
`npm ci` refuses to run against a desynchronised lockfile.

**Impact — corrected 2026-09-25 after testing, this was overstated.** The behaviour is
npm-version dependent, and the original review did not account for that:

| npm | Result |
|---|---|
| **7.7.6** (bundled with Node 15.14 — what `node:15-alpine` and the Dockerfile use) | **Succeeds.** Silently resolves `prettier@3.3.1` from the registry and installs it. |
| **10.x** (Node 20) | **Fails:** `npm error Missing: prettier@3.3.1 from lock file` plus ~40 `Invalid: lock file's …` entries. |

So the claim in PR #1 that "the image cannot be built until P0-3 is fixed" was wrong: at
the pinned Node 15 the Docker build gets past `npm ci` unharmed. The real blocker was
**P0-34** below. P0-3 remains a genuine defect — it is a latent trap for any Node
upgrade, and it is what caused **P0-33** — but it was not blocking the image.

It still tells us `package.json` was edited after the lock was generated.

**Status:** `[FIXED]` — lockfile regenerated on Node 15 (section 11).

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

### P1-13 — Pipeline stops at `npm run build`; no artifact, image, or deploy · `[FIXED]`

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

### P0-15 — The image build fails for the same reason CI does · `[SUPERSEDED by P0-34]`

[Dockerfile:4](codebase/rdicidr-0.1.0/Dockerfile#L4) runs `npm ci` against the same
desynchronised lockfile (P0-3). `node:15-alpine` satisfies the engine constraint, so P0-4
does not apply here, but P0-3 does.

`node:15-alpine` is also an end-of-life, unmaintained base image (Node 15 reached EOL in
June 2021) and receives no security patches.

### P0-16 — `REACT_APP_API_URL` can never be set, at build or runtime · `[OPEN — now visible in production]`

CRA substitutes `REACT_APP_*` variables into the bundle at build time. The Dockerfile
declares no `ARG`/`ENV`, so the baked bundle always contains an empty API URL. Because the
value is baked, it also **cannot** be injected later via a Kubernetes `env:` or ConfigMap —
setting it on the Deployment would have no effect on the served JavaScript.

**Impact:** this is an architectural constraint, not a typo. Per-environment API URLs require
either a build argument per environment (image per environment) or a runtime-config pattern
(e.g. an `env-config.js` written by the container entrypoint and read by the app).

### P1-17 — No `.dockerignore` · `[FIXED]`

`COPY . .` ([Dockerfile:5](codebase/rdicidr-0.1.0/Dockerfile#L5)) runs after `npm ci`. With no
`.dockerignore`, a local `node_modules`, `build/`, or `.git` is sent in the build context and
copied over the freshly installed tree — invalidating layer caching and potentially
overwriting the installed dependencies with whatever the developer had locally.

### P1-18 — Container runs as root · `[FIXED]`

The `nginx:1.21-alpine` stage sets no `USER`. The master process runs as root because it
binds port 80. Moving to an unprivileged port (e.g. 8080) would allow a non-root user, but
requires the port change to propagate to `nginx.conf`, the Dockerfile, and the Deployment
together.

### P2-19 — `node-sass` is declared, unused, and pins the project to Node ≤15 · `[FIXED]`

`node-sass@5.0.0` is a direct dependency, but the repository contains **zero** `.scss` or
`.sass` files — all styling is plain `.css`. `node-sass` is a native module
(`hasInstallScript: true`, requires `node-gyp` and a C toolchain), and version 5 supports
only Node ≤15.

**Impact:** this single unused dependency is the main thing blocking a move to a supported
Node LTS, and it is the most likely source of intermittent install failures. Removing it
should be evaluated before any Node upgrade is attempted.

### P2-20 — Favicon reference points at a file outside `public/` · `[OPEN]`

`public/index.html` references `%PUBLIC_URL%/RD.svg` (lines 5 and 12), but `RD.svg` exists at
`src/RD.svg`. `%PUBLIC_URL%` resolves to the `public/` output, so the icon 404s at runtime.

---

## 5. Findings — Kubernetes manifests

### P0-21 — The Service selects a label no pod carries · `[FIXED]`

| | Value | Location |
|---|---|---|
| Service selector | `app: rdicidr-web` | [service.yaml:8](k8s/service.yaml#L8) |
| Pod template label | `app: rdicidr` | [deployment.yaml:15](k8s/deployment.yaml#L15) |

**Impact:** the Service has zero endpoints permanently. All traffic to `rdicidr-service`
fails with connection refused. `kubectl get endpoints rdicidr-service` returns `<none>`.

### P0-22 — Probes target a port nothing listens on · `[FIXED]`

Both probes hit port 3000 ([deployment.yaml:33](k8s/deployment.yaml#L33),
[deployment.yaml:40](k8s/deployment.yaml#L40)), matching `containerPort: 3000`
([deployment.yaml:22](k8s/deployment.yaml#L22)). The container is nginx, which listens on
**80** ([nginx.conf:2](codebase/rdicidr-0.1.0/nginx.conf#L2)). Port 3000 is the CRA *dev
server* port and is never used in the built image.

**Impact:** the readiness probe never succeeds (pod never enters service) and the liveness
probe always fails (kubelet restarts the container) → permanent `CrashLoopBackOff`.
The `/health` endpoint that `nginx.conf` defines is correct — only the port is wrong.

### P0-23 — Liveness probe settings would kill healthy pods · `[FIXED]`

`initialDelaySeconds: 1`, `periodSeconds: 3`, `failureThreshold: 1`
([deployment.yaml:34-36](k8s/deployment.yaml#L34-L36)). A single missed check, one second
after container start, restarts the pod. There is no tolerance for a transient blip and no
startup grace.

### P1-24 — Resource requests are ~2 orders of magnitude oversized · `[FIXED]`

Requests 4 CPU / 4Gi, limits 8 CPU / 8Gi, at 2 replicas → **8 CPU and 8Gi requested** for a
static file server. Typical EKS worker nodes (m5.large = 2 vCPU) cannot schedule a single pod.

**Impact:** pods sit `Pending` with `FailedScheduling / Insufficient cpu`, or force
needlessly large nodes and cost. An nginx serving a static bundle is realistically in the
tens-of-millicores, tens-of-MiB range — but the correct values should come from measurement,
not from this document's guess.

### P1-25 — Image reference is unresolvable and non-deterministic · `[FIXED]`

`image: rdicidr:latest` ([deployment.yaml:19](k8s/deployment.yaml#L19)) has no registry host,
so a cluster resolves it against Docker Hub, where it does not exist → `ErrImagePull`. For
AWS this needs a full ECR reference.

Independently of that: the `latest` tag combined with `imagePullPolicy: IfNotPresent` means a
node that already holds *any* image called `rdicidr:latest` will never pull a newer one, so
rollouts are non-deterministic and not reproducible. An immutable tag (git SHA) or a digest
removes the ambiguity, and makes the pull-policy question moot.

### P1-26 — ClusterIP only; nothing exposes the app externally · `[FIXED]`

The Service is `type: ClusterIP` and there is no Ingress, no `LoadBalancer`, and no
AWS Load Balancer Controller annotation. The app is unreachable from outside the cluster.

### P2-27 — Manifest completeness gaps · `[PARTIALLY FIXED]`

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

## 11. Kubernetes remediation — Minikube (`fix/k8s-minikube`)

Target: Minikube v1.37.0, **docker** driver, **containerd** runtime, single node,
**arm64** (Apple Silicon), 8 CPU / 7.65Gi allocatable.

The runtime being containerd rather than Docker matters: `eval $(minikube docker-env)`
does not apply, so the image is side-loaded with `minikube image load`.

### 11.1 Applying the manifests unchanged

Per instruction, the original manifests were applied before anything was altered.
**They are schema-valid** — `kubectl apply --dry-run=server -f k8s/` passed cleanly, and
so did the real apply. Every defect is a runtime defect, which is precisely why a review
that stops at "the YAML parses" would have missed all of them.

| Observed | Finding | Evidence |
|---|---|---|
| `ErrImagePull` → `ImagePullBackOff` | P1-25 | `Failed to pull image "rdicidr:latest": ... docker.io/library/rdicidr:latest: pull access denied, repository does not exist` |
| 1 of 2 replicas stuck `Pending` | P1-24 | `0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory` |
| Service had no endpoints | P0-21 | `kubectl get endpoints rdicidr-service` → `<none>` |

P1-24 quantified: the node offers **8 CPU / 7.65Gi** allocatable; two replicas requested
**8 CPU / 8Gi**. Even the memory request alone exceeds the node.

P0-21 proven directly rather than inferred:

```
Service .spec.selector          : {"app":"rdicidr-web"}
Pod labels                      : {"app":"rdicidr","pod-template-hash":"7d68ff6b5b"}
pods matching app=rdicidr-web   : 0
pods actually labelled app=rdicidr: 2
```

**P0-22 could not be observed**, because no container ever started to fail its probes.
It was corrected by design, and the corrected form is what the validations below exercise.

### 11.2 P0-34 — `node-sass` cannot build on arm64/musl · `[FIXED]`

**Discovered building the image.** This is P2-19 escalating from "dead weight" to
"blocks the build outright", and it is the finding that actually prevented an image from
existing — not P0-3, which the original review named (see the correction there).

`npm ci` publishes no prebuilt `node-sass` binary for linux-musl/arm64, so it falls back
to `node-gyp`, and `node:15-alpine` ships no Python:

```
npm ERR! gyp ERR! find Python Python is not set from command line or npm configuration
npm ERR! gyp ERR! find Python - "python3" is not in PATH or produced an error
npm ERR! gyp ERR! stack Error: Could not find any Python installation to use
npm ERR! Build failed with error code: 1
ERROR: failed to solve: process "/bin/sh -c npm ci" did not complete successfully: exit code: 1
```

On the CI runner (linux/amd64, glibc) a prebuilt binary exists, which is why the pipeline
in PR #1 passes and the image build fails. The defect is architecture-specific, and only
appears on the very platform most developers on this team would build from.

**Fix:** `node-sass` removed from `package.json` (the repository contains **zero** `.scss`
or `.sass` files, verified). It survives in the lockfile as an *optional peer* of
`sass-loader`, so the builder additionally uses `npm ci --omit=optional` to skip it
deterministically rather than relying on optional-dependency failure tolerance.

### 11.3 P1-35 — kubectl context silently reverted to a production EKS cluster · `[OPEN]`

**Operational hazard, worth more attention than its number suggests.**

At session start `kubectl config current-context` was
`arn:aws:eks:us-east-1:931686776282:cluster/demo-eks` — a real EKS cluster, not Minikube.
It was switched to `minikube`, and **it reverted on its own partway through the session**.
Commands issued after that point were answered by EKS: a `kubectl get pods -n production`
returned "No resources found", which reads exactly like "the workload disappeared".

Nothing was applied to EKS — verified, there is no `production` namespace there — because
the reversion happened after the applies. That was luck, not design.

**Mitigation used here:** pass `--context=minikube` explicitly on every command rather
than trusting the ambient context.

**Recommended:** find what rewrites the kubeconfig (an `aws eks update-kubeconfig` in a
shell profile is the usual culprit) and, separately, put the EKS context behind
`kubectl config set-context --current --namespace=...` guards or a tool such as `kubectx`
with a prompt indicator. A cluster this easy to hit by accident will eventually be hit
by accident.

### 11.4 Changes applied

**Image** (`codebase/rdicidr-0.1.0/`)

| Change | Finding |
|---|---|
| `node-sass` removed from `package.json`; lockfile regenerated on Node 15 | P2-19, P0-34, P0-3 |
| `npm ci --omit=optional` in the builder stage | P0-34 |
| `.dockerignore` added | P1-17 |
| nginx listens on **8080**; runs as `nginx` (uid 101); pid relocated to `/tmp` | P1-18 |
| Tagged `rdicidr:0.1.0`, not `latest` | P1-25 |

Moving nginx off port 80 is what makes the non-root user possible, and it lines up with
the required Service port, so the same number now runs from container to Service.

**Manifests** (`k8s/`) — `deployment.yaml` and the old `service.yaml` were replaced:

| File | Contents |
|---|---|
| `00-namespace.yaml` | Namespace `production` |
| `10-statefulset.yaml` | StatefulSet `rdicidr`, 3 replicas, `podManagementPolicy: Parallel` |
| `20-service.yaml` | Headless `rdicidr-headless` (StatefulSet `serviceName`) + `rdicidr-service` on 8080 |
| `30-ingress.yaml` | Ingress for `fsl-challenge.me` → `rdicidr-service:8080` |
| `expose-local.sh` | Hosts entry + privileged port bind (the two steps needing root) |

Files are numbered because `kubectl apply -f k8s/` processes a directory in **alphabetical
order**; unprefixed, `30-ingress.yaml` would sort before `00-namespace.yaml` and fail with
`namespaces "production" not found`.

Other manifest corrections: selector labels now match the pod template exactly (P0-21);
probes address the port **by name** so a port change cannot desynchronise them again
(P0-22); liveness `failureThreshold` 3 with a 5s initial delay (P0-23); requests cut from
4 CPU/4Gi to 10m/32Mi with 200m/128Mi limits (P1-24); `app.kubernetes.io/*` labels,
`securityContext` with `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: ["ALL"]` and
`seccompProfile: RuntimeDefault` (P2-27).

`readOnlyRootFilesystem: true` requires the two paths nginx writes to be mounted
`emptyDir`: `/tmp` (the relocated pid file) and `/var/cache/nginx` (client/proxy temp).

> **One concern with the specification, stated once and then built as asked.** A StatefulSet
> is the wrong workload type for this application: it serves identical read-only static
> files, holds no per-replica state, claims no volumes, and needs no stable identity or
> ordered startup. A Deployment expresses that and rolls out faster. The requirement asks
> for a StatefulSet, so that is what is built — `podManagementPolicy: Parallel` removes the
> ordered-startup penalty, which is the only part that would otherwise cost anything here.

### 11.5 Validations

```
$ kubectl --context=minikube get pods -n production
NAME        READY   STATUS    RESTARTS   AGE
rdicidr-0   1/1     Running   0          3m8s
rdicidr-1   1/1     Running   0          3m8s
rdicidr-2   1/1     Running   0          3m8s

$ kubectl --context=minikube get statefulset,svc,ingress -n production
statefulset.apps/rdicidr    3/3
service/rdicidr-headless    ClusterIP   None             8080/TCP
service/rdicidr-service     ClusterIP   10.111.144.146   8080/TCP
ingress/rdicidr             nginx       fsl-challenge.me   192.168.49.2   80

$ kubectl --context=minikube get endpointslices -n production
rdicidr-headless-cdl27   IPv4   8080   10.244.0.7,10.244.0.9,10.244.0.8
rdicidr-service-95z29    IPv4   8080   10.244.0.7,10.244.0.9,10.244.0.8
```

| Requirement | Result |
|---|---|
| StatefulSet, ≥3 replicas | ✅ `statefulset.apps/rdicidr` 3/3 |
| Service + StatefulSet in `production` | ✅ all objects namespaced |
| Service listens on 8080 | ✅ both Services `8080/TCP`, targetPort `http` (8080) |
| Pods Running, probes passing consistently | ✅ 3/3 Ready, **0 restarts**, **0 `Unhealthy` events** |
| Reachable at `http://fsl-challenge.me` | ⚠️ Ingress verified on that exact `Host`; the privileged port-80 bind is deferred — see 11.6 |

Endpoint counts are the direct refutation of P0-21: both Services resolve to all three
Pod IPs, where the original resolved to none.

HTTP behaviour through the Ingress, with `Host: fsl-challenge.me`:

```
/health            -> ok
/                  -> HTTP 200   <title>RDerik Interactive CIDR</title>
/some/deep/route   -> HTTP 200   (SPA fallback works)
Host: not-the-app  -> HTTP 404   (host routing is actually enforced, not a catch-all)
```

Image checks before deployment: serves `/health` → `ok`, runs as
`uid=101(nginx) gid=101(nginx)`, `linux/arm64`, 22.5MB.

### 11.6 The last mile needs root

Two steps cannot be automated from this session because both require `sudo` and no
passwordless sudo is configured:

1. `127.0.0.1  fsl-challenge.me` in `/etc/hosts`
2. binding **port 80** on localhost (ports below 1024 are privileged on macOS)

`k8s/expose-local.sh` performs both, idempotently.

**Deliberately not run — deferred by decision, not blocked.** Nothing on this machine was
modified: no `/etc/hosts` entry was written and no privileged port was bound. The app is
instead reached over an unprivileged forward:

```
kubectl --context=minikube port-forward -n ingress-nginx \
  svc/ingress-nginx-controller 18080:80 --address 127.0.0.1

curl -H "Host: fsl-challenge.me" http://127.0.0.1:18080/
```

This traverses the identical path port 80 would — the same Ingress rule matched on the
same `Host`, the same Service, the same three Pods. The only untested element is the
privileged bind itself. Requirement 5 is therefore met in substance but not literally:
`http://fsl-challenge.me` in a browser needs `k8s/expose-local.sh` run once.

**To finish it later:** `./k8s/expose-local.sh` (prompts for sudo twice, stays in the
foreground). To undo: Ctrl-C, then
`sudo sed -i '' '/fsl-challenge\.me/d' /etc/hosts`.

### 11.7 Still open

- **P0-16** — `REACT_APP_API_URL` is still inlined at build time, so the running Pods
  render an empty API URL. Unchanged: it needs a build-arg-per-environment or a runtime
  `env-config.js`, which is a packaging decision (recommendation 15).
- **P1-35** — the kubeconfig context reversion above.
- **P2-20** — the `RD.svg` favicon 404.
- **P1-13** — no image is built or pushed by CI; `rdicidr:0.1.0` was built and side-loaded
  by hand. Nothing yet connects a green pipeline to a deployed Pod.
- **P2-27 partially** — no HPA, PodDisruptionBudget, NetworkPolicy or per-environment
  overlay. None are required for a single-node local cluster; all matter on EKS.

---

## 12. AWS delivery — ECR, EKS and an internet-facing ALB (`fix/aws-cicd`)

Closes the delivery gap that sections 10 and 11 both ended on: there is now a path from
a commit on `main` to a running Pod behind a public load balancer.

### 12.1 What was already there

| Resource | State |
|---|---|
| EKS `demo-eks` | ACTIVE, v1.36, VPC `vpc-0ccddba1a82f9f3d4` |
| Node group `demo-node` | 1 node, **t4g.medium — arm64**, 1930m allocatable CPU |
| Subnets | 2 private (`internal-elb` tag, NAT) — the cluster's own; 2 public (`kubernetes.io/role/elb=1`, IGW) |
| IAM role `github-actions-eks` | Trusts GitHub OIDC for `repo:bdllerena/fs-cl*`; EKS access entry with `AmazonEKSClusterAdminPolicy` |
| GitHub OIDC provider | Registered |
| Cluster IAM OIDC provider | **Absent** — required for IRSA |
| ECR | **No repositories** |
| Load balancer controller | **Not installed**, no `IngressClass` |
| EKS managed addons | None |

The VPC was already laid out correctly for a public ALB — both public subnets carry
`kubernetes.io/role/elb=1` and route to `igw-0e883a49f80299d71`. Nothing about the
networking needed changing.

### 12.2 P0-36 — the CI role's policy pointed at a cluster that does not exist · `[FIXED]`

`github-actions-demo-eks` granted `eks:DescribeCluster` on:

```
arn:aws:eks:us-east-1:931686776282:cluster/eks-demo     <- the policy
arn:aws:eks:us-east-1:931686776282:cluster/demo-eks     <- the actual cluster
```

The name is reversed, so the statement matched nothing and the role could not describe
the cluster it exists to deploy to — `aws eks update-kubeconfig` would have failed on the
very first deploy. The policy also carried **no ECR permissions at all**, so the role
could not have pushed an image either.

Nothing had ever caught this because nothing had ever assumed the role: the pipeline that
would have used it had never run (P0-1).

**Fix:** policy v2 corrects the ARN, adds account-wide `ecr:GetAuthorizationToken` (that
call does not accept a resource restriction) and adds push/pull scoped to the single
`rdicidr` repository.

### 12.3 P0-37 — controller IAM policy and controller version were three majors apart · `[FIXED]`

The IAM policy published in the controller's own repository is **version-specific**, and
the installation instructions most people copy pin a tag by hand while Helm installs
whatever is current. That is exactly what happened here:

```
IAM policy taken from   v2.8.1
Helm chart installed    v3.5.0
```

The ALB was created, then reconciliation failed repeatedly:

```
Failed deploy model ... CreateLoadBalancer ... AccessDenied:
  not authorized to perform: ec2:GetSecurityGroupsForVpc
Failed deploy model ... DescribeListenerAttributes ... AccessDenied:
  not authorized to perform: elasticloadbalancing:DescribeListenerAttributes
```

Nine actions were added between the two versions:

```
ec2:DescribeIpamPools                        elasticloadbalancing:DescribeCapacityReservation
ec2:DescribeRouteTables                      elasticloadbalancing:ModifyCapacityReservation
ec2:GetSecurityGroupsForVpc                  elasticloadbalancing:ModifyIpPools
elasticloadbalancing:DescribeListenerAttributes
elasticloadbalancing:ModifyListenerAttributes
elasticloadbalancing:SetRulePriorities
```

**Fix:** policy replaced with the `v3.5.0` document (5196 chars, within IAM's 6144 limit).

**The lesson is the reusable part:** pin the Helm chart version *and* source the IAM
policy from the matching tag, in one place. An unpinned `helm upgrade` can silently move
the controller ahead of its own permissions, and the failure surfaces as an opaque
`AccessDenied` on an API nobody deliberately chose to call.

### 12.4 P1-38 — the node group is arm64 · `[FIXED]`

`t4g.medium` is Graviton. An image built on the default `ubuntu-latest` runner is amd64
and would fail on these nodes with `exec format error`. The `image` job therefore runs on
**`ubuntu-24.04-arm`** — native, no QEMU, and free because this repository is public.

This is the same architecture question that produced P0-34 locally, arriving from the
other direction. It is worth stating plainly: **this application's platform is arm64
end to end** — the developer laptops, the Minikube node, and the EKS node group.

### 12.5 P1-39 — the Ingress status lagged the real ALB · `[OBSERVED]`

After the policy fix the ALB reached `active` in AWS, but
`ingress.status.loadBalancer` stayed empty and `kubectl get ingress` showed no ADDRESS for
several minutes. The controller had backed off after the repeated 403s and did not
re-reconcile on its own within a useful window. A `rollout restart` of the controller
populated the status immediately.

Consequence for the pipeline: a deploy job that waits on the Ingress address can outlast
a perfectly healthy load balancer. The `Resolve the load balancer address` step polls for
10 minutes and then prints `kubectl describe ingress` rather than failing silently, so the
underlying AWS error is in the log instead of a bare timeout.

### 12.6 What was installed

```bash
aws ecr create-repository --repository-name rdicidr \
  --image-scanning-configuration scanOnPush=true --image-tag-mutability IMMUTABLE

eksctl utils associate-iam-oidc-provider --cluster demo-eks --approve

aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json      # from the v3.5.0 tag -- see P0-37

eksctl create iamserviceaccount --cluster demo-eks \
  --namespace kube-system --name aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn arn:aws:iam::931686776282:policy/AWSLoadBalancerControllerIAMPolicy --approve

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=demo-eks \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 --set vpcId=vpc-0ccddba1a82f9f3d4 \
  --set replicaCount=1
```

`replicaCount=1` because the cluster has a single node; the chart's default of 2 leaves
one replica `Pending` forever on its anti-affinity rule.

ECR is **tag-immutable** and scans on push, so a tag always denotes one image and cannot be
quietly overwritten.

### 12.7 Pipeline

```
install -> lint -> test -> build -> image -> deploy
                                    \________________/
                                    only on push to main
```

`image` and `deploy` are both gated on `github.event_name == 'push' && github.ref ==
'refs/heads/main'`, so **a pull request cannot push an image or touch the cluster** — it
runs the four CI stages and stops. Authentication is GitHub OIDC into
`github-actions-eks`; `id-token: write` is granted per-job, not workflow-wide, and there
are no long-lived AWS keys anywhere.

Images are tagged with the commit SHA. Because ECR is tag-immutable, re-running a
workflow for an already-published commit would fail on `PutImage`, so the job checks
`aws ecr describe-images` first and skips the build when the SHA is already there.

The deploy job pins the image, applies, waits for the rollout, resolves the ALB hostname,
and **smoke-tests `/health` through the load balancer before it reports success** — a
green deploy means traffic actually flowed, not merely that `kubectl apply` returned 0.

### 12.8 Manifest layout

Two targets now front the app differently, which is what finally justifies overlays
(P2-27 called for exactly this):

```
k8s/base/                 namespace, statefulset, services
k8s/overlays/minikube/    nginx Ingress, image side-loaded as rdicidr:0.1.0
k8s/overlays/aws/         ALB Ingress, image from ECR pinned to the commit SHA
```

`kubectl apply -k k8s/overlays/<target>`. Kustomize is built into kubectl, so this adds no
tooling. It also retires the numeric filename prefixes from section 11 — kustomize orders
by the `resources` list, not by filename.

The ALB Ingress names its two public subnets explicitly rather than relying only on tag
discovery, so a tag edit elsewhere in the VPC cannot silently relocate the load balancer.

### 12.9 Validation

```
$ kubectl get pods -n production -o wide
rdicidr-0   1/1  Running  0  10.0.11.36
rdicidr-1   1/1  Running  0  10.0.11.179
rdicidr-2   1/1  Running  0  10.0.11.90

$ kubectl get ingress -n production
rdicidr   alb   *   k8s-producti-rdicidr-698491d6e6-2111000178.us-east-1.elb.amazonaws.com   80

$ aws elbv2 describe-load-balancers
k8s-producti-rdicidr-698491d6e6   active   internet-facing   application
  us-east-1a  subnet-0f206e07b5fe21f93      <- public
  us-east-1b  subnet-08194d1f169814522      <- public

$ aws elbv2 describe-target-health
10.0.11.36   8080  healthy
10.0.11.90   8080  healthy
10.0.11.179  8080  healthy
```

From the public internet:

```
http://k8s-producti-rdicidr-698491d6e6-2111000178.us-east-1.elb.amazonaws.com
  /health       -> 200  "ok"
  /             -> 200  <title>RDerik Interactive CIDR</title>
  /deep/route   -> 200  (SPA fallback)
```

All three Pod IPs register as ALB targets on 8080 — the `target-type: ip` path, no
NodePort hop.

**How this run was performed.** The AWS resources above were created once by hand, and the
first deployment was executed with the same commands the `deploy` job runs, against the
image the `image` job would build. That proves the path end to end and de-risks the first
pipeline run. **The pipeline itself has not yet executed the deploy**, because `image` and
`deploy` are gated on `main` and the work is still on a branch. Merging is what hands the
deployment over to CI.

### 12.10 Open

- **P0-16** — still unresolved and now visible in production: the served page renders
  `API:` with no value, because `REACT_APP_API_URL` is inlined at build time and nothing
  sets it. The image would need rebuilding per environment, or a runtime `env-config.js`.
- **Namespace mismatch** — the `github-actions-eks` access entry carries
  `AmazonEKSEditPolicy` scoped to namespace **`application`**, while the app deploys to
  **`production`**. It works only because `AmazonEKSClusterAdminPolicy` is also attached.
  Someone intended `application`; that should be reconciled, and cluster-admin dropped in
  favour of the namespace-scoped grant.
- **HTTP only** — the listener is port 80. HTTPS needs an ACM certificate, a real domain,
  and `ssl-redirect`. The app is served over plaintext to the internet today.
- **No `WAF`, no access logs, no deletion protection** on the ALB.
- **Single node, single AZ for Pods** — all three replicas sit on one node, so the
  StatefulSet's 3 replicas buy no availability. The ALB spans two AZs; the workload does
  not.
- **No EKS managed addons** — no EBS CSI, no VPC CNI/kube-proxy/CoreDNS as managed addons,
  so they will not receive EKS-driven upgrades.
- **Cost** — an idle ALB is roughly $16–18/month plus LCU charges, and ECR storage accrues
  per image. Both persist until deleted.

---

## Summary

**CI — resolved.** The pipeline had never executed: its workflow sat inside the
application subdirectory rather than at the repository root. Four runs took it from
never-triggered to green, each exposing exactly one defect.

**Container and Kubernetes — resolved and validated.** Applying the original manifests
unchanged proved three findings in minutes, all of them runtime defects behind
**schema-valid YAML**: an image with no registry, a replica unschedulable against a
4 CPU / 4Gi request, and a Service selecting a label no pod carried.

**AWS delivery — built and live.** ECR, IRSA, the load balancer controller and an
internet-facing ALB now stand behind `install → lint → test → build → image → deploy`,
with OIDC authentication and no long-lived keys. Three Pods serve the public internet and
register healthy as ALB targets.

**The recurring theme is that nothing had ever run.** Every serious defect in this
repository — the ESLint plugin that was never installed, the test asserting on an undefined
variable, the Service selector typo, the IAM policy naming `eks-demo` instead of
`demo-eks` — was the kind that a single execution exposes immediately and that no amount of
reading finds reliably. The pipeline's absence was not one defect among many; it was the
reason the others survived.

**Architecture is the second theme.** arm64 turned up three times from three directions:
`node-sass` unable to build on musl/arm64 (P0-34), the EKS node group being Graviton
(P1-38), and the controller image needing a multi-arch tag. The platform is arm64 end to
end, and every build decision has to say so explicitly.

**What is still not done.** `REACT_APP_API_URL` remains inlined at build time, so the live
site renders an empty API URL — the one original finding that survived every pass, because
it is a packaging decision rather than a bug. The ALB serves plaintext HTTP. All three
replicas sit on a single node, so the replica count buys no availability. And the deploy
stage, though built and proven by hand, has not yet been driven by the pipeline itself.
