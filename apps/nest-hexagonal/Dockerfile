# @file apps/nest-hexagonal/Dockerfile
#
# Imagen de la API NestJS de jmrg-link/nest-hexagonal-adapters para desplegarla en el clúster
# local. El código no se copia a este repositorio: el contexto de build es el clon de aquel.
#
# - Etapa `build`: instala dependencias con el pnpm fijado en `packageManager` (el `postinstall`
#   ejecuta `prisma generate`) y compila a `dist/` con `nest build`.
# - Etapa final: solo dependencias de producción y `dist/`, sin root, escuchando en el 3000.
# - Las exclusiones del contexto están en `Dockerfile.dockerignore`, junto a este fichero: ni
#   `.env` ni `node_modules` entran en la imagen.
# - En Docker Desktop, Kubernetes usa el mismo motor Docker, así que la imagen local está
#   disponible para el clúster sin publicarla en un registro.
#
# @param contexto - Ruta del clon de nest-hexagonal-adapters.
# @example
#   docker build -f apps/nest-hexagonal/Dockerfile -t nest-hexagonal-adapters:0.1.0 ../nest-hexagonal-adapters
# @see https://docs.docker.com/build/concepts/context/#filename-and-location
FROM node:24.22.0-bookworm-slim AS build
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY prisma ./prisma
COPY prisma.config.ts ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm build && pnpm prune --prod --ignore-scripts

FROM node:24.22.0-bookworm-slim
ENV NODE_ENV=production PORT=3000
WORKDIR /app
COPY --from=build --chown=node:node /app/package.json ./
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
USER node
EXPOSE 3000
CMD ["node", "dist/main.js"]
