FROM node:22-alpine AS build

WORKDIR /app

COPY package.json package-lock.json* ./
COPY economy-engine/package.json economy-engine/package.json
RUN npm install

COPY economy-engine/tsconfig.json economy-engine/tsconfig.json
COPY economy-engine/src economy-engine/src
RUN npm --workspace economy-engine run build
RUN npm prune --omit=dev

FROM node:22-alpine AS runtime

WORKDIR /app
ENV NODE_ENV=production

COPY --from=build /app/package.json /app/package.json
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/economy-engine/package.json /app/economy-engine/package.json
COPY --from=build /app/economy-engine/dist /app/economy-engine/dist

EXPOSE 3000

CMD ["node", "economy-engine/dist/index.js"]
