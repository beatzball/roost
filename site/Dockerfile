# Build the static site, then serve it with nginx.
# Coolify: set Base Directory to /site and Dockerfile Location to /site/Dockerfile.

# Stage 1: Build
FROM node:22-slim AS builder

RUN corepack enable

WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .
RUN pnpm build

# Stage 2: Serve
FROM nginx:alpine

COPY --from=builder /app/dist/static /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Which commit is actually being served.
#
# A static site has no /api/health to ask, so bake the answer in. Without it a
# post-deploy probe cannot tell the new container from the old one: it passes
# against whatever is still running and a failed deploy looks green.
#
# Prefer an explicit --build-arg GIT_SHA; fall back to SOURCE_COMMIT, which
# Coolify sets automatically on every deploy.
ARG GIT_SHA
ARG SOURCE_COMMIT
RUN printf '{"commit":"%s"}\n' "${GIT_SHA:-${SOURCE_COMMIT:-unknown}}" \
      > /usr/share/nginx/html/version.json

EXPOSE 80

# Coolify (and any orchestrator) uses this to decide whether a deploy actually
# came up, rather than assuming a started container is a working one. Requests
# a real page, so a container that boots with an empty document root fails
# instead of reporting healthy.
# 127.0.0.1, not localhost: inside the container "localhost" resolves to ::1
# first, and a check against an IPv6 address fails with "connection refused"
# unless nginx is also listening there -- which would report every healthy
# deploy as unhealthy.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
