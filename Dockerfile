# Mission 2 - naive single-stage Dockerfile (on purpose: no cache order, no .dockerignore)
FROM node:20
COPY . .
RUN npm ci
RUN npm run build
EXPOSE 4173
CMD ["node", "server.js"]
