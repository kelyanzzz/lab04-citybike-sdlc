# Mission 3 step 1 - cache-friendly order: dependencies before source
FROM node:20
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build
EXPOSE 4173
CMD ["node", "server.js"]
