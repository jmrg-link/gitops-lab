# 4. Qué se comprueba

El laboratorio existe para comprobar en local siete comportamientos que en producción se dan por
hechos. Cada uno tiene un comando que lo provoca y un resultado que dice si se cumple.

| # | Comportamiento | Dónde está | Diagrama |
|---|---|---|---|
| 1 | Las dependencias arrancan en orden y la API no arranca antes de tiempo | `compose.yml` | [03](diagrams/README.md#03--arranque-de-compose) |
| 2 | Las migraciones corren antes de que arranque la versión nueva | `charts/whoami/templates/migrate-job.yaml` | [02](diagrams/README.md#02--secuencia-gitops-de-un-commit-a-los-pods-nuevos) |
| 3 | Un despliegue nunca deja la API con menos réplicas listas que las declaradas | `charts/whoami/templates/deployment.yaml` | [05](diagrams/README.md#05--rolling-update-sin-pérdida-de-servicio) |
| 4 | Un commit es la única forma de cambiar lo desplegado | `argocd/application.yaml` | [04](diagrams/README.md#04--ciclo-de-vida-de-la-application) |
| 5 | Volver atrás es revertir un commit | `argocd/application.yaml` | [04](diagrams/README.md#04--ciclo-de-vida-de-la-application) |
| 6 | La puerta de entrada protege la API | `charts/whoami/templates/middlewares.yaml` | [01](diagrams/README.md#01--arquitectura-del-laboratorio) |
| 7 | Una API con estado se despliega igual | `charts/nest-hexagonal` | [01](diagrams/README.md#01--arquitectura-del-laboratorio) |

## 1. Orden de arranque de Compose

```bash
docker compose up -d --wait
docker compose ps -a
```

**Se cumple si** `--wait` vuelve sin error, `redis`, `mongo` y `mssql` aparecen `healthy`,
`mssql-init` aparece `Exited (0)` y `api` está `Up`. La base `lab` existe en SQL Server:

```bash
docker compose exec -T mssql sh -c '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa \
  -P "$MSSQL_SA_PASSWORD" -C -h -1 -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4"'
```

**Prueba en negativo:** sin `MSSQL_SA_PASSWORD`, `docker compose config` falla con el mensaje
`Define MSSQL_SA_PASSWORD en .env` y no se crea ningún contenedor.

## 2. Migraciones antes del despliegue

```bash
helm install lab charts/whoami -n lab --create-namespace --wait
kubectl -n lab get pods
kubectl -n lab logs job/lab-whoami-migrate
```

**Se cumple si** el pod del Job aparece `Completed` y es más antiguo que los pods de la API, y su log
dice `Migrando para v1.11.0`. Tras un `helm upgrade --set image.tag=v1.12.0`, el log dice
`Migrando para v1.12.0`: el Job se volvió a lanzar antes del relevo.

**Lo que no hace:** `helm rollback` no vuelve a lanzar el Job, porque solo es hook de `pre-install`
y `pre-upgrade`. Una migración tiene que dejar el esquema compatible con la versión anterior.

## 3. Rolling update sin pérdida de capacidad

Durante un `upgrade`, en otra terminal:

```bash
kubectl -n lab get pods -w
```

Al terminar, la secuencia queda en los eventos del Deployment:

```bash
kubectl -n lab get events --field-selector involvedObject.kind=Deployment --sort-by=.lastTimestamp
```

**Se cumple si** el orden es: ReplicaSet nuevo de 0 a 1, viejo de 2 a 1, nuevo de 1 a 2 y viejo de 1
a 0. En ningún momento hay menos de dos pods listos; durante el relevo llega a haber tres.

**Reparto entre réplicas:** desde dentro del clúster, las respuestas alternan entre los dos pods:

```bash
kubectl -n lab run probe --rm -it --image=busybox:1.38 --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5 6; do wget -qO- http://lab-whoami | grep Hostname; done'
```

## 4. Git manda sobre el clúster

Con la Application aplicada y en `Synced`:

```bash
kubectl -n lab scale deployment lab-whoami --replicas=1
kubectl -n argocd get application whoami -w
```

**Se cumple si** la Application pasa a `OutOfSync` y vuelve sola a `Synced`, y el Deployment recupera
las réplicas que dice `values.yaml`. Es `selfHeal` deshaciendo el cambio manual.

**Un cambio en Git:** sube `replicaCount` a 3, haz commit y push. Antes de 3 minutos (120 s de
intervalo más hasta 60 de margen), o al momento con `argocd app get whoami --refresh`, hay tres pods.

**Helm no interviene:** `helm list -A` solo muestra la release de Argo CD. La Application renderiza el
chart, pero no crea release.

## 5. Volver atrás con Git

```bash
git revert HEAD --no-edit && git push
argocd app history whoami
argocd app rollback whoami 0
```

**Se cumple si** el `git revert` devuelve el clúster a la versión anterior en la siguiente
sincronización, y `argocd app rollback` se niega mientras la sincronización automática esté activa
con `rollback cannot be initiated when auto-sync is enabled`.
El historial de Git es el historial de despliegues.

## 6. La puerta de entrada protege la API

```bash
for i in $(seq 1 30); do curl -s -o /dev/null -w '%{http_code}\n' http://whoami.localhost/; done | sort | uniq -c
curl -s -A 'navegador-de-prueba' http://whoami.localhost/ | grep -i -E 'user-agent|x-forwarded-for|x-real-ip'
curl -sk -o /dev/null -w '%{http_code}\n' https://whoami.localhost/
```

**Se cumple si** de las 30 peticiones pasan unas 14 y el resto recibe `429`; la respuesta de whoami
no contiene el `User-Agent` enviado (aparece el `Go-http-client/1.1` del proxy) ni `X-Forwarded-For`
ni `X-Real-Ip`; y HTTPS responde `200` con el certificado autofirmado de Traefik. Cada petición deja
una línea en `kubectl -n traefik logs deploy/traefik`.

## 7. Una API con estado se despliega igual

El mismo flujo de Git, Argo CD y Traefik con la API NestJS, que guarda usuarios en MongoDB. Los
comandos están en la [guía 6](06-api-nestjs.md#5-probarla).

**Se cumple si** la Application `nest` está `Synced` y `Healthy`, `POST /graphql` responde por
`http://` y `https://nest.localhost`, el registro devuelve `201`, el login un `accessToken`,
`/auth/me` el email con el rol `customer`, y el usuario aparece en la base `nest-k8s` del Mongo del
Compose.

## Datos del entorno en el que se probó

| Pieza | Versión |
|---|---|
| Kubernetes (Docker Desktop, un nodo kubeadm) | 1.36.1 |
| Docker Engine | 29.8 |
| Helm | 4.3.1 |
| Chart `argo/argo-cd` | 10.10.0 (Argo CD 3.5.4) |
| Chart `traefik/traefik` | 41.7.1 (Traefik 3.7.14) |
| Redis · MongoDB · SQL Server | 8.10 · 8.0 · 2022 CU27 |
| whoami | v1.11.0 y v1.12.0 |
| Imagen base de la API NestJS | `node:24.22.0-bookworm-slim` |

Con todo en marcha (Compose, el clúster y Argo CD), los contenedores ocupan unos 2 GiB de los 7,75
de la máquina virtual de Docker.
