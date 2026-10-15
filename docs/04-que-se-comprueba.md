# 4. Qué se comprueba

El laboratorio existe para comprobar en local cinco comportamientos que en producción se dan por
hechos. Cada uno tiene un comando que lo provoca y un resultado que dice si se cumple.

| # | Comportamiento | Dónde está | Diagrama |
|---|---|---|---|
| 1 | Las dependencias arrancan en orden y la API no arranca antes de tiempo | `compose.yml` | [03](diagrams/README.md#03--arranque-de-compose) |
| 2 | Las migraciones corren antes de que arranque la versión nueva | `charts/whoami/templates/migrate-job.yaml` | [02](diagrams/README.md#02--secuencia-gitops-de-un-commit-a-los-pods-nuevos) |
| 3 | Un despliegue nunca deja la API con menos réplicas listas que las declaradas | `charts/whoami/templates/deployment.yaml` | [05](diagrams/README.md#05--rolling-update-sin-pérdida-de-servicio) |
| 4 | Un commit es la única forma de cambiar lo desplegado | `argocd/application.yaml` | [04](diagrams/README.md#04--ciclo-de-vida-de-la-application) |
| 5 | Volver atrás es revertir un commit | `argocd/application.yaml` | [04](diagrams/README.md#04--ciclo-de-vida-de-la-application) |

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

## Datos del entorno en el que se probó

| Pieza | Versión |
|---|---|
| Kubernetes (Docker Desktop, un nodo kubeadm) | 1.36.1 |
| Docker Engine | 29.8 |
| Helm | 4.3.1 |
| Chart `argo/argo-cd` | 10.10.0 (Argo CD 3.5.4) |
| Redis · MongoDB · SQL Server | 8.10 · 8.0 · 2022 CU27 |
| whoami | v1.11.0 y v1.12.0 |

Con todo en marcha (Compose, el clúster y Argo CD), los contenedores ocupan unos 2 GiB de los 7,75
de la máquina virtual de Docker.
