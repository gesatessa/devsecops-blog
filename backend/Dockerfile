# Build stage
FROM node:20-alpine AS build

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

# Runtime stage
FROM node:20-alpine

WORKDIR /app

ENV NODE_ENV=production

COPY --from=build /app/package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY --from=build /app/src ./src

# RUN addgroup -S appgroup && adduser -S appuser -G appgroup
# USER appuser
RUN addgroup -S -g 10001 appgroup && adduser -S -u 10001 -G appgroup appuser
USER 10001

EXPOSE 5000

CMD ["node", "src/index.js"]
