FROM node:20-alpine

WORKDIR /app

# Install production deps only; keep image small for a 1 GB VM.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY server.js ./

# Run as non-root.
USER node

ENV NODE_ENV=production
EXPOSE 3000

CMD ["node", "server.js"]
