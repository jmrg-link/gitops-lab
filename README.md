# gitops-lab

Un laboratorio para practicar en local el ciclo completo de un backend que se despliega con GitOps:
las bases de datos en Docker Compose, la aplicación empaquetada como chart de Helm y Argo CD
manteniendo el clúster igual que este repositorio.

La aplicación es [traefik/whoami](https://github.com/traefik/whoami), que hace de API de pega:
responde con el nombre del pod que atiende la petición, así que se ve en cada momento qué versión y
qué réplica contesta.

## Qué hay en el repositorio

```
gitops-lab/
├── compose.yml              Redis, MongoDB y SQL Server para desarrollo local
├── charts/whoami/           Chart de Helm de la API
│   ├── Chart.yaml
│   ├── values.yaml          Valores por defecto: la API pública del chart
│   └── templates/
│       ├── _helpers.tpl     Nombres y etiquetas comunes
│       ├── deployment.yaml  Rolling update sin pérdida de servicio
│       ├── service.yaml     Service ClusterIP delante de los pods
│       └── migrate-job.yaml Job de migraciones que corre antes de cada despliegue
└── argocd/
    ├── values-local.yaml    Valores mínimos para instalar Argo CD en local
    └── application.yaml     Application que despliega el chart desde este repositorio
```

Cada fichero lleva una cabecera que explica qué hace y por qué. En `values.yaml`, cada clave tiene
su descripción en un comentario `# --` justo encima.

## Requisitos

- Docker Desktop con Kubernetes activado. Con un solo nodo (Kubeadm) basta.
- `helm` 4 y el CLI de `argocd`: `brew install helm argocd`.
- En Apple Silicon, la emulación con Rosetta activada en Docker Desktop: SQL Server solo publica
  imagen x86-64.

Probado con Kubernetes 1.36.1, Helm 4.3.1, el chart `argo/argo-cd` 10.10.0 (Argo CD 3.5.4) y Docker
Engine 29.8.

## 1. Las bases de datos con Docker Compose

Compose necesita la contraseña de `sa` de SQL Server en un fichero `.env` junto a `compose.yml`.
Tiene que tener 8 caracteres o más y mezclar al menos tres tipos entre mayúsculas, minúsculas,
dígitos y símbolos. El `.gitignore` lo deja fuera del repositorio.

```bash
echo 'MSSQL_SA_PASSWORD=<tu-contraseña>' > .env
docker compose up -d --wait
docker compose ps -a
curl localhost:8081
```

`--wait` vuelve cuando todo está sano. `mssql-init` aparece como `Exited (0)`: crea la base `lab`
y termina, y la API no arranca hasta que lo ha hecho bien.

| Servicio | Puerto | Notas |
| --- | --- | --- |
| Redis | 6379 | AOF y `noeviction`: si Redis expulsa claves, una cola pierde trabajos |
| MongoDB | 27017 | Replica set de un nodo, necesario para las transacciones. Conecta con `mongodb://localhost:27017/lab?directConnection=true` |
| SQL Server | 1433 | Usuario `sa` con la contraseña del `.env` |
| API (whoami) | 8081 | Sustituto de tu API; en un proyecto real sería `build: .` |

MongoDB y SQL Server tienen la memoria limitada para dejar sitio al clúster. Si aun así vas justo,
para el compose antes de seguir: `docker compose down` (con `-v` borra también los datos).

## 2. El chart con Helm

```bash
kubectl config use-context docker-desktop
helm lint charts/whoami
helm install lab charts/whoami -n lab --create-namespace --wait
kubectl -n lab get deploy,pods,svc,jobs
kubectl -n lab logs job/lab-whoami-migrate
```

Para llamar a la API, en otra terminal:

```bash
kubectl -n lab port-forward svc/lab-whoami 8082:80
curl localhost:8082
```

Una actualización y la vuelta atrás:

```bash
helm upgrade lab charts/whoami -n lab --set image.tag=v1.12.0 --wait --rollback-on-failure
helm history lab -n lab
helm rollback lab 1 -n lab --wait
```

Qué conviene mirar mientras tanto:

- El Job de migraciones termina antes de que arranque ningún pod nuevo: es un hook
  `pre-install,pre-upgrade`.
- Con `maxSurge: 1` y `maxUnavailable: 0` nunca hay menos de dos pods listos. Se ve con
  `kubectl -n lab get pods -w` durante el `upgrade`.
- `helm rollback` crea una revisión nueva con el contenido de la antigua, y **no** vuelve a lanzar
  la migración. Por eso el esquema de la base tiene que seguir sirviendo a la versión anterior.
- El port-forward se engancha a un solo pod. Para ver el reparto entre réplicas hay que preguntar
  desde dentro del clúster:

  ```bash
  kubectl -n lab run probe --rm -it --image=busybox:1.38 --restart=Never -- \
    sh -c 'while true; do wget -qO- http://lab-whoami | grep Hostname; sleep 1; done'
  ```

Antes de pasar a Argo CD, quita lo instalado. `helm uninstall` no borra el Job, porque los recursos
de un hook no forman parte de la release; por eso se borra el namespace entero.

```bash
helm uninstall lab -n lab
kubectl delete namespace lab
```

## 3. Argo CD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd --version 10.10.0 -n argocd --create-namespace \
  -f argocd/values-local.yaml --wait
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

La interfaz queda en http://localhost:8080. El usuario es `admin` y la contraseña inicial se lee con
`argocd admin initial-password -n argocd`. Para usar el CLI:

```bash
argocd login localhost:8080 --plaintext --username admin
```

`values-local.yaml` sirve la interfaz sin TLS y quita el SSO y las notificaciones para ahorrar
memoria. No es una configuración de producción.

## 4. GitOps: el clúster sigue a este repositorio

```bash
kubectl apply -f argocd/application.yaml
argocd app get whoami
```

La Application lee `charts/whoami` de la rama `main`, lo renderiza como lo haría
`helm template lab` y aplica el resultado en el namespace `lab`. A partir de aquí, los cambios se
hacen con commits, no con `kubectl` ni con `helm`.

Si haces un fork, cambia `repoURL` en `argocd/application.yaml`. Un repositorio privado hay que
registrarlo antes con `argocd repo add`.

### Experimentos

1. **Un cambio en Git.** Sube `replicaCount` a 3 en `values.yaml`, haz commit y push. Argo CD mira
   el repositorio cada 120 segundos, más un margen aleatorio de hasta 60; `argocd app get whoami --refresh` lo adelanta.
2. **Deriva.** `kubectl -n lab scale deployment lab-whoami --replicas=1`. Con `selfHeal`, Argo CD
   devuelve el Deployment a lo que dice Git en segundos.
3. **Una versión nueva.** Pon `image.tag: v1.12.0` en `values.yaml` y haz push. Primero corre el Job
   de migraciones como PreSync y después el rolling update.
4. **Rollback.** `git revert HEAD --no-edit && git push`. Con la sincronización automática activa,
   `argocd app rollback` se niega: volver atrás es revertir el commit.
5. **Helm no lo ve.** `helm list -A` solo muestra `argocd`. Argo CD usa Helm para renderizar, pero
   aplica los manifiestos él mismo y no crea una release.

## Limpieza

Borra la Application antes que Argo CD. Su finalizer necesita el controlador para eliminar lo
desplegado, y sin él la Application se queda atascada.

```bash
kubectl delete -f argocd/application.yaml
helm uninstall argocd -n argocd
kubectl delete namespace argocd lab
docker compose down -v
```

Los CRD de Argo CD siguen en el clúster después del `uninstall`, porque el chart los instala con
`crds.keep: true`. *Reset cluster*, en la vista de
Kubernetes de Docker Desktop, lo deja todo como al principio.
