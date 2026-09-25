# ---- build stage -----------------------------------------------------------
FROM node:15-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json ./

# --omit=optional skips node-sass. It is an optional peer dependency of
# sass-loader, it publishes no prebuilt binary for linux-musl/arm64, and this
# project contains no .scss or .sass sources, so building it from source would
# add a Python and C toolchain to the image for something never imported.
RUN npm ci --omit=optional

COPY . .
RUN npm run build

# ---- runtime stage ---------------------------------------------------------
FROM nginx:1.21-alpine

COPY --from=builder /app/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Run as the unprivileged `nginx` user (uid 101) that the base image already
# creates. The pid file moves to /tmp and the cache directory is handed over,
# because neither /var/run nor /var/cache/nginx is writable by that user.
RUN sed -i 's|^pid .*|pid /tmp/nginx.pid;|' /etc/nginx/nginx.conf \
 && chown -R nginx:nginx /var/cache/nginx

USER nginx
EXPOSE 8080

ENTRYPOINT ["nginx", "-g", "daemon off;"]
