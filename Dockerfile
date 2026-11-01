# =========================
# Stage 1: Builder
# =========================
FROM node:24-alpine AS builder

# Update Alpine packages
RUN apk update && apk upgrade --no-cache

WORKDIR /app

COPY package.json yarn.lock ./

RUN yarn install

COPY . .

ARG TMDB_V3_API_KEY

ENV VITE_APP_TMDB_V3_API_KEY=${TMDB_V3_API_KEY}
ENV VITE_APP_API_ENDPOINT_URL="https://api.themoviedb.org/3"

RUN yarn build


# =========================
# Stage 2: Production
# =========================
FROM nginx:stable-alpine

# Fix brotli-libs, curl and libcurl vulnerabilities
RUN apk update && apk upgrade --no-cache

WORKDIR /usr/share/nginx/html

RUN rm -rf ./*

COPY --from=builder /app/dist .

EXPOSE 80

ENTRYPOINT ["nginx", "-g", "daemon off;"]