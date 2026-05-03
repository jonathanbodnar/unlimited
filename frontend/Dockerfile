# Optional: deterministic build for Railway.
# Railway's Nixpacks autodetects Node and works fine, but this Dockerfile
# guarantees a known-good runtime if Nixpacks ever drifts.
FROM node:20-alpine

WORKDIR /app

# Install deps with cache-friendly ordering.
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# Copy source.
COPY tsconfig.json ./
COPY src ./src

ENV NODE_ENV=production
EXPOSE 3000

CMD ["npm", "start"]
