# =========================
# Stage 1: Builder
# =========================
FROM node:24-alpine AS builder

# Update Alpine packages
RUN apk update && apk upgrade --no-cache

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci

COPY . .

# ponytail: key is NOT baked in. Vite inlines this placeholder, the nginx
# entrypoint swaps it for $TMDB_V3_API_KEY at container start.
ENV VITE_APP_TMDB_V3_API_KEY="__TMDB_V3_API_KEY__"
ENV VITE_APP_API_ENDPOINT_URL="https://api.themoviedb.org/3"

RUN npm run build


# =========================
# Stage 2: Production
# =========================
FROM nginx:stable-alpine

# Fix brotli-libs, curl and libcurl vulnerabilities
RUN apk update && apk upgrade --no-cache

WORKDIR /usr/share/nginx/html

RUN rm -rf ./*

COPY --from=builder /app/dist .

# nginx:alpine runs /docker-entrypoint.d/*.sh before starting, so no ENTRYPOINT override.
RUN printf '#!/bin/sh\nset -e\n[ -n "$TMDB_V3_API_KEY" ] || { echo "TMDB_V3_API_KEY not set" >&2; exit 1; }\nsed -i "s|__TMDB_V3_API_KEY__|$TMDB_V3_API_KEY|g" /usr/share/nginx/html/assets/*.js\n' \
      > /docker-entrypoint.d/10-tmdb-key.sh \
    && chmod +x /docker-entrypoint.d/10-tmdb-key.sh

EXPOSE 80