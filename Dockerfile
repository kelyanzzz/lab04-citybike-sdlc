# Mission 3 step 3 - multi-stage build
# ---- stage 1: build (full node:20 + devDependencies, needed by npm run build) ----
FROM node:20 AS build
ARG GITHUB_SHA=local-dev
ENV GITHUB_SHA=${GITHUB_SHA}
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- stage 2: run (small alpine image, only what the app needs at runtime) ----
FROM node:20-alpine AS run
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /app/server.js ./server.js
COPY --from=build --chown=node:node /app/public ./public
COPY --from=build --chown=node:node /app/dist/build-manifest.json ./dist/build-manifest.json
USER node
EXPOSE 4173
CMD ["node", "server.js"]
