# Netflix Clone — DevSecOps Project

A Netflix-style front end (React + TypeScript + MUI) that reads catalogue data from
[TMDB](https://www.themoviedb.org/), built as a vehicle for a DevSecOps pipeline:
Jenkins → SonarQube → Trivy → Docker → Kubernetes.

The app itself is **100% client-side**. There is no backend in this repo — the browser
calls TMDB directly, and the production container is nginx serving static files.

---

## Quick start (local)

```bash
npm install
npm run dev          # http://localhost:5173
```

Create a `.env` first (git-ignored):

```
VITE_APP_API_ENDPOINT_URL=https://api.themoviedb.org/3
VITE_APP_TMDB_V3_API_KEY=<your TMDB v3 API key>
```

Get a key: TMDB → Settings → API → *API Key (v3 auth)*.

| Script | Does |
|---|---|
| `npm run dev` | Vite dev server with HMR |
| `npm run build` | `tsc` typecheck, then production bundle into `dist/` |
| `npm run preview` | Serve the built `dist/` locally |

Verified on Node 24 (the image builds on `node:24-alpine`).

---

## Docker

The key is **not** baked into the image. It is injected when the container starts, so one
image is safe to push to a registry and reuse across environments.

```bash
docker build -t bhikaji12/netflix:latest .

docker run -d -p 8080:80 --name netflix \
  -e TMDB_V3_API_KEY='<your TMDB v3 API key>' \
  bhikaji12/netflix:latest
```

How that works — worth knowing, because it is the one non-obvious thing in the build:

1. Vite **text-substitutes** `import.meta.env.*` into the JS bundle at build time. There is
   no runtime env to read later; the value is a string literal inside `assets/index.*.js`.
2. So the builder stage compiles with a sentinel value, `__TMDB_V3_API_KEY__`.
3. `nginx:alpine` runs every `/docker-entrypoint.d/*.sh` before starting nginx. The image
   drops `10-tmdb-key.sh` there, which `sed`s the sentinel out of `dist/assets/*.js` using
   `$TMDB_V3_API_KEY`, then nginx serves the patched files.
4. No `TMDB_V3_API_KEY` at run time → the container exits with an error rather than serving
   a silently broken app.

Consequence: the key ships inside the JavaScript the browser downloads and is readable in
devtools. That is inherent to any browser-only TMDB client. Use a read-only v3 key and
never put a privileged credential here.

---

## Kubernetes

```bash
kubectl apply -f Kubernetes/deployment.yml   # 2 replicas, container port 80
kubectl apply -f Kubernetes/service.yml      # LoadBalancer on port 80
```

Both live in the `netflix` namespace and match on `app: netflix`.

The pod needs `TMDB_V3_API_KEY` for the same reason the container does. `deployment.yml`
reads it from a secret named `tmdb-secret`, in the `netflix` namespace, so create both
before applying:

```bash
kubectl create namespace netflix
kubectl -n netflix create secret generic tmdb-secret \
  --from-literal=TMDB_V3_API_KEY='<your TMDB v3 API key>'
```

Get the external address once the cloud provider has provisioned it:

```bash
kubectl -n netflix get svc netflix -w
```

Then open `http://<EXTERNAL-IP>`. On a cluster with no load-balancer controller (kind,
minikube, bare metal) `EXTERNAL-IP` stays `<pending>` — use `kubectl -n netflix port-forward
svc/netflix 8080:80` instead, or switch the service back to `NodePort`.

---

## CI/CD

`pipeline.txt` is the Jenkins declarative pipeline:

| Stage | Does |
|---|---|
| Clean Workspace | `cleanWs()` |
| Checkout from Git | `main` of `bhikaji12/DevSecOps-Project` |
| SonarQube Analysis | `sonar-scanner`, project key `Netflix` |
| Quality Gate | `waitForQualityGate`, **non-blocking** (`abortPipeline: false`) |
| TRIVY FS SCAN | `trivy fs .` → `trivyfs.txt` |
| TRIVY IMAGE SCAN | `trivy image $DOCKER_IMAGE` → `trivyimage.txt` |
| Check Kubernetes Connection | `cluster-info` + `auth can-i create deployments` |
| Deploy to Kubernetes | `kubectl apply -f Kubernetes/`, then `rollout status deployment/netflix` |

Both Trivy reports are archived as build artifacts on every run, pass or fail.

**The pipeline does not build or push the image.** It scans and deploys
`bhikaji12/netflix:latest` as already published, so `docker build` / `docker push` happen
outside it (see [Docker](#docker) above) — otherwise the image scan and the rollout use the
previous image.

Jenkins prerequisites:

- Tools: `jdk17`, `nodejs` named `node24`, `sonar-scanner`
- SonarQube server config named `sonar-server`
- Credentials: `sonar-token` (quality gate), `k8s-ca-cert` (**Secret file** — cluster CA
  PEM), `k8s-jenkins-token` (service-account token)
- `K8S_SERVER` in the `environment` block is a placeholder — set your real API server URL
- `trivy` and `kubectl` on the agent's `PATH`
- Namespace `netflix` and secret `tmdb-secret` must exist before the first deploy

The deploy stage applies the whole `Kubernetes/` directory, so anything added there ships
with the app. Keep unrelated manifests (monitoring, exporters) elsewhere — a file carrying
its own `namespace:` conflicts with the stage's `-n netflix` and fails the apply.

---

## How the app is put together

```
src/
  main.tsx            entry — Redux store, MUI theme, router
  routes/             react-router config; pages are lazy-loaded
  layouts/            MainLayout — header, outlet, footer
  pages/
    HomePage          hero banner + genre rows
    GenreExplore      one genre, infinite-scroll grid
    WatchPage         full-screen video.js player
  store/
    slices/apiSlice   RTK Query base — all TMDB calls live here
    slices/           configuration, discover, genre, detail-modal state
  components/         presentational pieces (sliders, hover cards, player controls)
    watch/            video.js + YouTube player chrome
    slick-slider/     carousel wrapper and custom arrows
  providers/          DetailModalProvider, PortalProvider (hover-card portals)
  hooks/              typed redux hooks, intersection observer, window size
  constant/index.ts   API key/endpoint, route names, layout constants
  theme/palette.ts    Netflix-ish dark palette
  types/              TMDB response shapes
```

Key choices to orient around:

- **RTK Query** owns all data fetching and caching — no manual `fetch`, no loading flags in
  components. New TMDB endpoints go in `store/slices/apiSlice.ts`.
- **Routing** at `routes/index.tsx` uses `lazy:` imports, which is why `dist/` has separate
  `HomePage`, `GenreExplore` and `WatchPage` chunks. `/` redirects to `/browse`.
- **`src/` absolute imports** (`import x from "src/..."`) work via `vite-tsconfig-paths`
  reading `tsconfig.json` — not a Vite alias.
- **Hover previews** render through a React portal (`PortalProvider`) so a card can escape
  its carousel's overflow clipping.
- **Playback** is video.js with the YouTube tech; trailers come from TMDB video keys
  appended to `YOUTUBE_URL`.
- Single-page app, so any host must rewrite all paths to `/` — that is all `vercel.json`
  does.

---

## Known rough edges

- `npm audit` reports 15 vulnerabilities; Vite 3 and TypeScript 4 are several majors
  behind. Upgrading is a real migration, not a patch bump.
- The main bundle is ~1.1 MB (~358 KB gzipped) and trips Vite's chunk-size warning.
