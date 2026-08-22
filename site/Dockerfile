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

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
