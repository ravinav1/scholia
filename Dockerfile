FROM node:24-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY apps/web apps/web
COPY apps/chrome apps/chrome
COPY packages packages
COPY scripts/build-study-web.mjs scripts/build-study-web.mjs
RUN npm run build:web && npm prune --omit=dev

FROM node:24-bookworm-slim
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000 SCHOLIA_DATA_DIR=/data
RUN apt-get update && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-eng tesseract-ocr-nor \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/node_modules node_modules
COPY --from=build /app/dist/web dist/web
COPY package.json ./
COPY apps/server apps/server
COPY apps/chrome/src apps/chrome/src
COPY packages packages
COPY scripts/web-user.mjs scripts/web-user.mjs
RUN mkdir /data && chown node:node /data
USER node
VOLUME /data
EXPOSE 3000
CMD ["node", "apps/server/server.js"]
